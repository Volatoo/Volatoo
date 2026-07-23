#!/bin/sh

set -eu

# The official stage3 OCI source identifies itself as a container. The image
# produced here boots directly on a kernel.
sed -i '/^rc_sys="docker"$/d' /etc/rc.conf

# Host keys are machine identity and must be generated or restored at boot.
rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub

# A release image must never inherit the prototype's serial root auto-login.
sed -i \
	's|^s0:12345:respawn:/sbin/agetty --autologin root -L 115200 ttyS0 vt100$|s0:12345:respawn:/sbin/agetty -L 115200 ttyS0 vt100|' \
	/etc/inittab

if grep -q -- '--autologin' /etc/inittab; then
	echo "error: an auto-login getty remains in /etc/inittab" >&2
	exit 1
fi
