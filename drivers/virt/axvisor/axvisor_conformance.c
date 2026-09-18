// SPDX-License-Identifier: GPL-2.0
#include <linux/atomic.h>
#include <linux/interrupt.h>
#include <linux/module.h>
#include <linux/smp.h>

#include "axvisor_ffi.h"

static bool axvisor_conformance_mode;
module_param_named(conformance, axvisor_conformance_mode, bool, 0444);
MODULE_PARM_DESC(conformance,
		 "run the AxVisor host-contract conformance suite");

bool axvisor_linux_conformance_enabled(void)
{
	return axvisor_conformance_mode;
}

static atomic_t axvisor_conformance_irq_result = ATOMIC_INIT(0);

static void axvisor_linux_conformance_irq_ipi(void *info)
{
	unsigned long vector = (unsigned long)info;
	bool passed = in_interrupt() && axvisor_linux_handle_irq(vector);

	atomic_set(&axvisor_conformance_irq_result, passed ? 1 : -1);
}

bool axvisor_linux_conformance_trigger_irq(unsigned long vector)
{
	unsigned int target;
	int ret;

	target = cpumask_any_but(cpu_online_mask, smp_processor_id());
	if (target >= nr_cpu_ids)
		return false;
	atomic_set(&axvisor_conformance_irq_result, 0);
	ret = smp_call_function_single(target,
				       axvisor_linux_conformance_irq_ipi,
				       (void *)vector, 1);
	return ret == 0 && atomic_read(&axvisor_conformance_irq_result) == 1;
}
