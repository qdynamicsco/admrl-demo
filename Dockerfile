FROM ubuntu:26.04

# Install QEMU, KVM utilities, kernel module tools, firmware, usbutils and wget
RUN apt-get update && apt-get install -y \
    qemu-system-x86 \
    qemu-utils \
    kmod \
    pciutils \
    usbutils \
    wget \
    ovmf \
    && rm -rf /var/lib/apt/lists/*

# Create directory for the ISO
RUN mkdir /data

COPY gpu-passthrough.sh /usr/local/bin/gpu-passthrough.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/gpu-passthrough.sh /usr/local/bin/entrypoint.sh

EXPOSE 5900

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]