// SPDX-License-Identifier: GPL-2.0
/*
 * difftest - differential test of isa_emu_core.h against native execution.
 *
 * Run on a CPU that natively implements the emulated instructions (GFNI, AVX-VNNI,
 * VAES, VPCLMULQDQ, SHA-NI; AVX-IFMA if present). For each random test case it
 *   1. encodes one instruction (all operand forms, addressing modes, prefixes),
 *   2. executes it natively from a JIT stub with fully randomized YMM/GPR state,
 *   3. decodes + computes it with the emulator from the same initial state,
 *   4. compares instruction length and all 16 YMM registers.
 * A second pass mutates encodings and checks that anything the decoder accepts is
 * also a valid native instruction with the same result (no false accepts).
 *
 *   ./difftest [iterations] [seed]
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <signal.h>
#include <setjmp.h>
#include <unistd.h>
#include <cpuid.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <asm/prctl.h>
#include <fcntl.h>
#include <sched.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <sys/wait.h>
#include <sys/reboot.h>

#include "../isa_emu_core.h"

struct state {
	u8 ymm[16][32];
	u64 gpr[16];
	u64 save_rsp;
};

#define ARENA_SIZE   (1u << 20)
#define CODE_OFF     0x0000
#define STATE_OFF    0x2000
#define GS_OFF       0x3000
#define DATA_OFF     0x10000
#define DATA_SIZE    0xC0000
#define STACK_OFF    0xE8000

static u8 *arena;
static struct state *st;
static struct isa_tables tables;
static sigjmp_buf jb;
static volatile sig_atomic_t in_native;
static u64 fsbase, gsbase;

/* ---- rng ---------------------------------------------------------------------- */
static u64 rng_s;
static u64 rnd(void)
{
	rng_s ^= rng_s >> 12;
	rng_s ^= rng_s << 25;
	rng_s ^= rng_s >> 27;
	return rng_s * 0x2545F4914F6CDD1DULL;
}
static u32 rn(u32 n) { return (u32)(rnd() % n); }

static void fill_vec(u8 *v)
{
	static const u8 eb[] = { 0x00, 0x01, 0x7f, 0x80, 0xff, 0xfe, 0x81 };
	static const u16 ew[] = { 0x0000, 0x0001, 0x7fff, 0x8000, 0xffff, 0x8001 };
	static const u32 ed[] = { 0, 1, 0x7fffffff, 0x80000000, 0xffffffff, 0x7ffffff0, 0x80000010 };
	int i, style = rn(8);

	for (i = 0; i < 32; i++)
		v[i] = (u8)rnd();
	switch (style) {
	case 0: for (i = 0; i < 32; i++) v[i] = eb[rn(sizeof(eb))]; break;
	case 1: for (i = 0; i < 32; i += 2) { u16 w = ew[rn(6)]; memcpy(v + i, &w, 2); } break;
	case 2: for (i = 0; i < 32; i += 4) { u32 d = ed[rn(7)]; memcpy(v + i, &d, 4); } break;
	case 3: memset(v, 0, 32); v[rn(32)] = (u8)(1u << rn(8)); break;
	case 4: for (i = 0; i < 32; i += 8) { u64 q = rn(2) ? ~0ULL : (rnd() | 0xFFFFFFFFFFFFFULL); memcpy(v + i, &q, 8); } break;
	default: break;
	}
}

/* ---- JIT stub -------------------------------------------------------------------- */
static u8 *emit(u8 *p, const void *b, int n) { memcpy(p, b, n); return p + n; }
static u8 *emit_abs(u8 *p, const u8 *pre, int n, u8 regfield, void *addr)
{
	u32 a = (u32)(uintptr_t)addr;

	p = emit(p, pre, n);
	*p++ = 0x04 | (regfield << 3);
	*p++ = 0x25;
	return emit(p, &a, 4);
}

