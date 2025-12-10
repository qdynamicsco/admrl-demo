#!/bin/bash

# --- 1. HARDWARE INIT ---
/usr/lib/systemd/systemd-udevd --daemon
udevadm trigger
udevadm settle

# --- 2. SYSTEM SERVICES ---
if [ ! -S /run/dbus/system_bus_socket ]; then
    echo "Starting System DBus..."
    mkdir -p /run/dbus
    rm -f /run/dbus/pid
    dbus-daemon --system --fork
fi

# --- 3. ENVIRONMENT VARIABLES ---
export XDG_RUNTIME_DIR=/tmp/xdg
export WLR_BACKENDS=drm
export LIBSEAT_BACKEND=builtin
export WLR_LIBINPUT_NO_DEVICES=1

mkdir -p $XDG_RUNTIME_DIR
chmod 0700 $XDG_RUNTIME_DIR

: "${KIOSK_URL:=https://thank-you.admrl.co}"

# --- 4. EXECUTION ---
exec dbus-run-session -- cage -- sh -c '
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
    "${KIOSK_URL}"
'
