# syntax=docker/dockerfile:1

# ponytail: Trixie was for Mesa headers. Vendor wheels cap at Python 3.12.
# Bookworm ships Python 3.11 natively, perfectly matching the cp311 wheel.
ARG DEBIAN_IMAGE=debian:bookworm-slim

# ==============================================================================
# STAGE 1: Model Compiler (Heavy)
# ==============================================================================
FROM ${DEBIAN_IMAGE} AS builder

ARG DEBIAN_FRONTEND=noninteractive

# Install thick dependencies for AOT compilation
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3-venv python3-pip git curl \
      libgl1 libglib2.0-0 \
      cmake build-essential python3-dev \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /venv \
 && /venv/bin/pip install --no-cache-dir --upgrade pip numpy pillow opencv-python-headless

# Grab the full Toolkit 2 (has the AOT compiler, unlike lite2)
RUN git clone --depth 1 https://github.com/airockchip/rknn-toolkit2.git /tmp/rknn \
 && PY_VER=$(python3 -c 'import sys; print(f"cp{sys.version_info.major}{sys.version_info.minor}")') \
 && WHEEL=$(find /tmp/rknn/rknn-toolkit2/packages/ -name "*${PY_VER}*aarch64.whl" | head -n 1) \
 && test -n "$WHEEL" || (echo "Error: No matching wheel found for Python ${PY_VER}" && exit 1) \
 && echo "Installing $WHEEL" \
 && /venv/bin/pip install --no-cache-dir "$WHEEL" \
 && rm -rf /tmp/rknn

# Clone Model Zoo for the conversion script and INT8 calibration dataset
RUN git clone --depth 1 https://github.com/airockchip/rknn_model_zoo.git /opt/rknn_model_zoo

# ponytail: The python wheel is just a wrapper. We curl the native C++ hardware library directly.
RUN curl -fsSLo /opt/librknnrt.so https://github.com/airockchip/rknn-toolkit2/raw/refs/heads/master/rknpu2/runtime/Linux/librknn_api/aarch64/librknnrt.so

# Download ONNX & Compile to RKNN
WORKDIR /opt/rknn_model_zoo/examples/yolo11
RUN mkdir -p model \
 && curl -fsSLo model/yolo11n.onnx https://ftrg.zbox.filez.com/v2/delivery/data/95f00b0fc900458ba134f8b180b3f7a1/examples/yolo11/yolo11n.onnx

WORKDIR /opt/rknn_model_zoo/examples/yolo11/python
RUN /venv/bin/python convert.py ../model/yolo11n.onnx rk3588 i8

# Download sample video for the fallback stream
RUN mkdir -p /assets && curl -fsSLo /assets/sample.mp4 https://github.com/intel-iot-devkit/sample-videos/raw/master/person-bicycle-car-detection.mp4


# ==============================================================================
# STAGE 2: Runtime (Slim)
# ==============================================================================
FROM ${DEBIAN_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      python3-venv python3-pip git \
      libgl1 libglib2.0-0 \
      nano \
    && rm -rf /var/lib/apt/lists/*

# ponytail: Added torch and torchvision here as well for runtime decoding.
RUN python3 -m venv /venv \
 && /venv/bin/pip install --no-cache-dir --upgrade pip numpy pillow opencv-python-headless \
 && /venv/bin/pip install --no-cache-dir --upgrade torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu

# Grab only the Lite version for runtime inference
RUN git clone --depth 1 https://github.com/airockchip/rknn-toolkit2.git /tmp/rknn \
 && PY_VER=$(python3 -c 'import sys; print(f"cp{sys.version_info.major}{sys.version_info.minor}")') \
 && WHEEL=$(find /tmp/rknn/rknn-toolkit-lite2/packages/ -name "*${PY_VER}*aarch64.whl" | head -n 1) \
 && test -n "$WHEEL" || (echo "Error: No matching wheel found for Python ${PY_VER}" && exit 1) \
 && echo "Installing $WHEEL" \
 && /venv/bin/pip install --no-cache-dir "$WHEEL" \
 && rm -rf /tmp/rknn

# Copy the native NPU hardware library into system path
COPY --from=builder /opt/librknnrt.so /usr/lib/

# Copy the RKNN model, sample video, and the model zoo (detect_stream.py imports the zoo)
RUN mkdir -p /opt/assets
COPY --from=builder /opt/rknn_model_zoo/examples/yolo11/model/yolo11.rknn /opt/assets/
COPY --from=builder /assets/sample.mp4 /opt/assets/
COPY --from=builder /opt/rknn_model_zoo/ /opt/rknn_model_zoo/

COPY detect_stream.py /opt/

ENV PATH=/venv/bin:$PATH
ENTRYPOINT ["/venv/bin/python"]
CMD ["/opt/detect_stream.py"]