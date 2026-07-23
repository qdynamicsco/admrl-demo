#!/bin/bash
set -e

# Download Puppy Linux (Fossapup) - ~400MB
ISO_PATH="/data/puppy.iso"
if [ ! -f "$ISO_PATH" ]; then
    echo "Small GUI ISO not found. Downloading..."
    wget -O "$ISO_PATH" https://distro.ibiblio.org/puppylinux/puppy-fossa/fossapup64-9.5.iso
fi

# Run your passthrough script
echo "Starting GPU passthrough script..."
/usr/local/bin/gpu-passthrough.sh start

# Logitech receiver
LOGITECH_VENDOR="0x046d"
LOGITECH_PRODUCT="0xc534"

# Uncap locked memory limit for VFIO DMA mapping
ulimit -l unlimited

echo "Starting QEMU..."
exec qemu-system-x86_64 \
    -enable-kvm \
    -m 4G \
    -cpu host \
    -smp 4 \
    -M pc \
    -vga none -display none \
    -nic none \
    -device vfio-pci,host=00:02.0,bus=pci.0,addr=0x02,x-igd-opregion=on,x-vga=on,rombar=0 \
    -device qemu-xhci,id=xhci \
    -device usb-host,vendorid=$LOGITECH_VENDOR,productid=$LOGITECH_PRODUCT \
    -cdrom "$ISO_PATH" \
    -boot d