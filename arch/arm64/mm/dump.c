/*
 * Copyright (c) 2014, The Linux Foundation. All rights reserved.
 * Debug helper to dump the current kernel pagetables of the system
 * so that we can see what the various memory ranges are set to.
 *
 * Derived from x86 and arm implementation:
 * (C) Copyright 2008 Intel Corporation
 *
 * Author: Arjan van de Ven <arjan@linux.intel.com>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; version 2
 * of the License.
 */
#include <linux/debugfs.h>
#include <linux/errno.h>
#include <linux/fs.h>
#include <linux/io.h>
#include <linux/init.h>
#include <linux/mm.h>
#include <linux/sched.h>
#include <linux/seq_file.h>

#include <asm/fixmap.h>
#include <asm/kasan.h>
#include <asm/memory.h>
#include <asm/pgtable.h>
#include <asm/pgtable-hwdef.h>
#include <asm/ptdump.h>

static const struct addr_marker address_markers[] = {
#ifdef CONFIG_KASAN
	{ KASAN_SHADOW_START,		"Kasan shadow start" },
	{ KASAN_SHADOW_END,		"Kasan shadow end" },
#endif
	{ MODULES_VADDR,		"Modules start" },
	{ MODULES_END,			"Modules end" },
	{ VMALLOC_START,		"vmalloc() Area" },
	{ VMALLOC_END,			"vmalloc() End" },
	{ FIXADDR_START,		"Fixmap start" },
	{ FIXADDR_TOP,			"Fixmap end" },
	{ PCI_IO_START,			"PCI I/O start" },
	{ PCI_IO_END,			"PCI I/O end" },
#ifdef CONFIG_SPARSEMEM_VMEMMAP
	{ VMEMMAP_START,		"vmemmap start" },
	{ VMEMMAP_START + VMEMMAP_SIZE,	"vmemmap end" },
#endif
	{ PAGE_OFFSET,			"Linear Mapping" },
	{ -1,				NULL },
};

