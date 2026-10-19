// SPDX-License-Identifier: GPL-2.0
/*
 * isa_emu.c - emulate ISA extensions that userspace assumes but this CPU lacks.
 *
 * Googlebook OS userland is compiled for a CPU baseline that includes GFNI,
 * AVX-VNNI, AVX-IFMA, VAES, VPCLMULQDQ and SHA-NI, and uses them without checking
 * CPUID. On older AVX2 CPUs (Skylake/Kaby Lake, Zen 2) those instructions raise #UD.
 * This hooks the user-mode #UD path the same way UMIP emulation hooks #GP: decode
 * the instruction, compute the result in software, write the destination vector
 * register and skip the instruction.
 *
 * The decoder and arithmetic live in isa_emu_core.h, which is also compiled into a
 * userspace differential tester that checks every form against real hardware.
 *
 * Boot parameters: isa_emu=off | on (default) | profile, isa_emu_fast=0 | 1 (default)
 *   profile additionally records per-site hit counts (file + offset) and prints a
 *   summary to the kernel log every 10 seconds.
 *   isa_emu_fast=0 disables the whole-function fast paths (see isa_emu_fastpath.h).
 */
#define pr_fmt(fmt) "isa_emu: " fmt

#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/uaccess.h>
#include <linux/sched.h>
#include <linux/sched/signal.h>
#include <linux/ptrace.h>
#include <linux/percpu.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/mm.h>
#include <linux/fs.h>
#include <linux/hash.h>
#include <linux/vmalloc.h>
#include <linux/workqueue.h>
#include <linux/spinlock.h>
#include <linux/rcupdate.h>
#include <linux/slab.h>

#include <crypto/sha1.h>
#include <crypto/sha2.h>

#include <asm/cpufeature.h>
#include <asm/fpu/api.h>
#include <asm/fsgsbase.h>
#include <asm/insn.h>
#include <asm/insn-eval.h>
#include <asm/traps.h>

#include "isa_emu_core.h"
#include "isa_emu_fastpath.h"

static const char * const isa_op_name[ISA_OP_COUNT] = {
	"none", "gf2p8affineqb", "gf2p8affineinvqb", "gf2p8mulb", "vpdpbusd", "vpdpbusds",
	"vpdpwssd", "vpdpwssds", "vpmadd52luq", "vpmadd52huq", "aesenc", "aesenclast",
	"aesdec", "aesdeclast", "pclmulqdq", "sha1rnds4", "sha1nexte", "sha1msg1",
	"sha1msg2", "sha256rnds2", "sha256msg1", "sha256msg2",
};

static struct isa_tables isa_tables __ro_after_init;
static bool isa_emu_ready __ro_after_init;
static int isa_emu_mode __ro_after_init = 1;	/* 0 off, 1 on, 2 profile */
static DEFINE_PER_CPU(u64 [ISA_OP_COUNT], isa_emu_count);
static bool isa_emu_fast __ro_after_init = true;
static DEFINE_PER_CPU(u64, isa_fast_sha256_calls);
static DEFINE_PER_CPU(u64, isa_fast_sha256_blocks);
static DEFINE_PER_CPU(u64, isa_fast_sha1_calls);
static DEFINE_PER_CPU(u64, isa_fast_sha1_blocks);

static int __init isa_emu_setup(char *s)
{
	if (!s)
		return -EINVAL;
	if (!strcmp(s, "off"))
		isa_emu_mode = 0;
	else if (!strcmp(s, "on"))
		isa_emu_mode = 1;
	else if (!strcmp(s, "profile"))
		isa_emu_mode = 2;
	else
		return -EINVAL;
	return 0;
}
early_param("isa_emu", isa_emu_setup);

static int __init isa_emu_fast_setup(char *s)
{
	return s ? kstrtobool(s, &isa_emu_fast) : -EINVAL;
}
early_param("isa_emu_fast", isa_emu_fast_setup);

/* ---- vector register access ---------------------------------------------------
 * Callers hold fpregs_lock() with the task's FPU state loaded in the registers, so
 * the registers are the authoritative copy of the user's state. Kernel C code is
 * built without SSE/AVX and never touches them implicitly.
 */
struct isa_vec {
	u8 b[32];
};

