/*
 * Copyright (C) 2015-2018 - ARM Ltd
 * Author: Marc Zyngier <marc.zyngier@arm.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <linux/arm-smccc.h>
#include <linux/linkage.h>

#include <asm/alternative.h>
#include <asm/assembler.h>
#include <asm/cpufeature.h>
#include <asm/kvm_arm.h>
#include <asm/kvm_asm.h>
#include <asm/kvm_mmu.h>
#include <asm/mmu.h>

	.text
	.pushsection	.hyp.text, "ax"

#ifdef CONFIG_VERIFIED_KVM
.macro save_callee_saved_regs
	stp	lr, xzr,   [sp, #-16]!
	stp	x28, x29, [sp, #-16]!
	stp	x26, x27, [sp, #-16]!
	stp	x24, x25, [sp, #-16]!
	stp	x22, x23, [sp, #-16]!
	stp	x20, x21, [sp, #-16]!
	stp	x18, x19, [sp, #-16]!
	stp	x16, x17, [sp, #-16]!
	stp	x14, x15, [sp, #-16]!
	stp	x12, x13, [sp, #-16]!
	stp	x10, x11, [sp, #-16]!
	stp	x8, x9,   [sp, #-16]!
	stp	x6, x7,   [sp, #-16]!
	stp	x4, x5,   [sp, #-16]!
	stp	x2, x3,   [sp, #-16]!
	stp	x0, x1,   [sp, #-16]!
.endm

.macro restore_callee_saved_regs
	ldp	x0, x1,   [sp], #16
	ldp	x2, x3,   [sp], #16
	ldp	x4, x5,   [sp], #16
	ldp	x6, x7,   [sp], #16
	ldp	x8, x9,   [sp], #16
	ldp	x10, x11, [sp], #16
	ldp	x12, x13, [sp], #16
	ldp	x14, x15, [sp], #16
	ldp	x16, x17, [sp], #16
	ldp	x18, x19, [sp], #16
	ldp	x20, x21, [sp], #16
	ldp	x22, x23, [sp], #16
	ldp	x24, x25, [sp], #16
	ldp	x26, x27, [sp], #16
	ldp	x28, x29, [sp], #16
	ldp	lr, xzr,   [sp], #16
.endm

.macro  handle_dabt
	save_callee_saved_regs
	mov	x1, sp
	mov	x0, lr
	bl	handle_host_stage2_fault
	restore_callee_saved_regs
	eret
.endm

	.align 11

.macro enable_stage2_trans t0, t1
	msr	vttbr_el2, \t1
	/* Enable stage2 translation */
	mrs	\t0, hcr_el2
	orr	\t0, \t0, HCR_VM
	orr	\t0, \t0, HCR_AMO
	isb
	msr	hcr_el2, \t0
	isb
	tlbi	vmalle1is
	dsb	sy
	ic	ialluis
.endm
#endif

