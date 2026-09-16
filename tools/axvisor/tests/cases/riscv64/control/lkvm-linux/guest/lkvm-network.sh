#!/bin/sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
/bin/busybox --install -s >/dev/null 2>&1

mkdir -p /proc /sys /dev /dev/pts
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mount -t devpts devpts /dev/pts 2>/dev/null || true
n=$(grep -c '^processor' /proc/cpuinfo)
mkdir -p /tmp
ip link set eth0 up
ip addr add 172.16.0.2/24 dev eth0
rm -f /tmp/u
nc -u -l -p 9000 -s 172.16.0.2 -w 30 > /tmp/u &
p=$!
for i in 1 2 3 4 5 6 7 8 9 10; do
    if wget -T 2 -q -O /tmp/t http://172.16.0.1:8080/probe &&
       grep -q '^lkvm-network-pass$' /tmp/t; then
        break
    fi
    sleep 1
done
grep -q '^lkvm-network-pass$' /tmp/t || exit 1
udp_ok=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if test "$(cat /tmp/u 2>/dev/null)" = "virtio-udp-pass"; then
        udp_ok=1
        break
    fi
    sleep 1
done
kill "$p" 2>/dev/null || true
wait "$p" 2>/dev/null || true
test "$udp_ok" -eq 1 || exit 1
test "$n" -ge 4 || exit 1
echo 'guest test pass!'