#define pt_dump_seq_printf(m, fmt, args...)	\
({						\
	if (m)					\
		seq_printf(m, fmt, ##args);	\
})

#define pt_dump_seq_puts(m, fmt)	\
({					\
	if (m)				\
		seq_printf(m, fmt);	\
})

/*
 * The page dumper groups page table entries of the same type into a single
 * description. It uses pg_state to track the range information while
 * iterating over the pte entries. When the continuity is broken it then
 * dumps out a description of the range.
 */
struct pg_state {
	struct seq_file *seq;
	const struct addr_marker *marker;
	unsigned long start_address;
	unsigned level;
	u64 current_prot;
	bool check_wx;
	unsigned long wx_pages;
	unsigned long uxn_pages;
};

struct prot_bits {
	u64		mask;
	u64		val;
	const char	*set;
	const char	*clear;
};

static const struct prot_bits pte_bits[] = {
	{
		.mask	= PTE_VALID,
		.val	= PTE_VALID,
		.set	= " ",
		.clear	= "F",
	}, {
		.mask	= PTE_USER,
		.val	= PTE_USER,
		.set	= "USR",
		.clear	= "   ",
	}, {
		.mask	= PTE_RDONLY,
		.val	= PTE_RDONLY,
		.set	= "ro",
		.clear	= "RW",
	}, {
		.mask	= PTE_PXN,
		.val	= PTE_PXN,
		.set	= "NX",
		.clear	= "x ",
	}, {
		.mask	= PTE_SHARED,
		.val	= PTE_SHARED,
		.set	= "SHD",
		.clear	= "   ",
	}, {
		.mask	= PTE_AF,
		.val	= PTE_AF,
		.set	= "AF",
		.clear	= "  ",
	}, {
		.mask	= PTE_NG,
		.val	= PTE_NG,
		.set	= "NG",
		.clear	= "  ",
	}, {
		.mask	= PTE_CONT,
		.val	= PTE_CONT,
		.set	= "CON",
		.clear	= "   ",
	}, {
		.mask	= PTE_TABLE_BIT,
		.val	= PTE_TABLE_BIT,
		.set	= "   ",
		.clear	= "BLK",
	}, {
		.mask	= PTE_UXN,
		.val	= PTE_UXN,
		.set	= "UXN",
	}, {
		.mask	= PTE_ATTRINDX_MASK,
		.val	= PTE_ATTRINDX(MT_DEVICE_nGnRnE),
		.set	= "DEVICE/nGnRnE",
	}, {
		.mask	= PTE_ATTRINDX_MASK,
		.val	= PTE_ATTRINDX(MT_DEVICE_nGnRE),
		.set	= "DEVICE/nGnRE",
	}, {
		.mask	= PTE_ATTRINDX_MASK,
		.val	= PTE_ATTRINDX(MT_DEVICE_GRE),
		.set	= "DEVICE/GRE",
	}, {
		.mask	= PTE_ATTRINDX_MASK,
		.val	= PTE_ATTRINDX(MT_NORMAL_NC),
		.set	= "MEM/NORMAL-NC",
	}, {
		.mask	= PTE_ATTRINDX_MASK,
		.val	= PTE_ATTRINDX(MT_NORMAL),
		.set	= "MEM/NORMAL",
	}
};

struct pg_level {
	const struct prot_bits *bits;
	const char *name;
	size_t num;
	u64 mask;
};

static struct pg_level pg_level[] = {
	{
	}, { /* pgd */
		.name	= "PGD",
		.bits	= pte_bits,
		.num	= ARRAY_SIZE(pte_bits),
	}, { /* pud */
		.name	= (CONFIG_PGTABLE_LEVELS > 3) ? "PUD" : "PGD",
		.bits	= pte_bits,
		.num	= ARRAY_SIZE(pte_bits),
	}, { /* pmd */
		.name	= (CONFIG_PGTABLE_LEVELS > 2) ? "PMD" : "PGD",
		.bits	= pte_bits,
		.num	= ARRAY_SIZE(pte_bits),
	}, { /* pte */
		.name	= "PTE",
		.bits	= pte_bits,
		.num	= ARRAY_SIZE(pte_bits),
	},
};

static void dump_prot(struct pg_state *st, const struct prot_bits *bits,
			size_t num)
{
	unsigned i;

	for (i = 0; i < num; i++, bits++) {
		const char *s;

		if ((st->current_prot & bits->mask) == bits->val)
			s = bits->set;
		else
			s = bits->clear;

		if (s)
			pt_dump_seq_printf(st->seq, " %s", s);
	}
}

static void note_prot_uxn(struct pg_state *st, unsigned long addr)
{
	if (!st->check_wx)
		return;

	if ((st->current_prot & PTE_UXN) == PTE_UXN)
		return;

	WARN_ONCE(1, "arm64/mm: Found non-UXN mapping at address %p/%pS\n",
		  (void *)st->start_address, (void *)st->start_address);

	st->uxn_pages += (addr - st->start_address) / PAGE_SIZE;
}

static void note_prot_wx(struct pg_state *st, unsigned long addr)
{
	if (!st->check_wx)
		return;
	if ((st->current_prot & PTE_RDONLY) == PTE_RDONLY)
		return;
	if ((st->current_prot & PTE_PXN) == PTE_PXN)
		return;

	WARN_ONCE(1, "arm64/mm: Found insecure W+X mapping at address %p/%pS\n",
		  (void *)st->start_address, (void *)st->start_address);

	st->wx_pages += (addr - st->start_address) / PAGE_SIZE;
}

static void note_page(struct pg_state *st, unsigned long addr, unsigned level,
				u64 val)
{
	static const char units[] = "KMGTPE";
	u64 prot = val & pg_level[level].mask;

	if (!st->level) {
		st->level = level;
		st->current_prot = prot;
		st->start_address = addr;
		pt_dump_seq_printf(st->seq, "---[ %s ]---\n", st->marker->name);
	} else if (prot != st->current_prot || level != st->level ||
		   addr >= st->marker[1].start_address) {
		const char *unit = units;
		unsigned long delta;

		if (st->current_prot) {
			note_prot_uxn(st, addr);
			note_prot_wx(st, addr);
			pt_dump_seq_printf(st->seq, "0x%016lx-0x%016lx   ",
				   st->start_address, addr);

			delta = (addr - st->start_address) >> 10;
			while (!(delta & 1023) && unit[1]) {
				delta >>= 10;
				unit++;
			}
			pt_dump_seq_printf(st->seq, "%9lu%c %s", delta, *unit,
				   pg_level[st->level].name);
			if (pg_level[st->level].bits)
				dump_prot(st, pg_level[st->level].bits,
					  pg_level[st->level].num);
			pt_dump_seq_puts(st->seq, "\n");
		}

		if (addr >= st->marker[1].start_address) {
			st->marker++;
			pt_dump_seq_printf(st->seq, "---[ %s ]---\n", st->marker->name);
		}

		st->start_address = addr;
		st->current_prot = prot;
		st->level = level;
	}

	if (addr >= st->marker[1].start_address) {
		st->marker++;
		pt_dump_seq_printf(st->seq, "---[ %s ]---\n", st->marker->name);
	}

}

static void walk_pte(struct pg_state *st, pmd_t *pmdp, unsigned long start)
{
	pte_t *ptep = pte_offset_kernel(pmdp, 0UL);
	unsigned long addr;
	unsigned i;

	for (i = 0; i < PTRS_PER_PTE; i++, ptep++) {
		addr = start + i * PAGE_SIZE;
		note_page(st, addr, 4, READ_ONCE(pte_val(*ptep)));
	}
}

static void walk_pmd(struct pg_state *st, pud_t *pudp, unsigned long start)
{
	pmd_t *pmdp = pmd_offset(pudp, 0UL);
	unsigned long addr;
	unsigned i;

	for (i = 0; i < PTRS_PER_PMD; i++, pmdp++) {
		pmd_t pmd = READ_ONCE(*pmdp);

		addr = start + i * PMD_SIZE;
		if (pmd_none(pmd) || pmd_sect(pmd)) {
			note_page(st, addr, 3, pmd_val(pmd));
		} else {
			BUG_ON(pmd_bad(pmd));
			walk_pte(st, pmdp, addr);
		}
	}
}

static void walk_pud(struct pg_state *st, pgd_t *pgdp, unsigned long start)
{
	pud_t *pudp = pud_offset(pgdp, 0UL);
	unsigned long addr;
	unsigned i;

	for (i = 0; i < PTRS_PER_PUD; i++, pudp++) {
		pud_t pud = READ_ONCE(*pudp);

		addr = start + i * PUD_SIZE;
		if (pud_none(pud) || pud_sect(pud)) {
			note_page(st, addr, 2, pud_val(pud));
		} else {
			BUG_ON(pud_bad(pud));
			walk_pmd(st, pudp, addr);
		}
	}
}

static void walk_pgd(struct pg_state *st, struct mm_struct *mm,
		     unsigned long start)
{
	pgd_t *pgdp = pgd_offset(mm, 0UL);
	unsigned i;
	unsigned long addr;

	for (i = 0; i < PTRS_PER_PGD; i++, pgdp++) {
		pgd_t pgd = READ_ONCE(*pgdp);

		addr = start + i * PGDIR_SIZE;
		if (pgd_none(pgd)) {
			note_page(st, addr, 1, pgd_val(pgd));
		} else {
			BUG_ON(pgd_bad(pgd));
			walk_pud(st, pgdp, addr);
		}
	}
}

void ptdump_walk_pgd(struct seq_file *m, struct ptdump_info *info)
{
	struct pg_state st = {
		.seq = m,
		.marker = info->markers,
	};

	walk_pgd(&st, info->mm, info->base_addr);

	note_page(&st, 0, 0, 0);
}

static void ptdump_initialize(void)
{
	unsigned i, j;

	for (i = 0; i < ARRAY_SIZE(pg_level); i++)
		if (pg_level[i].bits)
			for (j = 0; j < pg_level[i].num; j++)
				pg_level[i].mask |= pg_level[i].bits[j].mask;
}

static struct ptdump_info kernel_ptdump_info = {
	.mm		= &init_mm,
	.markers	= address_markers,
	.base_addr	= VA_START,
};

void ptdump_check_wx_curr(struct task_struct *p)
{
	struct pg_state st = {
		.seq = NULL,
		.marker = (struct addr_marker[]) {
			{ 0, NULL},
			{ -1, NULL},
		},
		.check_wx = true,
	};
	pr_devel("ptdump_checkwx_curr: %p\n", p);

	walk_pgd(&st, p->mm, p->mm->start_code);
	note_page(&st, 0, 0, 0);
	if (st.wx_pages || st.uxn_pages)
		pr_warn("Checked W+X mappings(p): FAILED, %lu W+X pages found, %lu non-UXN pages found\n",
			st.wx_pages, st.uxn_pages);
	else
		pr_devel("Checked W+X mappings(p): passed, no W+X pages found\n");
}

void ptdump_check_wx(void)
{
	struct pg_state st = {
		.seq = NULL,
		.marker = (struct addr_marker[]) {
			{ 0, NULL},
			{ -1, NULL},
		},
		.check_wx = true,
	};

	walk_pgd(&st, &init_mm, VA_START);
	note_page(&st, 0, 0, 0);
	if (st.wx_pages || st.uxn_pages)
		pr_warn("Checked W+X mappings: FAILED, %lu W+X pages found, %lu non-UXN pages found\n",
			st.wx_pages, st.uxn_pages);
	else
		pr_info("Checked W+X mappings: passed, no W+X pages found\n");
}

static int ptdump_init(void)
{
	ptdump_initialize();
	return ptdump_debugfs_register(&kernel_ptdump_info,
					"kernel_page_tables");
}
device_initcall(ptdump_init);