static void build_stub(const u8 *insn, int len)
{
	static const u8 push[] = { 0x53, 0x55, 0x41, 0x54, 0x41, 0x55, 0x41, 0x56, 0x41, 0x57 };
	static const u8 pop[] = { 0x41, 0x5F, 0x41, 0x5E, 0x41, 0x5D, 0x41, 0x5C, 0x5D, 0x5B };
	static const u8 tail[] = { 0xC5, 0xF8, 0x77, 0xC3 };
	u8 *p = arena + CODE_OFF;
	u8 pre[3];
	int i;

	p = emit(p, push, sizeof(push));
	pre[0] = 0x48; pre[1] = 0x89;
	p = emit_abs(p, pre, 2, 4, &st->save_rsp);
	for (i = 0; i < 16; i++) {
		pre[0] = 0xC5; pre[1] = i < 8 ? 0xFE : 0x7E; pre[2] = 0x6F;
		p = emit_abs(p, pre, 3, i & 7, st->ymm[i]);
	}
	for (i = 0; i < 16; i++) {
		pre[0] = 0x48 | (i >= 8 ? 4 : 0); pre[1] = 0x8B;
		p = emit_abs(p, pre, 2, i & 7, &st->gpr[i]);
	}
	/* the instruction under test lives at a fixed, known address */
	p = emit(p, insn, len);
	memset(p, 0x90, 16);
	p += 16;
	pre[0] = 0x48; pre[1] = 0x8B;
	p = emit_abs(p, pre, 2, 4, &st->save_rsp);
	for (i = 0; i < 16; i++) {
		pre[0] = 0xC5; pre[1] = i < 8 ? 0xFE : 0x7E; pre[2] = 0x7F;
		p = emit_abs(p, pre, 3, i & 7, st->ymm[i]);
	}
	p = emit(p, pop, sizeof(pop));
	emit(p, tail, sizeof(tail));
}

/* address at which build_stub() places the instruction */
static u64 insn_addr(void)
{
	return (u64)(uintptr_t)(arena + CODE_OFF + 10 + 8 + 16 * 9 + 16 * 8);
}

static volatile sig_atomic_t last_sig;
static void *volatile last_addr;

static void on_fault(int sig, siginfo_t *si, void *uc)
{
	(void)uc;
	last_sig = sig;
	last_addr = si->si_addr;
	if (in_native)
		siglongjmp(jb, 1);
	_exit(99);
}

/* returns 0 if the instruction executed, 1 if it faulted */
static int run_native(void)
{
	in_native = 1;
	if (sigsetjmp(jb, 1)) {
		in_native = 0;
		return 1;
	}
	((void (*)(void))(arena + CODE_OFF))();
	in_native = 0;
	return 0;
}

/* ---- encoder ------------------------------------------------------------------------ */
struct enc {
	const struct isa_optab *t;
	int vex, L, W;
	int reg, vvvv, rm;
	int is_mem, mode;	/* mode: 0 base(+index), 1 rip, 2 abs(+index) */
	int base, index, has_index, scale, dispsz;
	s32 disp;
	int seg, addr32;
	u8 imm;
	u8 extra_prefix[4];
	int n_extra;
	int map_override, pp_override, opcode_override;	/* -1 = none */
};

