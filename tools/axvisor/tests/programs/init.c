// Minimal init for the self-contained AxVisor smoke initramfs.
// It execs the test program directly; no shell or host-side tree is needed.

#if defined(__riscv) && __riscv_xlen == 64
#define SYS_EXECVE 221
#define SYS_OPENAT 56
#define SYS_DUP3 24
#define SYS_MOUNT 40
#define SYS_EXIT 93
#define SYS_WRITE 64
static long syscall3(long nr, long a0, long a1, long a2)
{
	register long x10 __asm__("a0") = a0;
	register long x11 __asm__("a1") = a1;
	register long x12 __asm__("a2") = a2;
	register long x17 __asm__("a7") = nr;
	__asm__ volatile("ecall" : "+r"(x10) : "r"(x11), "r"(x12), "r"(x17) : "memory");
	return x10;
}
static long syscall5(long nr, long a0, long a1, long a2, long a3, long a4)
{
	register long x10 __asm__("a0") = a0;
	register long x11 __asm__("a1") = a1;
	register long x12 __asm__("a2") = a2;
	register long x13 __asm__("a3") = a3;
	register long x14 __asm__("a4") = a4;
	register long x17 __asm__("a7") = nr;
	__asm__ volatile("ecall" : "+r"(x10) : "r"(x11), "r"(x12), "r"(x13), "r"(x14), "r"(x17) : "memory");
	return x10;
}
static void syscall1_noreturn(long nr, long a0)
{
	register long x10 __asm__("a0") = a0;
	register long x17 __asm__("a7") = nr;
	__asm__ volatile("ecall" : : "r"(x10), "r"(x17) : "memory");
	for (;;) {}
}
#elif defined(__x86_64__)
#define SYS_EXECVE 59
#define SYS_OPENAT 257
#define SYS_DUP3 292
#define SYS_MOUNT 165
#define SYS_EXIT 60
#define SYS_WRITE 1
static long syscall3(long nr, long a0, long a1, long a2)
{
	register long r10 __asm__("r10") = a2;
	long ret;
	__asm__ volatile("syscall" : "=a"(ret) : "a"(nr), "D"(a0), "S"(a1), "d"(a2), "r"(r10)
			 : "rcx", "r11", "memory");
	return ret;
}
static long syscall5(long nr, long a0, long a1, long a2, long a3, long a4)
{
	register long r10 __asm__("r10") = a3;
	register long r8 __asm__("r8") = a4;
	long ret;
	__asm__ volatile("syscall" : "=a"(ret) : "a"(nr), "D"(a0), "S"(a1), "d"(a2), "r"(r10), "r"(r8)
			 : "rcx", "r11", "memory");
	return ret;
}
static void syscall1_noreturn(long nr, long a0)
{
	__asm__ volatile("syscall" : : "a"(nr), "D"(a0) : "rcx", "r11", "memory");
	for (;;) {}
}
#else
#error "unsupported architecture"
#endif

void _start(void)
{
	static const char devtmpfs[] = "devtmpfs";
	static const char dev[] = "/dev";
	(void)syscall5(SYS_MOUNT, (long)devtmpfs, (long)dev, (long)devtmpfs, 0, 0);
	static const char console[] = "/dev/console";
	long console_fd = syscall3(SYS_OPENAT, -100, (long)console, 2);
	if (console_fd >= 0) {
		for (long fd = 0; fd < 3; fd++)
			syscall3(SYS_DUP3, console_fd, fd, 0);
	}
	static const char path[] = "/test/kvm_smoke";
	static char *const argv[] = {(char *)path, (char *)0};
	long rc = syscall3(SYS_EXECVE, (long)path, (long)argv, 0);
	(void)rc;
	static const char error[] = "init: exec /test/kvm_smoke failed\n";
	syscall3(SYS_WRITE, 1, (long)error, sizeof(error) - 1);
	syscall1_noreturn(SYS_EXIT, 127);
}
