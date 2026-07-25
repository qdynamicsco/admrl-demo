FROM ubuntu:26.04

RUN apt-get update && apt-get install -y \
    qemu-system-x86 \
    qemu-utils \
    kmod \
    pciutils \
    usbutils \
    wget \
    ovmf \
    swtpm \
    vim \
    nano \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir /data

COPY gpu-passthrough.sh /usr/local/bin/gpu-passthrough.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/gpu-passthrough.sh /usr/local/bin/entrypoint.sh

EXPOSE 5900

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]