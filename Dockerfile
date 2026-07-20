# =============================================
# Home Assistant Supervised + DinD (ARM64 + AMD64)
# =============================================

FROM docker:29.6.2-dind-alpine3.24 AS dind

# Install dependencies
RUN apk add --no-cache \
    bash \
    curl \
    jq \
    dbus \
    udev \
    eudev \
    tzdata \
    && rm -rf /var/cache/apk/*

# Create directories
RUN mkdir -p /usr/share/hassio /var/lib/docker /run/dbus /etc/docker

# Configure Docker for dynamic MTU safety, high concurrency, and disabled nesting features
RUN echo '{"max-concurrent-downloads": 10, "mtu": 1400, "features": {"containerd-snapshotter": false}}' > /etc/docker/daemon.json

# Copy startup script
COPY startup.sh /usr/local/bin/startup.sh
RUN chmod +x /usr/local/bin/startup.sh

EXPOSE 8123

VOLUME ["/usr/share/hassio", "/var/lib/docker"]

ENV \
    TZ=UTC \
    SUPERVISOR_SHARE=/usr/share/hassio \
    SUPERVISOR_NAME=hassio_supervisor

ENTRYPOINT ["/usr/local/bin/startup.sh"]