#!/bin/sh
unclutter -idle 0.01 -root &
openbox &
exec dbus-launch --exit-with-session /opt/doohly-player.AppImage --no-sandbox