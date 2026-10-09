#!/bin/sh

export PATH=/bin:/sbin:/usr/bin:/usr/sbin
/bin/busybox --install -s >/dev/null 2>&1

fail()
{
	echo "aarch64 lkvm linux test fail: $*"
	exit 1
}

mkdir -p /proc /sys /dev
mount -t proc proc /proc 2>/dev/null || fail "cannot mount procfs"
mount -t sysfs sysfs /sys 2>/dev/null || fail "cannot mount sysfs"

[ "$(uname -m)" = "aarch64" ] || fail "unexpected architecture: $(uname -m)"
[ "$(grep -c '^processor' /proc/cpuinfo)" -eq 1 ] || fail "unexpected CPU count"

poweroff -f
