FROM debian:trixie

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:0
ENV HOME=/root
ENV XDG_RUNTIME_DIR=/tmp/xdg

# Define AppImage Base URL
ENV APPIMAGE_VERSION="5.9.16"
ENV APPIMAGE_PATH="/opt/doohly-player.AppImage"

# Use build arguments to determine architecture
ARG TARGETARCH

# Install necessary packages, then remove unnecessary ones
RUN apt-get update && apt-get install -y \
    xserver-xorg-core \
    xinit \
    openbox \
    openssh-server \
    dbus \
    dbus-x11 \
    udev \
    sudo \
    fonts-noto \
    mesa-utils \
    libgl1-mesa-dri \
    $( [ "$(dpkg --print-architecture)" = "amd64" ] && echo "intel-media-va-driver i965-va-driver" ) \
    mesa-va-drivers \
    mesa-vulkan-drivers \
    vainfo \
    python3-xdg \
    zlib1g-dev \
    unclutter \
    fuse \
    libfuse2 \
    libnss3 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libgtk-3-0 \
    libasound2 \
    alsa-utils \
    curl \
    ca-certificates \
    --no-install-recommends \
    && apt-get purge -y --auto-remove system-config-printer at-spi2-core \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Download appropriate AppImage based on architecture
RUN if [ "$TARGETARCH" = "arm64" ]; then \
        URL="https://doohly-production-static.s3.ap-southeast-2.amazonaws.com/installers/linux/${APPIMAGE_VERSION}/arm64/doohly-player-v${APPIMAGE_VERSION}-arm64.AppImage"; \
    else \
        URL="https://doohly-production-static.s3.ap-southeast-2.amazonaws.com/installers/linux/${APPIMAGE_VERSION}/x86_64/doohly-player-v${APPIMAGE_VERSION}-x86_64.AppImage"; \
    fi; \
    curl -L -o ${APPIMAGE_PATH} "${URL}" && chmod +x ${APPIMAGE_PATH}

# Add user to necessary groups for hardware access
RUN usermod -a -G video,render,input,audio root

# SSH Configuration
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh
ADD https://github.com/danward.keys /root/.ssh/authorized_keys
ADD https://github.com/alexanderturner.keys /root/.ssh/authorized_keys_alex
RUN cat /root/.ssh/authorized_keys_alex >> /root/.ssh/authorized_keys && \
    rm /root/.ssh/authorized_keys_alex && \
    chown root:root /root/.ssh/authorized_keys && \
    chmod 600 /root/.ssh/authorized_keys
RUN sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config

# Openbox Configuration for Kiosk Mode
# Moved to system-wide config (/etc/xdg/openbox) to keep /root/.config reserved for AppImage
RUN mkdir -p /etc/xdg/openbox
COPY rc.xml /etc/xdg/openbox/rc.xml

# Xinit Configuration
COPY xinitrc /root/.xinitrc
RUN chmod +x /root/.xinitrc

# Start Script
COPY start.sh /start.sh
RUN chmod +x /start.sh

# Set the entrypoint
CMD ["/start.sh"]
