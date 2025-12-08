#!/bin/bash

# --- 1. HARDWARE GOVERNORS (Prevents "Square Blocks" on startup) ---
# Force CPU and GPU to max freq to handle Chrome's initialization burst
echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > /dev/null
echo performance | tee /sys/class/devfreq/ff9a0000.gpu/governor > /dev/null
echo performance | tee /sys/class/devfreq/dmc/governor 2>/dev/null

# --- 2. SYSTEM SERVICES (Fixes DBus/UPower Timeouts) ---
# Check if system DBus is running. If not, start it manually.
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

# GRAPHICS PIPELINE FIXES (The "Best So Far" Combo):
# 1. Disable Direct Scanout -> Forces Cage to finish the frame (Sync Stability)
export WLR_SCENE_DISABLE_DIRECT_SCANOUT=1
# 2. Force Linear/Simple Buffer Layouts -> Prevents Scanout Confusion
export PAN_MESA_DEBUG=noafbc
# 3. Triple Buffering -> Absorbs frame-time jitter (16ms latency trade-off)
export MESA_BACK_BUFFER_SYNC=1

# SHADER CACHE (Fixes Stutter; Updated variable names)
export MESA_SHADER_CACHE_DIR=/tmp/shader_cache
export MESA_SHADER_CACHE_MAX_SIZE=100M

mkdir -p $XDG_RUNTIME_DIR
mkdir -p /tmp/shader_cache
chmod 777 /tmp/shader_cache

# --- 4. EXECUTION ---
# We wrap in dbus-run-session to provide the Session Bus.
# We rely on the System Bus started above for Power/Network calls.

dbus-run-session -- cage -d -- sh -c '
  wlr-randr --output HDMI-A-1 --mode 1920x1080@60Hz
  # Increased sleep slightly to ensure mode-switch settles
  sleep 3

  # The Magic Chrome Command
  vblank_mode=2 chromium \
    --no-sandbox \
    --kiosk \
    --ozone-platform=wayland \
    --disable-features=ExplicitSyncWayland \
    --enable-gpu-rasterization \
    --enable-gpu-compositing \
    --disable-gpu-vsync \
    --ignore-gpu-blocklist \
    --disk-cache-dir=/tmp/shader_cache \
    --no-first-run \
    "https://signage-demo.admrl.co"
'