.macro do_el2_call
	/*
	 * Shuffle the parameters before calling the function
	 * pointed to in x0. Assumes parameters in x[1,2,3].
	 */
	str	lr, [sp, #-16]!
	mov	lr, x0
	mov	x0, x1
	mov	x1, x2
	mov	x2, x3
	blr	lr
	ldr	lr, [sp], #16
.endm

ENTRY(__vhe_hyp_call)
	do_el2_call
	/*
	 * We used to rely on having an exception return to get
	 * an implicit isb. In the E2H case, we don't have it anymore.
	 * rather than changing all the leaf functions, just do it here
	 * before returning to the rest of the kernel.
	 */
	isb
	ret
ENDPROC(__vhe_hyp_call)

el1_sync:				// Guest trapped into EL2

	mrs	x0, esr_el2
	lsr	x0, x0, #ESR_ELx_EC_SHIFT
	cmp	x0, #ESR_ELx_EC_HVC64
	ccmp	x0, #ESR_ELx_EC_HVC32, #4, ne
#ifndef CONFIG_VERIFIED_KVM
	b.ne	el1_trap

	mrs	x1, vttbr_el2		// If vttbr is valid, the guest
	cbnz	x1, el1_hvc_guest	// called HVC
#else
	b.eq	4f
	cmp	x0, #ESR_ELx_EC_DABT_LOW
	b.eq	5f
	cmp	x0, #ESR_ELx_EC_IABT_LOW
	b.ne	el1_trap

5:
	/* if tpidr_el2 = 0, we know if traps from host kernel! */
	mrs     x1, tpidr_el2
	cbnz    x1, el1_trap

	ldp	x0, x1,   [sp], #16
	handle_dabt
4:
	mrs	x1, tpidr_el2
	cbnz	x1, el1_hvc_guest	// called HVC
#endif

	/* Here, we're pretty sure the host called HVC. */
	ldp	x0, x1, [sp], #16

	cmp	x0, #HVC_GET_VECTORS
	b.ne	2f
	mrs	x0, vbar_el2
	eret

2:
	/* Check for a stub HVC call */
	cmp	x0, #HVC_STUB_HCALL_NR
	b.hs	1f

	/*
	 * Compute the idmap address of __kvm_handle_stub_hvc and
	 * jump there. Since we use kimage_voffset, do not use the
	 * HYP VA for __kvm_handle_stub_hvc, but the kernel VA instead
	 * (by loading it from the constant pool).
	 *
	 * Preserve x0-x4, which may contain stub parameters.
	 */
	ldr	x5, =__kvm_handle_stub_hvc
	ldr_l	x6, kimage_voffset

	/* x5 = __pa(x5) */
	sub	x5, x5, x6
	br	x5

1:
#ifdef CONFIG_VERIFIED_KVM
	save_callee_saved_regs
	mov	x0, sp
	bl	handle_host_hvc
	restore_callee_saved_regs
	eret
#else
	/*
	 * Perform the EL2 call
	 */
	kern_hyp_va	x0
	do_el2_call

	eret
#endif

el1_hvc_guest:
	/*
	 * Fastest possible path for ARM_SMCCC_ARCH_WORKAROUND_1.
	 * The workaround has already been applied on the host,
	 * so let's quickly get back to the guest. We don't bother
	 * restoring x1, as it can be clobbered anyway.
	 */
	ldr	x1, [sp]				// Guest's x0
	eor	w1, w1, #ARM_SMCCC_ARCH_WORKAROUND_1
	cbz	w1, wa_epilogue

	/* ARM_SMCCC_ARCH_WORKAROUND_2 handling */
	eor	w1, w1, #(ARM_SMCCC_ARCH_WORKAROUND_1 ^ \
			  ARM_SMCCC_ARCH_WORKAROUND_2)
	cbnz	w1, el1_trap

#ifdef CONFIG_ARM64_SSBD
alternative_cb	arm64_enable_wa2_handling
	b	wa2_end
