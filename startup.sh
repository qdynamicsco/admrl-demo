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

# Ensure udev directory exists for supervisor/homeassistant bind mounts
mkdir -p /run/udev /run/supervisor

# Fake IPv6 procfs if unsupported by host kernel to prevent Docker network creation crashes
if [ ! -d /proc/sys/net/ipv6 ]; then
    echo "Faking IPv6 procfs for Docker compatibility..."
    mkdir -p /tmp/real_net /tmp/mock_ipv6
    mount --bind /proc/sys/net /tmp/real_net
    mount -t tmpfs tmpfs /proc/sys/net

    # Symlink all other items back to real procfs
    for item in /tmp/real_net/*; do
        [ -e "$item" ] || continue
        name=$(basename "$item")
        ln -s "$item" "/proc/sys/net/$name"
    done

    # Remove the broken symlink to real non-existent ipv6 and create fake directory
    rm -f /proc/sys/net/ipv6
    mkdir -p /proc/sys/net/ipv6

    # Populate mock IPv6 entries recursively
    echo "1" > /tmp/mock_ipv6/disable_ipv6
    echo "0" > /tmp/mock_ipv6/accept_ra
    for link in conf all default lo docker0 hassio; do
        ln -s . /tmp/mock_ipv6/$link
    done
    for i in $(seq 0 9); do
        ln -s . /tmp/mock_ipv6/br-0$i
        ln -s . /tmp/mock_ipv6/veth0$i
    done

    mount --bind /tmp/mock_ipv6 /proc/sys/net/ipv6
    echo "✅ IPv6 procfs faked."
fi

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
    sleep 3
    timeout=$((timeout-3))
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