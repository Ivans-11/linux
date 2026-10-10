#!/bin/sh

export PATH=/bin:/sbin:/usr/bin:/usr/sbin
/bin/busybox --install -s >/dev/null 2>&1

fail()
{
	echo "aarch64 lkvm linux test fail: $*"
	exit 1
}

mkdir -p /proc /sys /dev /mnt/rootfs /tmp
mount -t proc proc /proc 2>/dev/null || fail "cannot mount procfs"
mount -t sysfs sysfs /sys 2>/dev/null || fail "cannot mount sysfs"
mount -t devtmpfs devtmpfs /dev 2>/dev/null || fail "cannot mount devtmpfs"

[ "$(uname -m)" = "aarch64" ] || fail "unexpected architecture: $(uname -m)"
[ "$(grep -c '^processor' /proc/cpuinfo)" -eq 4 ] || fail "unexpected CPU count"

mount -t ext4 /dev/vda /mnt/rootfs 2>/dev/null || fail "cannot mount virtio block device"
echo aarch64-lkvm-disk-pass > /mnt/rootfs/axvisor-disk-test || fail "cannot write disk"
[ "$(cat /mnt/rootfs/axvisor-disk-test)" = "aarch64-lkvm-disk-pass" ] ||
	fail "disk readback mismatch"
sync
umount /mnt/rootfs || fail "cannot unmount virtio block device"

ip link set eth0 up || fail "cannot bring up virtio network device"
ip addr add 172.16.0.2/24 dev eth0 || fail "cannot configure virtio network device"
rm -f /tmp/http-probe /tmp/udp-probe
nc -u -l -p 9000 -s 172.16.0.2 -w 30 > /tmp/udp-probe &
udp_pid=$!
http_ok=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
	if wget -T 2 -q -O /tmp/http-probe http://172.16.0.1:8080/probe &&
		[ "$(cat /tmp/http-probe)" = "lkvm-network-pass" ]; then
		http_ok=1
		break
	fi
	sleep 1
done
[ "$http_ok" -eq 1 ] || fail "virtio network HTTP receive failed"

udp_ok=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
	if [ "$(cat /tmp/udp-probe 2>/dev/null)" = "virtio-udp-pass" ]; then
		udp_ok=1
		break
	fi
	sleep 1
done
kill "$udp_pid" 2>/dev/null || true
wait "$udp_pid" 2>/dev/null || true
[ "$udp_ok" -eq 1 ] || fail "virtio network UDP delivery failed"

poweroff -f