static int encode(const struct enc *e, u8 *out, u64 ip, u64 target)
{
	u8 *p = out;
	int R = (e->reg >> 3) & 1, X = 0, B = 0;
	int map = e->map_override >= 0 ? e->map_override : e->t->map;
	int pp = e->pp_override >= 0 ? e->pp_override : e->t->pp;
	int opcode = e->opcode_override >= 0 ? e->opcode_override : e->t->opcode;
	u8 modrm, sib = 0;
	int use_sib = 0, mod = 3, dispsz = 0, i;
	u8 *disp_at = NULL;

	for (i = 0; i < e->n_extra; i++)
		*p++ = e->extra_prefix[i];
	if (e->seg == ISA_SEG_FS) *p++ = 0x64;
	if (e->seg == ISA_SEG_GS) *p++ = 0x65;
	if (e->addr32) *p++ = 0x67;

	if (!e->is_mem) {
		B = (e->rm >> 3) & 1;
		modrm = 0xC0 | ((e->reg & 7) << 3) | (e->rm & 7);
	} else if (e->mode == 1) {
		mod = 0; dispsz = 4;
		modrm = ((e->reg & 7) << 3) | 5;
	} else if (e->mode == 2) {
		mod = 0; dispsz = 4; use_sib = 1;
		if (e->has_index) { X = (e->index >> 3) & 1; sib = (e->scale << 6) | ((e->index & 7) << 3) | 5; }
		else sib = (4 << 3) | 5;
		modrm = ((e->reg & 7) << 3) | 4;
	} else {
		B = (e->base >> 3) & 1;
		dispsz = e->dispsz;
		if (dispsz == 0 && (e->base & 7) == 5)
			dispsz = 1;
		mod = dispsz == 0 ? 0 : dispsz == 1 ? 1 : 2;
		if (e->has_index || (e->base & 7) == 4) {
			use_sib = 1;
			if (e->has_index) { X = (e->index >> 3) & 1; sib = (e->scale << 6) | ((e->index & 7) << 3) | (e->base & 7); }
			else sib = (4 << 3) | (e->base & 7);
			modrm = (mod << 6) | ((e->reg & 7) << 3) | 4;
		} else {
			modrm = (mod << 6) | ((e->reg & 7) << 3) | (e->base & 7);
		}
	}

	if (e->vex) {
		*p++ = 0xC4;
		*p++ = (u8)((!R << 7) | (!X << 6) | (!B << 5) | (map & 0x1F));
		*p++ = (u8)((e->W << 7) | ((~e->vvvv & 0xF) << 3) | (e->L << 2) | (pp & 3));
	} else {
		if (pp == 1) *p++ = 0x66;
		if (R || X || B || rn(4) == 0)
			*p++ = (u8)(0x40 | (R << 2) | (X << 1) | B);
		*p++ = 0x0F;
		*p++ = map == 2 ? 0x38 : 0x3A;
	}
	*p++ = (u8)opcode;
	*p++ = modrm;
	if (use_sib) *p++ = sib;
	if (dispsz == 1) { *p++ = (u8)(s8)e->disp; }
	else if (dispsz == 4) { disp_at = p; p += 4; }
	if (e->t->has_imm) *p++ = e->imm;

	if (disp_at) {
		s32 d = e->disp;

		if (e->is_mem && e->mode == 1)
			d = (s32)(target - (ip + (u64)(p - out)));
		memcpy(disp_at, &d, 4);
	}
	return (int)(p - out);
}

/* ---- feature detection ---------------------------------------------------------------- */
static int have[ISA_OP_COUNT];
static void detect(void)
{
	unsigned a, b, c, d, a1 = 0, b1, c1, d1;
	int gfni, vaes, vpclmul, sha, vnni = 0, ifma = 0, i;

	__cpuid_count(7, 0, a, b, c, d);
	gfni = (c >> 8) & 1; vaes = (c >> 9) & 1; vpclmul = (c >> 10) & 1; sha = (b >> 29) & 1;
	if (a >= 1) {
		__cpuid_count(7, 1, a1, b1, c1, d1);
		vnni = (a1 >> 4) & 1; ifma = (a1 >> 23) & 1;
	}
	for (i = 0; i < ISA_OP_COUNT; i++) have[i] = 0;
	have[ISA_GF2P8AFFINEQB] = have[ISA_GF2P8AFFINEINVQB] = have[ISA_GF2P8MULB] = gfni;
	have[ISA_VPDPBUSD] = have[ISA_VPDPBUSDS] = have[ISA_VPDPWSSD] = have[ISA_VPDPWSSDS] = vnni;
	have[ISA_VPMADD52LUQ] = have[ISA_VPMADD52HUQ] = ifma;
	have[ISA_AESENC] = have[ISA_AESENCLAST] = have[ISA_AESDEC] = have[ISA_AESDECLAST] = vaes;
	have[ISA_PCLMULQDQ] = vpclmul;
	for (i = ISA_SHA1RNDS4; i <= ISA_SHA256MSG2; i++) have[i] = sha;
	printf("native oracle: gfni=%d avx_vnni=%d avx_ifma=%d vaes=%d vpclmulqdq=%d sha=%d\n",
	       gfni, vnni, ifma, vaes, vpclmul, sha);
}

