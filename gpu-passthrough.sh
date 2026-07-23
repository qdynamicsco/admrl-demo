#!/bin/sh
# /etc/init.d/S99gpu-passthrough
GPU="0000:00:02.0"
ID="8086 3e92"

case "$1" in
  start)
    echo "Unbinding host consoles and framebuffer..."
    echo 0 > /sys/class/vtconsole/vtcon0/bind 2>/dev/null
    echo 0 > /sys/class/vtconsole/vtcon1/bind 2>/dev/null
    echo efi-framebuffer.0 > /sys/bus/platform/drivers/efi-framebuffer/unbind 2>/dev/null

    echo "Binding to VFIO..."
    echo $GPU > /sys/bus/pci/devices/$GPU/driver/unbind 2>/dev/null
    modprobe vfio-pci
    echo "$ID" > /sys/bus/pci/drivers/vfio-pci/new_id
    ;;
  stop)
    echo $GPU > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null
    echo "$ID" > /sys/bus/pci/drivers/vfio-pci/remove_id 2>/dev/null
    modprobe i915
    ;;
esac