# syntax=docker/dockerfile:1

ARG DEBIAN_IMAGE=debian:trixie-20250630-slim

# ==============================================================================
# STAGE 1: Builder
# ==============================================================================
FROM ${DEBIAN_IMAGE} AS builder

ARG MESA_REF=main
ARG DEBIAN_FRONTEND=noninteractive

# Install build-time dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates build-essential pkg-config \
      meson ninja-build python3 python3-mako python3-yaml \
      bison flex \
      libdrm-dev libexpat1-dev zlib1g-dev libelf-dev llvm-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Clone Mesa
RUN git clone --filter=blob:none --branch "${MESA_REF}" --depth=1 \
      https://gitlab.freedesktop.org/mesa/mesa.git \
 && git -C mesa rev-parse HEAD > /mesa.sha

WORKDIR /src/mesa

# Build Mesa / Teflon
RUN set -eux; \
    COMMON="-Dteflon=true -Dvulkan-drivers= -Dplatforms= \
            -Dglx=disabled -Degl=disabled -Dgbm=disabled \
            -Dgles1=disabled -Dgles2=disabled \
            -Dllvm=disabled -Dbuildtype=release"; \
    if meson setup build -Dgallium-drivers=rocket $COMMON; then \
        echo rocket > /gallium.driver; \
    else \
        rm -rf build; \
        meson setup build -Dgallium-drivers=llvmpipe -Dllvm=enabled \
            -Dteflon=true -Dvulkan-drivers= -Dplatforms= \
            -Dglx=disabled -Degl=disabled -Dgbm=disabled \
            -Dgles1=disabled -Dgles2=disabled -Dbuildtype=release; \
        echo llvmpipe > /gallium.driver; \
    fi; \
    ninja -C build src/gallium/targets/teflon/libteflon.so; \
    install -Dm755 build/src/gallium/targets/teflon/libteflon.so \
        /out/usr/local/lib/libteflon.so

# Auto-detect Debian runtime packages required by libteflon.so
RUN set -eux; \
    ldd /out/usr/local/lib/libteflon.so \
      | awk '/=> \//{print $3}' \
      | xargs -r -n1 realpath \
      | sort -u \
      | xargs -r dpkg-query -S 2>/dev/null \
      | cut -d: -f1 | tr ',' '\n' | tr -d ' ' \
      | sort -u > /out/runtime-deps.txt

# Build Python Virtual Environment with TFLite Runtime & OpenCV
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3-venv python3-pip curl \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /venv \
 && /venv/bin/pip install --no-cache-dir --upgrade pip \
 && /venv/bin/pip install --no-cache-dir numpy pillow opencv-python-headless \
 && ( /venv/bin/pip install --no-cache-dir tflite-runtime \
      || /venv/bin/pip install --no-cache-dir ai-edge-litert )

# Bake assets for ALL demos into the image
WORKDIR /assets
RUN set -eux; \
    GC=https://github.com/google-coral/test_data/raw/master; \
    # Classification assets \
    curl -fsSLo classify_model.tflite $GC/mobilenet_v1_1.0_224_quant.tflite; \
    curl -fsSLo classify_labels.txt $GC/imagenet_labels.txt; \
    curl -fsSLo sample.jpg $GC/parrot.jpg; \
    # Object Detection assets \
    curl -fsSLo detect_model.tflite $GC/ssd_mobilenet_v1_coco_quant_postprocess.tflite; \
    curl -fsSLo detect_labels.txt $GC/coco_labels.txt; \
    # Sample Video for stream demo (when no webcam present) \
    curl -fsSLo sample.mp4 https://github.com/intel-iot-devkit/sample-videos/raw/master/person-bicycle-car-detection.mp4

COPY classify.py detect_stream.py /opt/

# ==============================================================================
# STAGE 2: Runtime
# ==============================================================================
FROM ${DEBIAN_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive

COPY --from=builder /out/runtime-deps.txt /tmp/runtime-deps.txt

# Install dynamic dependencies + glib (for OpenCV ffmpeg decoding)
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 libglib2.0-0 $(tr '\n' ' ' < /tmp/runtime-deps.txt) \
    && rm -rf /var/lib/apt/lists/* /tmp/runtime-deps.txt

COPY --from=builder /out/usr/local/lib/libteflon.so /usr/local/lib/
COPY --from=builder /venv   /venv
COPY --from=builder /assets /opt/assets
COPY --from=builder /opt/   /opt/
COPY --from=builder /mesa.sha /gallium.driver /etc/

RUN ldconfig \
 && ldd /usr/local/lib/libteflon.so \
 && ! ldd /usr/local/lib/libteflon.so | grep -q 'not found'

ENV PATH=/venv/bin:$PATH \
    TEFLON_DELEGATE=/usr/local/lib/libteflon.so

ENTRYPOINT ["/venv/bin/python"]
CMD ["/opt/classify.py"]