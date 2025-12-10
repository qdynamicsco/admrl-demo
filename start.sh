#!/bin/sh

# Exit immediately if a command exits with a non-zero status.
set -e

# Chain our script to launch chrome, but we don't care if it exits
/usr/local/bin/run-chrome.sh &

# Create the sshd runtime directory if it doesn't exist.
# This is necessary because /run is a tmpfs that is empty on boot.
echo "Creating /run/sshd directory for SSH daemon..."
mkdir -p /run/sshd
chmod 0755 /run/sshd

echo "Starting SSH daemon in the foreground..."
# Use "exec" to replace the shell process with the sshd process.
# This is important for proper signal handling.
exec /usr/sbin/sshd -D