#define ISA_RD(n) case n: asm volatile("vmovdqu %%ymm" #n ", %0" : "=m" (*v)); break
#define ISA_WR(n) case n: asm volatile("vmovdqu %0, %%ymm" #n : : "m" (*v)); break
#define ISA_WRX(n) case n: asm volatile("movdqu %0, %%xmm" #n : : "m" (*v)); break
#define ISA_ALL(M) M(0); M(1); M(2); M(3); M(4); M(5); M(6); M(7); \
		   M(8); M(9); M(10); M(11); M(12); M(13); M(14); M(15)

static noinline void isa_rd_ymm(unsigned int n, struct isa_vec *v)
{
	switch (n) {
	ISA_ALL(ISA_RD);
	}
}

/* VEX-encoded destination: bits above the vector length are zeroed */
static noinline void isa_wr_ymm(unsigned int n, const struct isa_vec *v)
{
	switch (n) {
	ISA_ALL(ISA_WR);
	}
}

/* legacy SSE destination: only bits 127:0 change */
static noinline void isa_wr_xmm(unsigned int n, const struct isa_vec *v)
{
	switch (n) {
	ISA_ALL(ISA_WRX);
	}
}

/* ---- optional per-site profile ---------------------------------------------------- */
#define ISA_SITE_BITS 13
#define ISA_SITES (1u << ISA_SITE_BITS)

struct isa_site {
	u64 key_ino;
	u64 key_off;
	u64 count;
	u32 dev;
	u8 op;
	char name[35];
};

static struct isa_site *isa_sites;
static DEFINE_RAW_SPINLOCK(isa_site_lock);
static u64 isa_site_dropped;

static void isa_emu_record(unsigned long ip, u8 op)
{
	struct mm_struct *mm = current->mm;
	struct vm_area_struct *vma;
	struct isa_site s = { .op = op, .key_off = ip };
	unsigned long flags;
	u32 h, i;

	if (!isa_sites || !mm || !mmap_read_trylock(mm))
		return;
	vma = vma_lookup(mm, ip);
	if (vma && vma->vm_file) {
		struct inode *inode = file_inode(vma->vm_file);

		s.key_ino = inode->i_ino;
		s.dev = inode->i_sb->s_dev;
		s.key_off = ip - vma->vm_start + ((u64)vma->vm_pgoff << PAGE_SHIFT);
		rcu_read_lock();
		strscpy(s.name, vma->vm_file->f_path.dentry->d_name.name, sizeof(s.name));
		rcu_read_unlock();
	} else {
		strscpy(s.name, "[anon]", sizeof(s.name));
	}
	mmap_read_unlock(mm);

	h = hash_64(s.key_ino * 0x9E3779B97F4A7C15ULL ^ s.key_off ^ ((u64)s.dev << 40), ISA_SITE_BITS);
	raw_spin_lock_irqsave(&isa_site_lock, flags);
	for (i = 0; i < 32; i++) {
		struct isa_site *e = &isa_sites[(h + i) & (ISA_SITES - 1)];

		if (!e->count) {
			*e = s;
			e->count = 1;
			goto unlock;
		}
		if (e->key_ino == s.key_ino && e->key_off == s.key_off && e->dev == s.dev) {
			e->count++;
			goto unlock;
		}
	}
	isa_site_dropped++;
unlock:
	raw_spin_unlock_irqrestore(&isa_site_lock, flags);
}

static u64 isa_emu_sum(int op)
{
	u64 sum = 0;
	int cpu;

	for_each_possible_cpu(cpu)
		sum += per_cpu(isa_emu_count, cpu)[op];
	return sum;
}

static u64 isa_percpu_sum(u64 __percpu *var)
{
	u64 sum = 0;
	int cpu;

	for_each_possible_cpu(cpu)
		sum += *per_cpu_ptr(var, cpu);
	return sum;
}

#define ISA_TOP 12
static void isa_emu_report(struct work_struct *work);
static DECLARE_DELAYED_WORK(isa_emu_report_work, isa_emu_report);

