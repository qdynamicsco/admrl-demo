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

# Build Mesa / Teflon.
# Attempts building with -Dgallium-drivers=rocket first (the upstream path).
# If Mesa has re-arranged the options, falls back to llvmpipe with Teflon enabled.
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

# Auto-detect exact Debian runtime packages required by libteflon.so
# (Avoids hardcoding package names like libelf1 vs libelf1t64 across Debian releases)
RUN set -eux; \
    ldd /out/usr/local/lib/libteflon.so \
      | awk '/=> \//{print $3}' \
      | xargs -r -n1 realpath \
      | sort -u \
      | xargs -r dpkg-query -S 2>/dev/null \
      | cut -d: -f1 | tr ',' '\n' | tr -d ' ' \
      | sort -u > /out/runtime-deps.txt; \
    cat /out/runtime-deps.txt

# Build Python Virtual Environment with TFLite Runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3-venv python3-pip curl \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /venv \
 && /venv/bin/pip install --no-cache-dir --upgrade pip \
 && /venv/bin/pip install --no-cache-dir numpy pillow \
 && ( /venv/bin/pip install --no-cache-dir tflite-runtime \
      || /venv/bin/pip install --no-cache-dir ai-edge-litert ) \
 && /venv/bin/python -c 'import numpy, PIL; \
      exec("try:\n from tflite_runtime.interpreter import Interpreter\nexcept ImportError:\n from ai_edge_litert.interpreter import Interpreter")'

# Bake model & sample image assets into the image
WORKDIR /assets
RUN set -eux; \
    B=https://storage.googleapis.com/download.tensorflow.org; \
    curl -fsSL $B/models/mobilenet_v1_1.0_224_quant.tgz \
        | tar xz mobilenet_v1_1.0_224_quant.tflite; \
    curl -fsSLo labels.txt $B/data/ImageNetLabels.txt; \
    curl -fsSLo sample.jpg $B/example_images/YellowLabradorLooking_new.jpg


# ==============================================================================
# STAGE 2: Runtime
# ==============================================================================
FROM ${DEBIAN_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive

# Copy dynamically discovered dependencies from builder and install them
COPY --from=builder /out/runtime-deps.txt /tmp/runtime-deps.txt

RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 $(tr '\n' ' ' < /tmp/runtime-deps.txt) \
    && rm -rf /var/lib/apt/lists/* /tmp/runtime-deps.txt

# Copy artifacts from builder
COPY --from=builder /out/usr/local/lib/libteflon.so /usr/local/lib/
COPY --from=builder /venv   /venv
COPY --from=builder /assets /opt/assets
COPY --from=builder /mesa.sha /gallium.driver /etc/

# Verify runtime shared library integrity
RUN ldconfig \
 && ldd /usr/local/lib/libteflon.so \
 && ! ldd /usr/local/lib/libteflon.so | grep -q 'not found'

COPY classify.py /opt/classify.py

ENV PATH=/venv/bin:$PATH \
    TEFLON_DELEGATE=/usr/local/lib/libteflon.so

ENTRYPOINT ["python3", "/opt/classify.py"]