/* independent reference for AVX-IFMA when the host cannot execute it */
static void ifma_ref(int hi, int vl, u8 *dst, const u8 *a, const u8 *b)
{
	int i;

	for (i = 0; i < 32; i += 8) {
		u64 x, y, d, lo, mid, hi_, r;

		if (i >= vl) { memset(dst + i, 0, 8); continue; }
		memcpy(&x, a + i, 8); memcpy(&y, b + i, 8); memcpy(&d, dst + i, 8);
		x &= (1ULL << 52) - 1; y &= (1ULL << 52) - 1;
		/* 26-bit limbs: x = x1*2^26 + x0 */
		{
			u64 x0 = x & 0x3FFFFFF, x1 = x >> 26, y0 = y & 0x3FFFFFF, y1 = y >> 26;

			lo = x0 * y0; mid = x0 * y1 + x1 * y0; hi_ = x1 * y1;
			/* product = hi_*2^52 + mid*2^26 + lo */
			u64 low52 = (lo + ((mid & 0x3FFFFFF) << 26));
			u64 carry = low52 >> 52;

			low52 &= (1ULL << 52) - 1;
			r = hi ? (hi_ + (mid >> 26) + carry) : low52;
		}
		d += r;
		memcpy(dst + i, &d, 8);
	}
}

/* ---- one test case ---------------------------------------------------------------------- */
static const char *opname[ISA_OP_COUNT] = {
	"none", "gf2p8affineqb", "gf2p8affineinvqb", "gf2p8mulb", "vpdpbusd", "vpdpbusds", "vpdpwssd",
	"vpdpwssds", "vpmadd52luq", "vpmadd52huq", "aesenc", "aesenclast", "aesdec", "aesdeclast",
	"pclmulqdq", "sha1rnds4", "sha1nexte", "sha1msg1", "sha1msg2", "sha256rnds2", "sha256msg1", "sha256msg2",
};
static unsigned long n_pass[ISA_OP_COUNT], n_ref[ISA_OP_COUNT], n_fail, n_mut_accept, n_mut_total, n_mut_reject_valid;

static void dump(const char *what, const u8 *code, int len, const struct state *init, const struct state *nat, const struct state *emu)
{
	int i, j;

	printf("FAIL: %s\n  bytes:", what);
	for (i = 0; i < len; i++) printf(" %02x", code[i]);
	printf("\n");
	for (i = 0; i < 16; i++)
		if (memcmp(nat->ymm[i], emu->ymm[i], 32)) {
			printf("  ymm%-2d init  :", i); for (j = 31; j >= 0; j--) printf("%02x", init->ymm[i][j]);
			printf("\n  ymm%-2d native:", i); for (j = 31; j >= 0; j--) printf("%02x", nat->ymm[i][j]);
			printf("\n  ymm%-2d emu   :", i); for (j = 31; j >= 0; j--) printf("%02x", emu->ymm[i][j]);
			printf("\n");
		}
}

/* emulate against a copy of the initial state; returns decoded length or <0 */
static int run_emu(const u8 *code, int avail, u64 ip, struct state *s, struct isa_insn *in)
{
	u8 src2[32], dstv[32];
	int len = isa_emu_decode(code, avail, in);

	if (len < 0)
		return len;
	if (in->is_mem) {
		u64 ea = isa_emu_ea(in, s->gpr, ip,
				    in->seg == ISA_SEG_FS ? fsbase : in->seg == ISA_SEG_GS ? gsbase : 0);

		if (ea < (u64)(uintptr_t)arena || ea + 32 > (u64)(uintptr_t)arena + ARENA_SIZE)
			return -100;	/* emulator computed an address outside the arena */
		memset(src2, 0, 32);
		memcpy(src2, (void *)(uintptr_t)ea, in->vl);
	} else {
		memcpy(src2, s->ymm[in->rm], 32);
	}
	memcpy(dstv, s->ymm[in->reg], 32);
	isa_emu_compute(&tables, in, dstv, s->ymm[in->vvvv], src2, s->ymm[0]);
	memcpy(s->ymm[in->reg], dstv, 32);
	return len;
}

