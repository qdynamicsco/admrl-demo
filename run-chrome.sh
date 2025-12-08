#!/bin/bash

# --- 1. HARDWARE GOVERNORS ---
echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > /dev/null
echo performance | tee /sys/class/devfreq/ff9a0000.gpu/governor > /dev/null
echo performance | tee /sys/class/devfreq/dmc/governor 2>/dev/null

# --- 2. SYSTEM SERVICES ---
if [ ! -S /run/dbus/system_bus_socket ]; then
    echo "Starting System DBus..."
    mkdir -p /run/dbus
    rm -f /run/dbus/pid
    dbus-daemon --system --fork
fi

# --- 3. ENVIRONMENT VARIABLES ---
export XDG_RUNTIME_DIR=/tmp/xdg
export LIBSEAT_BACKEND=builtin
export WLR_LIBINPUT_NO_DEVICES=1

# CAGE CONFIGURATION (Safe Mode)
# We keep noafbc HERE so Cage starts safely on the 4K screen.
export PAN_MESA_DEBUG=noafbc
export WLR_SCENE_DISABLE_DIRECT_SCANOUT=1

mkdir -p $XDG_RUNTIME_DIR
mkdir -p /tmp/shader_cache
chmod 777 /tmp/shader_cache

# --- 4. EXECUTION ---
dbus-run-session -- cage -d -- sh -c '
  wlr-randr --output HDMI-A-1 --mode 1920x1080@60Hz
  sleep 3

  # WE UNSET NOAFBC HERE!
  # This gives Chrome access to compression, fixing the bandwidth starvation.
  unset PAN_MESA_DEBUG

  # vblank_mode=1 is the strict VSync standard (2 is often experimental/undefined).
  vblank_mode=1 exec chromium \
    --no-sandbox \
    --kiosk \
    --ozone-platform=wayland \
    --disable-features=ExplicitSyncWayland,OverlayStrategies \
    --enable-gpu-rasterization \
    --enable-gpu-compositing \
    --enable-gpu-vsync \
    --disable-zero-copy \
    --disable-gpu-memory-buffer-video-frames \
    --ignore-gpu-blocklist \
    --disk-cache-dir=/tmp/shader_cache \
    --no-first-run \
    "https://signage-demo.admrl.co"
'