static void isa_emu_report(struct work_struct *work)
{
	static u64 last_total;
	u64 total = 0, top_count[ISA_TOP] = { 0 };
	u32 top_idx[ISA_TOP] = { 0 };
	char line[400];
	int op, n = 0, i, j;
	u32 k;

	for (op = 1; op < ISA_OP_COUNT; op++) {
		u64 c = isa_emu_sum(op);

		total += c;
		if (c)
			n += scnprintf(line + n, sizeof(line) - n, " %s=%llu", isa_op_name[op], c);
	}
	if (total != last_total) {
		pr_info("total=%llu (+%llu/10s) fast_sha256=%llu calls/%llu blocks fast_sha1=%llu calls/%llu blocks%s\n",
			total, total - last_total, isa_percpu_sum(&isa_fast_sha256_calls),
			isa_percpu_sum(&isa_fast_sha256_blocks), isa_percpu_sum(&isa_fast_sha1_calls),
			isa_percpu_sum(&isa_fast_sha1_blocks), line);
		for (k = 0; k < ISA_SITES; k++) {
			u64 c = READ_ONCE(isa_sites[k].count);

			for (i = 0; i < ISA_TOP; i++) {
				if (c <= top_count[i])
					continue;
				for (j = ISA_TOP - 1; j > i; j--) {
					top_count[j] = top_count[j - 1];
					top_idx[j] = top_idx[j - 1];
				}
				top_count[i] = c;
				top_idx[i] = k;
				break;
			}
		}
		for (i = 0; i < ISA_TOP && top_count[i]; i++) {
			struct isa_site *e = &isa_sites[top_idx[i]];

			pr_info("  site %llu %s %s+0x%llx\n", top_count[i], isa_op_name[e->op],
				e->name, e->key_off);
		}
		if (isa_site_dropped)
			pr_info("  site table full: %llu hits unattributed\n", isa_site_dropped);
		last_total = total;
	}
	schedule_delayed_work(&isa_emu_report_work, 10 * HZ);
}

/* ---- whole-function fast paths --------------------------------------------------------- */

#define ISA_FAST_MAX_BLOCKS (1ULL << 26)	/* 4 GiB of message per call */

/*
 * The trap is the first SHA256RNDS2 of BoringSSL's sha256_block_data_order_hw (verified by
 * hashing the function's bytes): rdi = state, rsi = current block, rdx = blocks left, and the
 * working state is in xmm1/xmm2. Hash all remaining blocks with the kernel's SHA-256, store the
 * state as the function's tail would, and resume at its `ret`. Vector registers, rsi and rdx
 * are caller-saved scratch for this function. Returns false, having changed nothing, if the
 * code does not match or user memory is not accessible; the caller then emulates normally.
 */
static noinline bool isa_fast_sha256(struct pt_regs *regs, const struct isa_fastpath *e)
{
	unsigned long start = regs->ip - e->trap_off, data = regs->si;
	u64 blocks = regs->dx, left;
	struct sha256_ctx ctx = {};
	struct isa_vec x1, x2;
	bool ok = false;
	u8 out[32];
	u8 *page;
	int i;

	if (!blocks || blocks > ISA_FAST_MAX_BLOCKS)
		return false;
	page = kmalloc(PAGE_SIZE, GFP_KERNEL);
	if (!page)
		return false;
	if (copy_from_user(page, (void __user *)start, e->len) || isa_fp_hash(page, e) != e->hash)
		goto out;

	fpregs_lock();
	if (test_thread_flag(TIF_NEED_FPU_LOAD))
		switch_fpu_return();
	isa_rd_ymm(1, &x1);
	isa_rd_ymm(2, &x2);
	fpregs_unlock();
	isa_fp_sha256_state(ctx.ctx.state.h, x1.b, x2.b);

	for (left = blocks * SHA256_BLOCK_SIZE; left; ) {
		size_t n = min_t(u64, left, PAGE_SIZE);

		if (copy_from_user(page, (void __user *)data, n))
			goto out;
		sha256_update(&ctx, page, n);
		data += n;
		left -= n;
		cond_resched();
	}
	for (i = 0; i < 8; i++)
		isa_wr32(out + 4 * i, ctx.ctx.state.h[i]);
	if (copy_to_user((void __user *)regs->di, out, sizeof(out)))
		goto out;

	regs->si = data;
	regs->dx = 0;
	regs->ip = start + e->ret_off;
	this_cpu_inc(isa_fast_sha256_calls);
	this_cpu_add(isa_fast_sha256_blocks, blocks);
	ok = true;
out:
	kfree(page);
	return ok;
}

/*
 * The trap is the first SHA1MSG1 of an iteration of BoringSSL's SHA-NI SHA-1 loop (verified by hashing the
 * function's bytes; gen_fastpath.py checked its loop head and tail): rdi = state, rdx = blocks left after the
 * current one, rsi = next block (or the current one if it is the last), xmm0 = A..D and xmm9 = E as of the
 * start of the current block. The state in memory is only written by the function's tail, so it may be stale;
 * the registers are authoritative at every iteration. Hash the current and all remaining blocks with the
 * kernel's SHA-1, store the state as the tail would and resume at `ret`. Same failure rule as SHA-256: on any
 * mismatch or fault nothing has been modified and normal emulation continues.
 */