static void random_enc(struct enc *e)
{
	const struct isa_optab *t = &isa_optab[rn(sizeof(isa_optab) / sizeof(isa_optab[0]))];

	memset(e, 0, sizeof(*e));
	e->map_override = e->pp_override = e->opcode_override = -1;
	e->t = t;
	e->vex = t->vex && (!t->legacy || rn(2));
	e->L = e->vex ? rn(2) : 0;
	e->W = t->w == 2 ? rn(2) : t->w;
	e->reg = rn(16); e->vvvv = rn(16); e->rm = rn(16);
	e->imm = (u8)rnd();
	if (rn(8) == 0) e->imm = (u8[]){ 0x00, 0x01, 0x10, 0x11, 0xff, 0x03 }[rn(6)];
	e->is_mem = rn(2);
	if (e->is_mem) {
		e->mode = rn(10) < 6 ? 0 : rn(2) + 1;
		e->base = rn(16);
		e->has_index = rn(2);
		do { e->index = rn(16); } while (e->index == 4);
		if (e->mode == 0 && e->index == e->base) e->has_index = 0;
		e->scale = rn(4);
		e->dispsz = (int[]){ 0, 1, 4 }[rn(3)];
		if (e->mode == 0 && e->dispsz == 0 && (e->base & 7) == 5)
			e->dispsz = 1;	/* rbp/r13 base has no disp-less encoding */
		e->disp = e->dispsz == 1 ? (s8)rnd() : (s32)rnd();
		e->addr32 = rn(6) == 0;
		if (e->mode == 0) {
			int s = rn(8);

			e->seg = s == 0 ? ISA_SEG_GS : (s == 1 && !e->addr32) ? ISA_SEG_FS : ISA_SEG_NONE;
		}
	}
}

/* set up registers/memory so the operand of *e resolves to a valid in-arena address */
static u64 place_operand(struct enc *e, const u8 *val)
{
	u64 off = DATA_OFF + rn(DATA_SIZE - 64);
	u64 target, segb = e->seg == ISA_SEG_FS ? fsbase : e->seg == ISA_SEG_GS ? gsbase : 0;
	int i;

	if (!e->vex)
		off &= ~15ULL;		/* legacy SSE memory operands must be aligned */
	target = (u64)(uintptr_t)arena + off;
	memcpy((void *)(uintptr_t)target, val, 32);

	for (i = 0; i < 16; i++)
		st->gpr[i] = rnd();
	st->gpr[4] = (u64)(uintptr_t)arena + STACK_OFF;

	if (e->mode == 2) {
		/* [index*scale + disp32] or [disp32] */
		if (e->has_index) {
			u64 idx = (u64)rn(0x1000) << 0;

			st->gpr[e->index] = e->addr32 ? (idx | (rnd() << 32)) : idx;
			e->disp = (s32)(target - segb - (idx << e->scale));
		} else {
			e->disp = (s32)(target - segb);
		}
	} else if (e->mode == 0) {
		u64 idx = 0, want = target - segb - (u64)(s64)(e->dispsz ? e->disp : 0);

		if (e->has_index) {
			idx = rnd();
			if (e->index == 4) e->has_index = 0;
			else st->gpr[e->index] = idx;
		}
		if (e->has_index)
			want -= idx << e->scale;
		if (e->addr32)
			want = (u32)want | (rnd() << 32);
		st->gpr[e->base] = want;
		if (e->base == 4 && e->addr32)
			st->gpr[4] = want;	/* garbage upper bits: only used as an address-size-32 base */
	}
	return target;
}

