/* SPDX-License-Identifier: GPL-2.0 */
SECTIONS
{
	.text : { *(.text .text.*) }
	.rodata : { *(.rodata .rodata.*) }
	.data : { *(.data .data.*) }
	.bss : { *(.bss .bss.*) *(COMMON) }

	.percpu : {
		_percpu_load_start = .;
		*(.percpu)
		_percpu_load_end = .;
	}

	.ex_table : {
		_ex_table_start = .;
		*(.ex_table)
		_ex_table_end = .;
	}

	__ex_table : { *(__ex_table) }
}
