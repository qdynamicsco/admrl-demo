#!/bin/bash

# Cleanup old state (if restarted)
rm -f /tmp/.X0-lock
rm -rf /tmp/xdg

# Create required runtime directories
mkdir -p /run/sshd
mkdir -p /run/dbus
mkdir -p -m 0700 /tmp/xdg

# Start essential services
/usr/sbin/sshd
dbus-uuidgen --ensure
service dbus start

# Exec xinit in foreground; when player/X exits, container exits
exec xinit /root/.xinitrc -- /usr/bin/X :0 -nocursor -s 0 -dpms