static int one_case(int mutate)
{
	struct enc e;
	struct state init, nat, emu;
	struct isa_insn in;
	u8 code[32], memval[32];
	u64 ip = insn_addr(), target = 0;
	int len, elen, faulted, i, op;

	random_enc(&e);
	op = e.t->op;
	for (i = 0; i < 16; i++)
		fill_vec(st->ymm[i]);
	fill_vec(memval);
	for (i = 0; i < 16; i++)
		st->gpr[i] = rnd();
	st->gpr[4] = (u64)(uintptr_t)arena + STACK_OFF;

	if (mutate) {
		static const u8 pfx[] = { 0x66, 0xF2, 0xF3, 0xF0, 0x2E, 0x3E, 0x48, 0x41 };

		e.is_mem = 0;	/* keep mutated encodings register-only so native execution is safe */
		e.imm = 0x90;	/* if the mutation drops the imm8, the stray byte is a NOP */
		e.seg = 0; e.addr32 = 0;
		switch (rn(6)) {
		case 0: e.W ^= 1; break;
		case 1: e.pp_override = rn(4); break;
		case 2: e.map_override = rn(3) + 1; break;
		case 3: e.opcode_override = isa_optab[rn(sizeof(isa_optab) / sizeof(isa_optab[0]))].opcode; break;
		case 4: e.extra_prefix[e.n_extra++] = pfx[rn(sizeof(pfx))]; break;
		default: e.opcode_override = (int)(rnd() & 0xff); e.map_override = rn(2) + 2; break;
		}
		if (!e.vex && (e.map_override == 1))
			e.map_override = 2;
	} else if (e.is_mem) {
		target = place_operand(&e, memval);
	}

	len = encode(&e, code, ip, target);
	memset(code + len, 0x90, sizeof(code) - len);
	init = *st;
	build_stub(code, len);

	emu = init;
	elen = run_emu(code, mutate ? len + 8 : len, ip, &emu, &in);

	if (mutate) {
		n_mut_total++;
		if (elen < 0)
			return 0;		/* rejected: fine (SIGILL is the fallback) */
		n_mut_accept++;
		faulted = run_native();
		nat = *st;
		if (faulted) {
			if (!have[in.op])
				return 0;	/* host cannot execute this op at all */
			dump("decoder accepted an encoding the CPU rejects", code, len, &init, &nat, &emu);
			return 1;
		}
		if (memcmp(nat.ymm, emu.ymm, sizeof(nat.ymm))) {
			dump("mutated encoding: result mismatch", code, len, &init, &nat, &emu);
			return 1;
		}
		return 0;
	}

	if (elen != len) {
		printf("FAIL: %s decode length %d, expected %d\n  bytes:", opname[op], elen, len);
		for (i = 0; i < len; i++) printf(" %02x", code[i]);
		printf("\n");
		return 1;
	}
	if (!have[op]) {
		/* no native oracle: compare with an independent reference where we have one */
		if (op == ISA_VPMADD52LUQ || op == ISA_VPMADD52HUQ) {
			struct state ref = init;
			u8 dstv[32], b[32];

			if (e.is_mem) memcpy(b, memval, 32); else memcpy(b, init.ymm[e.rm], 32);
			memcpy(dstv, init.ymm[e.reg], 32);
			ifma_ref(op == ISA_VPMADD52HUQ, e.L ? 32 : 16, dstv, init.ymm[e.vvvv], b);
			memcpy(ref.ymm[e.reg], dstv, 32);
			if (memcmp(ref.ymm, emu.ymm, sizeof(ref.ymm))) {
				dump("reference mismatch (no native oracle)", code, len, &init, &ref, &emu);
				return 1;
			}
			n_ref[op]++;
		}
		return 0;
	}
	faulted = run_native();
	nat = *st;
	if (faulted) {
		dump("native execution faulted on a valid encoding", code, len, &init, &nat, &emu);
		return 1;
	}
	if (memcmp(nat.ymm, emu.ymm, sizeof(nat.ymm))) {
		char what[96];

		snprintf(what, sizeof(what), "%s %s vl=%d %s", opname[op], e.vex ? "VEX" : "legacy",
			 e.L ? 32 : 16, e.is_mem ? "mem" : "reg");
		dump(what, code, len, &init, &nat, &emu);
		return 1;
	}
	n_pass[op]++;
	return 0;
}