alternative_cb_end
	get_vcpu_ptr	x2, x0
	ldr	x0, [x2, #VCPU_WORKAROUND_FLAGS]

	// Sanitize the argument and update the guest flags
	ldr	x1, [sp, #8]			// Guest's x1
	clz	w1, w1				// Murphy's device:
	lsr	w1, w1, #5			// w1 = !!w1 without using
	eor	w1, w1, #1			// the flags...
	bfi	x0, x1, #VCPU_WORKAROUND_2_FLAG_SHIFT, #1
	str	x0, [x2, #VCPU_WORKAROUND_FLAGS]

	/* Check that we actually need to perform the call */
	hyp_ldr_this_cpu x0, arm64_ssbd_callback_required, x2
	cbz	x0, wa2_end

	mov	w0, #ARM_SMCCC_ARCH_WORKAROUND_2
	smc	#0

	/* Don't leak data from the SMC call */
	mov	x3, xzr
wa2_end:
	mov	x2, xzr
	mov	x1, xzr
#endif

wa_epilogue:
	mov	x0, xzr
	add	sp, sp, #16
	eret

el1_trap:
#ifndef CONFIG_VERIFIED_KVM
	get_vcpu_ptr	x1, x0
#else
	mrs	x1, tpidr_el2
#endif
	mov	x0, #ARM_EXCEPTION_TRAP
	b	__guest_exit

el1_irq:
#ifndef CONFIG_VERIFIED_KVM
	get_vcpu_ptr	x1, x0
#else
	mrs	x1, tpidr_el2
#endif
	mov	x0, #ARM_EXCEPTION_IRQ
	b	__guest_exit

el1_error:
#ifndef CONFIG_VERIFIED_KVM
	get_vcpu_ptr	x1, x0
#else
	mrs	x1, tpidr_el2
#endif
	mov	x0, #ARM_EXCEPTION_EL1_SERROR
	b	__guest_exit

el2_error:
	ldp	x0, x1, [sp], #16

	/*
	 * Only two possibilities:
	 * 1) Either we come from the exit path, having just unmasked
	 *    PSTATE.A: change the return code to an EL2 fault, and
	 *    carry on, as we're already in a sane state to handle it.
	 * 2) Or we come from anywhere else, and that's a bug: we panic.
	 *
	 * For (1), x0 contains the original return code and x1 doesn't
	 * contain anything meaningful at that stage. We can reuse them
	 * as temp registers.
	 * For (2), who cares?
	 */
	mrs	x0, elr_el2
	adr	x1, abort_guest_exit_start
	cmp	x0, x1
	adr	x1, abort_guest_exit_end
	ccmp	x0, x1, #4, ne
	b.ne	__hyp_panic
	mov	x0, #(1 << ARM_EXIT_WITH_SERROR_BIT)
	eret

ENTRY(__hyp_do_panic)
	mov	lr, #(PSR_F_BIT | PSR_I_BIT | PSR_A_BIT | PSR_D_BIT |\
		      PSR_MODE_EL1h)
	msr	spsr_el2, lr
	ldr	lr, =panic
	msr	elr_el2, lr
	eret
ENDPROC(__hyp_do_panic)

ENTRY(__hyp_panic)
	get_host_ctxt x0, x1
	b	hyp_panic
ENDPROC(__hyp_panic)

.macro invalid_vector	label, target = __hyp_panic
	.align	2
\label:
	b \target
ENDPROC(\label)
.endm

	/* None of these should ever happen */
	invalid_vector	el2t_sync_invalid
	invalid_vector	el2t_irq_invalid
	invalid_vector	el2t_fiq_invalid
	invalid_vector	el2t_error_invalid
	invalid_vector	el2h_sync_invalid
	invalid_vector	el2h_irq_invalid
	invalid_vector	el2h_fiq_invalid
	invalid_vector	el1_fiq_invalid

	.ltorg

	.align 11

.macro valid_vect target
	.align 7
	stp	x0, x1, [sp, #-16]!
	b	\target
.endm

.macro invalid_vect target
	.align 7
	b	\target
	ldp	x0, x1, [sp], #16
	b	\target
.endm

ENTRY(__kvm_hyp_vector)
	invalid_vect	el2t_sync_invalid	// Synchronous EL2t
	invalid_vect	el2t_irq_invalid	// IRQ EL2t
	invalid_vect	el2t_fiq_invalid	// FIQ EL2t
	invalid_vect	el2t_error_invalid	// Error EL2t

	invalid_vect	el2h_sync_invalid	// Synchronous EL2h
	invalid_vect	el2h_irq_invalid	// IRQ EL2h
	invalid_vect	el2h_fiq_invalid	// FIQ EL2h
	valid_vect	el2_error		// Error EL2h

	valid_vect	el1_sync		// Synchronous 64-bit EL1
	valid_vect	el1_irq			// IRQ 64-bit EL1
	invalid_vect	el1_fiq_invalid		// FIQ 64-bit EL1
	valid_vect	el1_error		// Error 64-bit EL1

	valid_vect	el1_sync		// Synchronous 32-bit EL1
	valid_vect	el1_irq			// IRQ 32-bit EL1
	invalid_vect	el1_fiq_invalid		// FIQ 32-bit EL1
	valid_vect	el1_error		// Error 32-bit EL1
ENDPROC(__kvm_hyp_vector)

#ifdef CONFIG_KVM_INDIRECT_VECTORS
.macro hyp_ventry
	.align 7
1:	.rept 27
	nop
	.endr
/*
 * The default sequence is to directly branch to the KVM vectors,
 * using the computed offset. This applies for VHE as well as
 * !ARM64_HARDEN_EL2_VECTORS.
 *
 * For ARM64_HARDEN_EL2_VECTORS configurations, this gets replaced
 * with:
 *
 * stp	x0, x1, [sp, #-16]!
 * movz	x0, #(addr & 0xffff)
 * movk	x0, #((addr >> 16) & 0xffff), lsl #16
 * movk	x0, #((addr >> 32) & 0xffff), lsl #32
 * br	x0
 *
 * Where addr = kern_hyp_va(__kvm_hyp_vector) + vector-offset + 4.
 * See kvm_patch_vector_branch for details.
 */
alternative_cb	kvm_patch_vector_branch
	b	__kvm_hyp_vector + (1b - 0b)
	nop
	nop
	nop
	nop
alternative_cb_end
.endm

.macro generate_vectors
0:
	.rept 16
	hyp_ventry
	.endr
	.org 0b + SZ_2K		// Safety measure
.endm

	.align	11
ENTRY(__bp_harden_hyp_vecs_start)
	.rept BP_HARDEN_EL2_SLOTS
	generate_vectors
	.endr
ENTRY(__bp_harden_hyp_vecs_end)

	.popsection

ENTRY(__smccc_workaround_1_smc_start)
	sub	sp, sp, #(8 * 4)
	stp	x2, x3, [sp, #(8 * 0)]
	stp	x0, x1, [sp, #(8 * 2)]
	mov	w0, #ARM_SMCCC_ARCH_WORKAROUND_1
	smc	#0
	ldp	x2, x3, [sp, #(8 * 0)]
	ldp	x0, x1, [sp, #(8 * 2)]
	add	sp, sp, #(8 * 4)
ENTRY(__smccc_workaround_1_smc_end)
#endif
