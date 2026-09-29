/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_AXVISOR_H
#define _LINUX_AXVISOR_H

#include <linux/types.h>

#ifdef CONFIG_X86
bool axvisor_linux_dispatch_host_irq(unsigned long vector);
bool axvisor_linux_dispatch_host_system_irq(unsigned long vector);
#endif

#ifdef CONFIG_RISCV
int axvisor_linux_register_irq_handler(bool (*handler)(unsigned long vector));
void axvisor_linux_handle_pending_external_irqs(void);
void axvisor_linux_handle_pending_software_irq(void);
unsigned long axvisor_linux_boot_fdt_paddr(void);
#endif

#endif /* _LINUX_AXVISOR_H */