static noinline bool isa_fast_sha1(struct pt_regs *regs, const struct isa_fastpath *e)
{
	unsigned long start = regs->ip - e->trap_off;
	struct sha1_ctx ctx = {};
	struct isa_vec x0, x9;
	u64 data, blocks, left;
	bool ok = false;
	u8 out[20];
	u8 *page;
	int i;

	if (regs->dx >= ISA_FAST_MAX_BLOCKS)
		return false;
	isa_fp_sha1_args(regs->si, regs->dx, &data, &blocks);
	page = kmalloc(PAGE_SIZE, GFP_KERNEL);
	if (!page)
		return false;
	if (copy_from_user(page, (void __user *)start, e->len) || isa_fp_hash(page, e) != e->hash)
		goto out;

	fpregs_lock();
	if (test_thread_flag(TIF_NEED_FPU_LOAD))
		switch_fpu_return();
	isa_rd_ymm(0, &x0);
	isa_rd_ymm(9, &x9);
	fpregs_unlock();
	isa_fp_sha1_state(ctx.state.h, x0.b, x9.b);

	for (left = blocks * SHA1_BLOCK_SIZE; left; ) {
		size_t n = min_t(u64, left, PAGE_SIZE);

		if (copy_from_user(page, (void __user *)data, n))
			goto out;
		sha1_update(&ctx, page, n);
		data += n;
		left -= n;
		cond_resched();
	}
	for (i = 0; i < 5; i++)
		isa_wr32(out + 4 * i, ctx.state.h[i]);
	if (copy_to_user((void __user *)regs->di, out, sizeof(out)))
		goto out;

	regs->si = data;
	regs->dx = 0;
	regs->ip = start + e->ret_off;
	this_cpu_inc(isa_fast_sha1_calls);
	this_cpu_add(isa_fast_sha1_blocks, blocks);
	ok = true;
out:
	kfree(page);
	return ok;
}

static bool isa_emu_fastpath(struct pt_regs *regs, const struct isa_insn *in,
			     const unsigned char *buf, int nr)
{
	int i;

	if (in->op == ISA_SHA256RNDS2 && !in->is_mem && in->reg == 2 && in->rm == 1) {
		for (i = isa_fp_next(buf, nr, ISA_FP_SHA256_BLOCKS, 0); i >= 0;
		     i = isa_fp_next(buf, nr, ISA_FP_SHA256_BLOCKS, i + 1))
			if (isa_fast_sha256(regs, &isa_fastpaths[i]))
				return true;
	}
	if (in->op == ISA_SHA1MSG1 && !in->is_mem && in->reg == 4 && in->rm == 5) {
		for (i = isa_fp_next(buf, nr, ISA_FP_SHA1_BLOCKS, 0); i >= 0;
		     i = isa_fp_next(buf, nr, ISA_FP_SHA1_BLOCKS, i + 1))
			if (isa_fast_sha1(regs, &isa_fastpaths[i]))
				return true;
	}
	return false;
}

/* ---- the #UD hook -------------------------------------------------------------------- */

/*
 * Called from exc_invalid_op() for a #UD taken in user mode, with interrupts off.
 * Returns true if the instruction was emulated (or a fault on its memory operand was
 * turned into a signal) and the trap is fully handled.
 */