/*
 * Guest-only checks of the kernel glue (meaningless on a CPU that has the instructions):
 * the memory operand of an emulated instruction must behave like a real access.
 */
static int glue_tests(const char *self)
{
	/* vgf2p8affineqb ymm1, ymm2, [abs32], 0 : C4 E3 ED CE 0C 25 <abs32> 00 */
	u8 code[32] = { 0xC4, 0xE3, 0xED, 0xCE, 0x0C, 0x25, 0, 0, 0, 0, 0x00 };
	struct state init, emu;
	struct isa_insn in;
	u8 *none, *fresh, *filemap = MAP_FAILED;
	int fails = 0, i, fd;
	u32 a;

	/* 1. unmapped operand: SIGSEGV at the operand address, not SIGILL */
	none = mmap(NULL, 4096, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_32BIT, -1, 0);
	a = (u32)(uintptr_t)none + 64;
	memcpy(code + 6, &a, 4);
	memset(code + 11, 0x90, sizeof(code) - 11);
	for (i = 0; i < 16; i++) fill_vec(st->ymm[i]);
	st->gpr[4] = (u64)(uintptr_t)arena + STACK_OFF;
	build_stub(code, 11);
	last_sig = 0;
	if (!run_native() || last_sig != SIGSEGV || last_addr != (void *)(uintptr_t)a) {
		printf("FAIL: unmapped operand: sig=%d addr=%p (want SIGSEGV at %#x)\n", (int)last_sig, last_addr, a);
		fails++;
	} else {
		printf("glue: unmapped operand -> SIGSEGV at operand address: ok\n");
	}

	/* 2. operand on a page that has never been faulted in (anonymous, then file-backed) */
	fresh = mmap(NULL, 2 * 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_32BIT, -1, 0);
	fd = open(self, O_RDONLY);
	if (fd >= 0)
		filemap = mmap(NULL, 16 * 4096, PROT_READ, MAP_PRIVATE | MAP_32BIT, fd, 0);
	for (i = 0; i < 2; i++) {
		u8 *page = i == 0 ? fresh : filemap, expect[32];

		if (page == MAP_FAILED) {
			printf("glue: file-backed operand test skipped (cannot map %s)\n", self);
			continue;
		}
		a = (u32)(uintptr_t)page + (i == 0 ? 4096 - 16 : 9 * 4096 + 24);	/* straddles / deep in file */
		if (i == 0) memset(expect, 0, 32);
		else if (pread(fd, expect, 32, 9 * 4096 + 24) != 32) continue;
		memcpy(code + 6, &a, 4);
		for (int r = 0; r < 16; r++) fill_vec(st->ymm[r]);
		init = *st;
		build_stub(code, 11);
		last_sig = 0;
		if (run_native()) {
			printf("FAIL: not-present %s operand: got signal %d\n", i ? "file" : "anon", (int)last_sig);
			fails++;
			continue;
		}
		emu = init;
		isa_emu_decode(code, 11, &in);
		isa_emu_compute(&tables, &in, emu.ymm[1], init.ymm[2], expect, init.ymm[0]);
		if (memcmp(emu.ymm, st->ymm, sizeof(emu.ymm))) {
			printf("FAIL: not-present %s operand: wrong result\n", i ? "file" : "anon");
			fails++;
		} else {
			printf("glue: not-present %s-backed operand page faulted in and read: ok\n", i ? "file" : "anon");
		}
	}
	return fails;
}

