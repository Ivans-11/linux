#!/bin/busybox sh

# Host init used by cases that launch a userspace VMM (lkvm, Firecracker, ...).
# The runner supplies /bin/busybox as a declared asset.  No case-specific
# binary or command is embedded here; interactions remain in case.toml.
# Install the BusyBox applet links once so declarative case interactions can
# use normal command names (mount, ip, sleep, ...), just as they would on a
# conventional host userspace.
/bin/busybox --install -s /bin 2>/dev/null || true
/bin/busybox mount -t devtmpfs none /dev 2>/dev/null || true
/bin/busybox mkdir -p /dev/pts
/bin/busybox mount -t devpts devpts /dev/pts 2>/dev/null || true
/bin/busybox ln -sf pts/ptmx /dev/ptmx 2>/dev/null || true
/bin/busybox mount -t proc none /proc 2>/dev/null || true
/bin/busybox mount -t sysfs none /sys 2>/dev/null || true
/bin/busybox mkdir -p /ext2
PS1='~ # '
export PS1
# PID 1 has no controlling terminal when launched from an initramfs.  Attach
# the shell explicitly to the serial device and restart it if a nested VMM
# closes the session.  This is the same transport used by the previously
# validated AxVisor host initramfs and does not require a host-side PTY helper.
while :; do
	# A terminal-mode VMM may use stdin's terminal file for all three guest
	# standard streams.  Open it read/write before duplicating it so stdout
	# remains writable in that mode (gVisor's `runsc do` relies on this).
	/bin/busybox sh -i <>/dev/ttyS0 1>&0 2>&0
done
