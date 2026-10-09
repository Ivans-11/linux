#!/bin/sh

export PATH=/bin:/sbin:/usr/bin:/usr/sbin
/bin/busybox mkdir -p /proc /sys /dev
/bin/busybox mount -t devtmpfs devtmpfs /dev
exec </dev/console >/dev/console 2>&1
/bin/busybox --install -s >/dev/null 2>&1

fail()
{
	echo "aarch64 static linux test fail: $*"
	exit 1
}

mountpoint -q /proc || mount -t proc proc /proc || fail "cannot mount procfs"
mountpoint -q /sys || mount -t sysfs sysfs /sys || fail "cannot mount sysfs"

cpu_count=$(grep -c '^processor' /proc/cpuinfo)
[ "$cpu_count" -eq 4 ] || fail "expected 4 CPUs, found $cpu_count"
[ "$(cat /sys/devices/system/cpu/online)" = "0-3" ] ||
	fail "unexpected online CPU set: $(cat /sys/devices/system/cpu/online)"

for cpu in 0 1 2 3; do
	actual=$(taskset -c "$cpu" sh -c 'cat /proc/self/stat' | awk '{print $39}') ||
		fail "cannot run a task on CPU $cpu"
	[ "$actual" -eq "$cpu" ] || fail "task requested CPU $cpu but ran on CPU $actual"
done

before=$(cut -d. -f1 /proc/uptime)
sleep 1
after=$(cut -d. -f1 /proc/uptime)
[ "$after" -gt "$before" ] || fail "architectural timer did not advance"

echo "aarch64 static linux test pass!"
exec /bin/sh
