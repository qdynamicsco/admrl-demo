#!/bin/bash

# A generic function to bind a device to vfio-pci
bind_to_vfio() {
    local dev=$1
    local vendor=$(cat /sys/bus/pci/devices/$dev/vendor 2>/dev/null)
    local device=$(cat /sys/bus/pci/devices/$dev/device 2>/dev/null)
    
    # Strip the '0x' prefix
    local v_id="${vendor#0x}"
    local d_id="${device#0x}"

    local driver_path="/sys/bus/pci/devices/$dev/driver"
    local orig_driver="none"

    if [ -e "$driver_path" ]; then
        orig_driver=$(basename $(readlink "$driver_path"))
        
        # Prevent saving 'vfio-pci' as native driver if script is run twice
        if [ "$orig_driver" = "vfio-pci" ]; then
            echo "Warning: $dev is already bound to vfio-pci. Preserving state."
            orig_driver="none"
        else
            # Unbind from current host driver
            echo "$dev" > "$driver_path/unbind" 2>/dev/null || true
        fi
    fi

    # Save precisely 4 fields: PCI-ADDR VENDOR DEVICE NATIVE-DRIVER
    echo "$dev $v_id $d_id $orig_driver" >> /tmp/vfio_state_list

    # Bind to VFIO
    echo "$v_id $d_id" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || true
}

case "$1" in
  start)
    # Empty legacy states
    rm -f /tmp/vfio_state_list /tmp/vfio_gpu_pci /tmp/vfio_usb_pci

    # Auto-find Intel GPU (VGA/Display Controller from Vendor 8086)
    GPU_PCI=$(lspci -D -nn | awk '/[Vv][Gg][Aa]|[Dd][Ii][Ss][Pp][Ll][Aa][Yy]/ && /8086:/ {print $1; exit}')
    
    # Auto-find Primary USB Controller
    USB_PCI=$(lspci -D -nn | awk '/[Uu][Ss][Bb] [Cc]ontroller/ {print $1; exit}')

    if [ -z "$GPU_PCI" ] || [ -z "$USB_PCI" ]; then
        echo "Error: Could not auto-detect GPU ($GPU_PCI) or USB Controller ($USB_PCI)"
        exit 1
    fi

    echo "Found Intel GPU at $GPU_PCI"
    echo "Found USB Controller at $USB_PCI"

    echo "$GPU_PCI" > /tmp/vfio_gpu_pci
    echo "$USB_PCI" > /tmp/vfio_usb_pci

    echo "Unbinding host consoles and framebuffer..."
    echo 0 > /sys/class/vtconsole/vtcon0/bind 2>/dev/null || true
    echo 0 > /sys/class/vtconsole/vtcon1/bind 2>/dev/null || true
    echo efi-framebuffer.0 > /sys/bus/platform/drivers/efi-framebuffer/unbind 2>/dev/null || true

    modprobe vfio-pci

    # Bind devices to VFIO
    bind_to_vfio "$GPU_PCI"
    bind_to_vfio "$USB_PCI"
    ;;
    
  stop)
    if [ -f /tmp/vfio_state_list ]; then
        echo "Restoring hardware to host natively..."
        
        # Read the 4 distinct fields
        while read -r dev v_id d_id orig_driver; do
            echo "Unbinding $dev from vfio-pci..."
            echo "$v_id $d_id" > /sys/bus/pci/drivers/vfio-pci/remove_id 2>/dev/null || true
            echo "$dev" > /sys/bus/pci/devices/$dev/driver/unbind 2>/dev/null || true
            
            # Rebind to host only if it's not a generic 'none' or 'vfio-pci' duplicate
            if [ "$orig_driver" != "none" ] && [ "$orig_driver" != "vfio-pci" ]; then
                echo "Rebinding $dev to $orig_driver..."
                modprobe "$orig_driver" 2>/dev/null || true
                echo "$dev" > "/sys/bus/pci/drivers/$orig_driver/bind" 2>/dev/null || true
            fi
        done < /tmp/vfio_state_list
        rm -f /tmp/vfio_state_list
    fi
    ;;
esac