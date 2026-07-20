#!/bin/bash
set -e

echo "=== Home Assistant Supervised + DinD (ARM64 Optimized) ==="

# Architecture detection
ARCH=$(uname -m)
case $ARCH in
    x86_64|amd64) 
        HA_ARCH="amd64"
        HA_MACHINE="qemux86-64"
        ;;
    aarch64|arm64) 
        HA_ARCH="aarch64"
        HA_MACHINE="qemuarm-64"
        ;;
    *) echo "ERROR: Unsupported arch: $ARCH"; exit 1 ;;
esac

echo "Detected: $ARCH → $HA_ARCH ($HA_MACHINE)"

# Ensure udev and dbus directories exist
mkdir -p /run/udev /run/supervisor /run/dbus /var/run/dbus

# Share D-Bus socket path between nested structures
ln -sf /var/run/dbus/system_bus_socket /run/dbus/system_bus_socket

# Check if a live host D-Bus system daemon is already mounted/functional
if dbus-send --system --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1; then
    echo "✅ Active Host D-Bus detected. Sharing host message bus."
else
    echo "No active D-Bus connection. Cleaning stale sockets and starting local D-Bus..."
    rm -f /run/dbus/system_bus_socket /var/run/dbus/system_bus_socket || true
    dbus-uuidgen --ensure
    dbus-daemon --system --fork
fi

# Start udevd daemon for hardware event propagation
echo "Starting udevd..."
udevd --daemon || true

# Start Docker daemon
echo "Starting Docker daemon..."
/usr/local/bin/dockerd-entrypoint.sh &

# Wait for Docker
timeout=120
until docker info >/dev/null 2>&1; do
    if [ $timeout -le 0 ]; then
        echo "ERROR: Docker failed to start"
        exit 1
    fi
    echo "Waiting for Docker daemon... ($timeout s)"
    sleep 1
    timeout=$((timeout-1))
done

echo "✅ Docker daemon ready."

# Clean up old container
echo "Cleaning up old Supervisor container..."
docker rm -f hassio_supervisor 2>/dev/null || true

# Start Supervisor
SUPERVISOR_IMAGE="ghcr.io/home-assistant/${HA_ARCH}-hassio-supervisor:latest"

echo "Starting Supervisor: $SUPERVISOR_IMAGE"

docker run -d \
    --name hassio_supervisor \
    --privileged \
    --security-opt seccomp=unconfined \
    -v /run/dbus:/run/dbus:ro \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /usr/share/hassio:/data \
    -e SUPERVISOR_SHARE=/usr/share/hassio \
    -e SUPERVISOR_NAME=hassio_supervisor \
    -e SUPERVISOR_MACHINE="${HA_MACHINE}" \
    "${SUPERVISOR_IMAGE}"

echo "✅ Supervisor started!"
echo "Access HA at http://<your-ip>:8123"

docker logs -f hassio_supervisor