int main(int argc, char **argv)
{
	unsigned long iters = 2000000, k;
	struct sigaction sa;
	stack_t ss;
	int i, guest = 0, nproc = 1, child = 0, argi = 1;
	pid_t kids[16];

	if (argc > 1 && !strcmp(argv[1], "--guest")) {
		guest = 1; nproc = 4; argi = 2; iters = 100000;
	}
	if (getpid() == 1) {
		guest = 1; nproc = 4; iters = 100000;	/* running as /init in a test initramfs */
		mkdir("/proc", 0755);
		mount("proc", "/proc", "proc", 0, NULL);
	}
	if (argc > argi) iters = strtoul(argv[argi], NULL, 0);
	rng_s = argc > argi + 1 ? strtoull(argv[argi + 1], NULL, 0) : 0x9E3779B97F4A7C15ULL;
	setvbuf(stdout, NULL, _IOLBF, 0);

	for (i = 1; i < nproc; i++) {
		kids[i] = fork();
		if (kids[i] == 0) { child = i; rng_s += 0x1234567ULL * i; break; }
	}

	arena = mmap(NULL, ARENA_SIZE, PROT_READ | PROT_WRITE | PROT_EXEC,
		     MAP_PRIVATE | MAP_ANONYMOUS | MAP_32BIT, -1, 0);
	if (arena == MAP_FAILED) { perror("mmap"); return 2; }
	st = (struct state *)(arena + STATE_OFF);

	ss.ss_sp = malloc(1 << 16); ss.ss_size = 1 << 16; ss.ss_flags = 0;
	sigaltstack(&ss, NULL);
	memset(&sa, 0, sizeof(sa));
	sa.sa_sigaction = on_fault;
	sa.sa_flags = SA_ONSTACK | SA_NODEFER | SA_SIGINFO;
	sigaction(SIGILL, &sa, NULL);
	sigaction(SIGSEGV, &sa, NULL);
	sigaction(SIGBUS, &sa, NULL);
	sigaction(SIGFPE, &sa, NULL);
	sigaction(SIGTRAP, &sa, NULL);

	gsbase = (u64)(uintptr_t)arena + GS_OFF;
	if (syscall(SYS_arch_prctl, ARCH_SET_GS, gsbase) || syscall(SYS_arch_prctl, ARCH_GET_FS, &fsbase)) {
		perror("arch_prctl"); return 2;
	}
	isa_emu_init_tables(&tables);
	if (!child)
		detect();
	else
		for (i = 0; i < ISA_OP_COUNT; i++) have[i] = 0;
	if (guest) {
		/* the kernel emulator is the "native" side: every op is expected to execute */
		for (i = 1; i < ISA_OP_COUNT; i++) have[i] = 1;
		if (!child) {
			printf("guest mode: comparing kernel #UD emulation against the userspace core, %d processes\n", nproc);
			n_fail += glue_tests(argv[0]);
		}
	}

	for (k = 0; k < iters; k++) {
		if (one_case(0)) n_fail++;
		if (n_fail > 5) break;
		if (guest && (k & 0xff) == 0) sched_yield();
	}
	for (k = 0; k < iters / 4 && n_fail <= 5; k++)
		if (one_case(1)) n_fail++;

	if (child)
		_exit(n_fail ? 1 : 0);
	for (i = 1; i < nproc; i++) {
		int status = 0;

		waitpid(kids[i], &status, 0);
		if (!WIFEXITED(status) || WEXITSTATUS(status)) {
			printf("FAIL: child %d status %#x\n", i, status);
			n_fail++;
		}
	}

	printf("%-18s %10s %10s\n", "op", "native-ok", "ref-ok");
	for (i = 1; i < ISA_OP_COUNT; i++)
		printf("%-18s %10lu %10lu%s\n", opname[i], n_pass[i], n_ref[i], have[i] ? "" : "   (no native oracle on this CPU)");
	printf("mutation fuzz: %lu encodings, %lu accepted by decoder (all matched native)\n", n_mut_total, n_mut_accept);
	if (guest) {
		FILE *f = fopen("/proc/isa_emu", "r");
		char line[128];

		while (f && fgets(line, sizeof(line), f))
			printf("  /proc/isa_emu: %s", line);
	}
	printf("%s: %lu failures\n", n_fail ? "ISA_EMU_TEST_FAILED" : "ISA_EMU_TEST_PASSED", n_fail);
	fflush(stdout);
	if (getpid() == 1) {
		sync();
		reboot(RB_POWER_OFF);
	}
	return n_fail ? 1 : 0;
}
