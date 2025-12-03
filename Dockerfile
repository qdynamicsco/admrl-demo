FROM debian:bookworm

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install SSH, EGL test utilities, and dependencies for the Mali driver
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    # SSH Server
    openssh-server \
    # EGL/GLES test utilities (es2gears_x11 is in mesa-utils-extra)
    mesa-utils \
    mesa-utils-extra \
    kmscube \
    # Dependency for the Mali .deb package
    libwayland-client0 \
    # Basic utilities
    nano \
    wget \
    ca-certificates \
    # Clean up APT cache
    && rm -rf /var/lib/apt/lists/*

# --- Mali Proprietary Driver Installation ---

    # Download and install the newer r18p0 driver
RUN wget https://github.com/tsukumijima/libmali-rockchip/releases/download/v1.9-1-2131373/libmali-midgard-t86x-r18p0-gbm_1.9-1_arm64.deb -O /tmp/mali.deb && \
    dpkg -i /tmp/mali.deb && \
    rm /tmp/mali.deb

# Add the Mali library path to the linker
RUN echo "/usr/lib/aarch64-linux-gnu/mali" > /etc/ld.so.conf.d/mali.conf && \
    ldconfig

# SSH Configuration
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

# --- Startup Script ---
# Copy the startup script into the image and make it executable
COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

# Set the default command to our startup script.
# On the real device, the init system (e.g., systemd) should be configured
# to run this script to start the SSH service.
CMD ["/usr/local/bin/start.sh"]