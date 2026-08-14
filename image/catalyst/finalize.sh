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
		# OpenSSH is also installed below /usr/bin on merged-usr images.
		sed -i \
			's|/usr/sbin/sshd}|/usr/bin/sshd}|' \
			/etc/init.d/sshd
		if grep -q '/usr/sbin/sshd' /etc/init.d/sshd; then
			echo "error: OpenRC sshd still references /usr/sbin/sshd" >&2
			exit 1
		fi
		;;
	systemd)
		# Gentoo's OpenSSH units still reference the pre-merged-usr path.
		for ssh_unit in sshd.service sshd@.service; do
			sed -i 's|/usr/sbin/sshd|/usr/bin/sshd|g' \
				"/usr/lib/systemd/system/$ssh_unit"
		done
		if grep -q '/usr/sbin/sshd' \
			/usr/lib/systemd/system/sshd.service \
			/usr/lib/systemd/system/sshd@.service; then
			echo "error: systemd sshd units still reference /usr/sbin/sshd" >&2
			exit 1
		fi
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

if [ -e /usr/bin/signify ] || [ -L /usr/bin/signify ]; then
	if [ ! -x /usr/bin/signify ] || [ -L /usr/bin/signify ]; then
		echo "error: packaged signify wrapper is missing or unsafe" >&2
		exit 1
	fi
	set +e
	/usr/bin/signify -h >/dev/null 2>&1
	signify_status=$?
	set -e
	if [ "$signify_status" -ne 1 ]; then
		echo "error: packaged signify runtime failed its help probe" >&2
		exit 1
	fi
fi

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
