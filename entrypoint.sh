#!/bin/bash
set -e

ISO_PATH="/data/Win11_25H2_English_x64_v2.iso"
DISK_PATH="/data/win11_disk.qcow2"

if [ ! -f "$ISO_PATH" ]; then
    echo "ERROR: Windows 11 ISO not found at $ISO_PATH!"
    echo "Please download it and place it in your /data mount."
    exit 1
fi

# Create a 64GB virtual hard drive for the installation if it doesn't exist
if [ ! -f "$DISK_PATH" ]; then
    echo "Creating 64GB virtual hard drive for Windows 11..."
    qemu-img create -f qcow2 "$DISK_PATH" 64G
fi

VIRTIO_ISO="/data/virtio-win.iso"
if [ ! -f "$VIRTIO_ISO" ]; then
    echo "Downloading VirtIO Drivers..."
    wget -q -O "$VIRTIO_ISO" https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso
fi

# Run your passthrough script (Starts VFIO)
echo "Starting GPU/USB passthrough script..."
/usr/local/bin/gpu-passthrough.sh start

# Read the automatically discovered PCI addresses
GPU_PCI=$(cat /tmp/vfio_gpu_pci)
USB_PCI=$(cat /tmp/vfio_usb_pci)

# Uncap locked memory limit
ulimit -l unlimited

# Setup Virtual TPM 2.0
echo "Starting software TPM..."

# --- NEW: Kill zombie TPMs and wipe the old locked directory ---
killall swtpm 2>/dev/null || true
rm -rf /tmp/mytpm
mkdir -p /tmp/mytpm

swtpm socket --tpmstate dir=/tmp/mytpm --ctrl type=unixio,path=/tmp/mytpm/swtpm-sock --tpm2 &
SWTPM_PID=$!

# Give swtpm a second to create its socket file before QEMU looks for it
sleep 1 

# Use the Microsoft Secure Boot enrolled firmware
# Copy locally so NVRAM is persistent and writable
if [ ! -f "/data/OVMF_VARS_4M.ms.fd" ]; then
    echo "Copying SecureBoot NVRAM..."
    cp /usr/share/OVMF/OVMF_VARS_4M.ms.fd /data/OVMF_VARS_4M.ms.fd
fi

# Clean-up function on container SIGTERM / SIGINT
cleanup() {
    echo "Caught SIGTERM! Gracefully stopping..."
    if kill -0 $QEMU_PID 2>/dev/null; then
        kill -TERM $QEMU_PID
        wait $QEMU_PID
    fi
    if kill -0 $SWTPM_PID 2>/dev/null; then
        kill -TERM $SWTPM_PID
    fi
    echo "Rebinding hardware to host..."
    /usr/local/bin/gpu-passthrough.sh stop
    exit 0
}

trap cleanup SIGTERM SIGINT

echo "Starting QEMU Windows 11..."
qemu-system-x86_64 \
    -enable-kvm \
    -m 6G \
    -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time,kvm=off,hv_vendor_id=Null12345678 \
    -smp 4 \
    -M q35,smm=on \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.ms.fd \
    -drive if=pflash,format=raw,file=/data/OVMF_VARS_4M.ms.fd \
    -chardev socket,id=chrtpm,path=/tmp/mytpm/swtpm-sock \
    -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-tis,tpmdev=tpm0 \
    -vga none -display none \
    -netdev user,id=net0 \
    -device e1000e,netdev=net0,addr=0x08 \
    -device vfio-pci,host=${GPU_PCI},bus=pcie.0,addr=0x02,x-igd-opregion=on,rombar=0 \
    -device vfio-pci,host=${USB_PCI} \
    -drive file="$DISK_PATH",format=qcow2,if=virtio \
    -cdrom "$ISO_PATH" \
    -drive file="$VIRTIO_ISO",media=cdrom \
    -boot d &

# Get QEMU PID and wait for it to exit
QEMU_PID=$!
wait $QEMU_PID

# Clean up natively if QEMU shuts down from inside Windows
kill -TERM $SWTPM_PID 2>/dev/null || true
/usr/local/bin/gpu-passthrough.sh stop