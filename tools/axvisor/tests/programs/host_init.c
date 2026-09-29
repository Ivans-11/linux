// Minimal host init for cases whose workload runs in an AxVisor guest.
// Load the host module, then keep PID 1 alive while AxVisor owns the machine.
#if defined(__riscv) && __riscv_xlen == 64
#define SYS_MOUNT 40
#define SYS_OPENAT 56
#define SYS_CLOSE 57
#define SYS_FINIT_MODULE 273
static long syscall1(long nr, long a0)
{
	register long x10 __asm__("a0") = a0;
	register long x17 __asm__("a7") = nr;
	__asm__ volatile("ecall" : "+r"(x10) : "r"(x17) : "memory");
	return x10;
}
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
#elif defined(__x86_64__)
#define SYS_MOUNT 165
#define SYS_OPENAT 257
#define SYS_READ 0
#define SYS_WRITE 1
#define SYS_CLOSE 3
#define SYS_FINIT_MODULE 313
static long syscall1(long nr, long a0)
{
	long ret;
	__asm__ volatile("syscall" : "=a"(ret) : "a"(nr), "D"(a0)
			 : "rcx", "r11", "memory");
	return ret;
}
static long syscall3(long nr, long a0, long a1, long a2)
{
	long ret;
	__asm__ volatile("syscall" : "=a"(ret) : "a"(nr), "D"(a0), "S"(a1), "d"(a2)
			 : "rcx", "r11", "memory");
	return ret;
}
static long syscall4(long nr, long a0, long a1, long a2, long a3)
{
	register long r10 __asm__("r10") = a3;
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
#else
#error "unsupported architecture"
#endif

void _start(void)
{
	static const char fs[] = "devtmpfs";
	static const char dev[] = "/dev";
	static const char module_path[] = "/test/axvisor_linux.ko";
	static const char module_args[] = "";
	long module;

	(void)syscall5(SYS_MOUNT, (long)fs, (long)dev, (long)fs, 0, 0);
	module = syscall3(SYS_OPENAT, -100, (long)module_path, 0);
	if (module >= 0) {
		(void)syscall3(SYS_FINIT_MODULE, module, (long)module_args, 0);
		(void)syscall1(SYS_CLOSE, module);
	}
#if defined(__x86_64__)
	static const char serial_path[] = "/dev/ttyS0";
	static const char input_path[] = "/dev/axvisor-console-input";
	char buffer[256];
	long serial;
	long input;
	long count;

	serial = syscall4(SYS_OPENAT, -100, (long)serial_path, 0, 0);
	input = syscall4(SYS_OPENAT, -100, (long)input_path, 1, 0);
	if (serial < 0 || input < 0)
		for (;;) {}
	for (;;) {
		count = syscall3(SYS_READ, serial, (long)buffer, sizeof(buffer));
		if (count > 0)
			(void)syscall3(SYS_WRITE, input, (long)buffer, count);
	}
#else
	for (;;) {}
#endif
}
