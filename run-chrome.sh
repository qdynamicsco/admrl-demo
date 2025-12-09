#!/bin/bash

# --- 1. HARDWARE INIT ---
udevadm trigger
udevadm settle
echo performance | tee /sys/class/devfreq/dmc/governor > /dev/null 2>&1
echo performance | tee /sys/class/devfreq/fdab0000.gpu/governor > /dev/null 2>&1

# --- 2. ENVIRONMENT ---
export XDG_RUNTIME_DIR=/tmp/xdg
export WAYLAND_DISPLAY=wayland-1
mkdir -p $XDG_RUNTIME_DIR
chmod 0700 $XDG_RUNTIME_DIR

# --- 3. START WESTON ---
if ! pgrep -x "weston" > /dev/null; then
    echo "Starting Weston..."
    weston --socket=$WAYLAND_DISPLAY --backend=drm-backend.so &
    while [ ! -e "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; do sleep 0.1; done
fi

# --- 4. START CHROMIUM ---
echo "Starting Chromium with Native PPA Flags..."

exec chromium \
  --no-sandbox \
  --ozone-platform=wayland \
  --no-first-run \
  --kiosk \
  --disk-cache-dir=/tmp/shader_cache \
  --ignore-gpu-blocklist \
  --disable-gpu-driver-bug-workarounds \
  --disable-gpu-sandbox \
  --enable-gpu-rasterization \
  --enable-features=WaylandWindowDecorations,OverlayStrategies,AcceleratedVideoDecoder,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL \
  --disable-software-rasterizer \
  "https://signage-demo.admrl.co"