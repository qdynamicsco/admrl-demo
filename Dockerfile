FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive

# Install standard graphics stack
# - libgl1-mesa-dri: Contains the 'panfrost' driver for RK3399
# - libgles2-mesa: OpenGL ES 2/3 libraries
# - libgbm1: Generic Buffer Management
# - kmscube: The test tool
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    # SSH Server
    openssh-server \
    # MESA/GPU support
    libgl1-mesa-dri \
    libgles2 \
    libegl1 \
    libgbm1 \
    mesa-utils \
    # Workload
    cage \
    chromium \
    # Basic utilities
    ca-certificates \
    nano \
    udev \
    wget \
    # Clean up APT cache
    && rm -rf /var/lib/apt/lists/*

# Add user to video/render groups
RUN usermod -a -G video,render root

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