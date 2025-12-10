#!/bin/bash

# --- 1. HARDWARE INIT ---
udevadm trigger
udevadm settle

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
  --enable-features=VaapiVideoDecoder,VaapiVideoEncoder,CanvasOopRasterization \
  --enable-gpu-rasterization \
  --enable-zero-copy \
  --ignore-gpu-blocklist \
  --disable-gpu-driver-bug-workarounds \
  "https://signage-demo.admrl.co"