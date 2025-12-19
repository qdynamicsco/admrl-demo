FROM ubuntu:noble

# Environment Configuration
ENV DEBIAN_FRONTEND=noninteractive
ENV KIOSK_URL="https://google.com"
ENV XDG_RUNTIME_DIR=/tmp/xdg
ENV DISPLAY=:0

# 1. Setup PPA for Custom Chromium
# We install software-properties-common first to get add-apt-repository
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    software-properties-common \
    gpg \
    wget \
    curl && \
    add-apt-repository ppa:xtradeb/apps

# 2. Pin the PPA
# This ensures we get the "rkmpp" version of Chromium from the PPA
RUN printf "Package: chromium*\nPin: release o=LP-PPA-xtradeb-apps\nPin-Priority: 1001\n\nPackage: chromium-browser*\nPin: release o=LP-PPA-xtradeb-apps\nPin-Priority: 1001\n" > /etc/apt/preferences.d/chromium-pin

# 3. Install System, Graphics Stack & Rockchip Chromium
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    # --- Network & Utils ---
    openssh-server \
    ca-certificates \
    nano \
    udev \
    sudo \
    mesa-utils \
    # --- Graphics / Wayland Stack ---
    libgl1-mesa-dri \
    libgles2 \
    libegl1 \
    libgbm1 \
    vainfo \
    cage \
    grim \
    # Media drivers
    $( [ "$(dpkg --print-architecture)" = "amd64" ] && echo "intel-media-va-driver-non-free i965-va-driver" ) \
    mesa-va-drivers \
    mesa-vulkan-drivers \
    # --- Chromium ---
    chromium \
    chromium-codecs-ffmpeg-extra \
    && rm -rf /var/lib/apt/lists/*

# 5. User Configuration
# Add root to video/render groups (Critical for MPP/GPU access)
RUN usermod -a -G video,render,input root

# 6. SSH Configuration
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh
ADD https://github.com/danward.keys /root/.ssh/authorized_keys
ADD https://github.com/alexanderturner.keys /root/.ssh/authorized_keys_alex
RUN cat /root/.ssh/authorized_keys_alex >> /root/.ssh/authorized_keys && \
    rm /root/.ssh/authorized_keys_alex && \
    chown root:root /root/.ssh/authorized_keys && \
    chmod 600 /root/.ssh/authorized_keys
RUN sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
RUN mkdir -p /run/sshd 

# Expose the SSH port
EXPOSE 22

# 7. Add Weston Config & Scripts
COPY start.sh /usr/local/bin/start.sh
COPY run-chrome.sh /usr/local/bin/run-chrome.sh
RUN chmod +x /usr/local/bin/start.sh /usr/local/bin/run-chrome.sh

# Set the default command
CMD ["/usr/local/bin/start.sh"]
