#!/bin/sh

set -eu

init_system=$(cat /etc/volatoo/init-system)
case $init_system in
	openrc)
		# The official stage3 OCI source identifies itself as a container. The
		# image produced here boots directly on a kernel.
		sed -i '/^rc_sys="docker"$/d' /etc/rc.conf
		# Keep a normal, password-protected serial console available on
		# headless systems. The prototype's auto-login remains forbidden.
		sed -i \
			's|^#s0:12345:respawn:/sbin/agetty -L 115200 ttyS0 vt100$|s0:12345:respawn:/sbin/agetty -L 115200 ttyS0 vt100|' \
			/etc/inittab
		# sysklogd-2.7.2 installs syslogd in /usr/bin for merged-usr but its
		# OpenRC service still references /usr/sbin.
		sed -i \
			's|^command="/usr/sbin/syslogd"$|command="/usr/bin/syslogd"|' \
			/etc/init.d/sysklogd
		;;
	systemd)
		mkdir -p /etc/systemd/system/multi-user.target.wants
		for service in dhcpcd sshd volatoo-persist; do
			ln -sfn \
				"/usr/lib/systemd/system/${service}.service" \
				"/etc/systemd/system/multi-user.target.wants/${service}.service"
		done
		;;
	*)
		echo "error: unsupported Volatoo init system: $init_system" >&2
		exit 1
		;;
esac

# Host keys are machine identity and must be generated or restored at boot.
rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub

# A release image must never inherit the prototype's serial root auto-login.
if [ -f /etc/inittab ]; then
	sed -i \
		's|^s0:12345:respawn:/sbin/agetty --autologin root -L 115200 ttyS0 vt100$|s0:12345:respawn:/sbin/agetty -L 115200 ttyS0 vt100|' \
		/etc/inittab

	if grep -q -- '--autologin' /etc/inittab; then
		echo "error: an auto-login getty remains in /etc/inittab" >&2
		exit 1
	fi
fi