bool isa_emu_fixup(struct pt_regs *regs)
{
	unsigned char buf[MAX_INSN_SIZE];
	struct isa_vec src1, src2, dst, x0;
	struct isa_insn in;
	bool handled = false;
	int nr, len;

	if (!isa_emu_ready || !user_64bit_mode(regs))
		return false;

	if (regs->flags & X86_EFLAGS_IF)
		local_irq_enable();

	nr = insn_fetch_from_user(regs, buf);
	if (nr <= 0)
		goto out;
	len = isa_emu_decode(buf, nr, &in);
	if (len < 0)
		goto out;
	if (isa_emu_fast && isa_emu_fastpath(regs, &in, buf, nr)) {
		handled = true;
		goto out;
	}

	memset(&src2, 0, sizeof(src2));
	memset(&x0, 0, sizeof(x0));
	if (in.is_mem) {
		u64 gpr[16] = {
			regs->ax, regs->cx, regs->dx, regs->bx, regs->sp, regs->bp, regs->si, regs->di,
			regs->r8, regs->r9, regs->r10, regs->r11, regs->r12, regs->r13, regs->r14, regs->r15,
		};
		u64 segbase = 0, ea;

		if (in.seg == ISA_SEG_FS)
			segbase = x86_fsbase_read_task(current);
		else if (in.seg == ISA_SEG_GS)
			segbase = x86_gsbase_read_task(current);
		ea = isa_emu_ea(&in, gpr, regs->ip, segbase);
		if (copy_from_user(src2.b, (void __user *)ea, in.vl)) {
			/* what the real instruction would have done */
			force_sig_fault(SIGSEGV, SEGV_MAPERR, (void __user *)ea);
			handled = true;
			goto out;
		}
	}

	fpregs_lock();
	if (test_thread_flag(TIF_NEED_FPU_LOAD))
		switch_fpu_return();
	if (!in.is_mem)
		isa_rd_ymm(in.rm, &src2);
	isa_rd_ymm(in.vvvv, &src1);
	isa_rd_ymm(in.reg, &dst);
	if (in.op == ISA_SHA256RNDS2)
		isa_rd_ymm(0, &x0);
	isa_emu_compute(&isa_tables, &in, dst.b, src1.b, src2.b, x0.b);
	if (in.legacy)
		isa_wr_xmm(in.reg, &dst);
	else
		isa_wr_ymm(in.reg, &dst);
	fpregs_unlock();

	regs->ip += len;
	this_cpu_inc(isa_emu_count[in.op]);
	if (isa_emu_mode == 2)
		isa_emu_record(regs->ip - len, in.op);
	handled = true;
out:
	if (regs->flags & X86_EFLAGS_IF)
		local_irq_disable();
	return handled;
}

static int isa_emu_show(struct seq_file *m, void *v)
{
	int op;

	seq_printf(m, "mode %s\n", isa_emu_mode == 2 ? "profile" : isa_emu_ready ? "on" : "off");
	for (op = 1; op < ISA_OP_COUNT; op++)
		seq_printf(m, "%-18s %llu\n", isa_op_name[op], isa_emu_sum(op));
	seq_printf(m, "fastpath %s\n", isa_emu_fast ? "on" : "off");
	seq_printf(m, "fast_sha256_calls  %llu\n", isa_percpu_sum(&isa_fast_sha256_calls));
	seq_printf(m, "fast_sha256_blocks %llu\n", isa_percpu_sum(&isa_fast_sha256_blocks));
	seq_printf(m, "fast_sha1_calls  %llu\n", isa_percpu_sum(&isa_fast_sha1_calls));
	seq_printf(m, "fast_sha1_blocks %llu\n", isa_percpu_sum(&isa_fast_sha1_blocks));
	return 0;
}

static int isa_emu_sites_show(struct seq_file *m, void *v)
{
	u32 k;

	if (!isa_sites)
		return 0;
	for (k = 0; k < ISA_SITES; k++) {
		struct isa_site *e = &isa_sites[k];

		if (e->count)
			seq_printf(m, "%llu %s %x:%llu 0x%llx %s\n", e->count, isa_op_name[e->op],
				   e->dev, e->key_ino, e->key_off, e->name);
	}
	return 0;
}

static int __init isa_emu_init(void)
{
	if (!isa_emu_mode)
		return 0;
	/* The emulator reads and writes YMM state directly. */
	if (!boot_cpu_has(X86_FEATURE_AVX2) || !boot_cpu_has(X86_FEATURE_OSXSAVE)) {
		pr_info("disabled: CPU has no AVX2\n");
		return 0;
	}
	isa_emu_init_tables(&isa_tables);
	if (isa_emu_mode == 2) {
		isa_sites = vzalloc(array_size(ISA_SITES, sizeof(*isa_sites)));
		if (isa_sites)
			schedule_delayed_work(&isa_emu_report_work, 10 * HZ);
	}
	proc_create_single("isa_emu", 0444, NULL, isa_emu_show);
	proc_create_single("isa_emu_sites", 0444, NULL, isa_emu_sites_show);
	isa_emu_ready = true;
	pr_info("user-mode emulation enabled%s (gfni=%d avx_vnni=%d vaes=%d vpclmulqdq=%d sha_ni=%d native)\n",
		isa_emu_mode == 2 ? " with site profiling" : "",
		boot_cpu_has(X86_FEATURE_GFNI), boot_cpu_has(X86_FEATURE_AVX_VNNI),
		boot_cpu_has(X86_FEATURE_VAES), boot_cpu_has(X86_FEATURE_VPCLMULQDQ),
		boot_cpu_has(X86_FEATURE_SHA_NI));
	return 0;
}
arch_initcall(isa_emu_init);
