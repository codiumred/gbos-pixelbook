/* SPDX-License-Identifier: GPL-2.0 */
/*
 * isa_emu_fastpath.h - recognise well-known whole functions built from emulated instructions.
 *
 * Emulating one instruction per trap is correct but slow when a function consists mostly of
 * such instructions. BoringSSL's SHA-NI SHA-256 block function needs about 56 traps per 64-byte
 * block and, on CPUs without SHA-NI, causes almost all traps during boot. When the trap site
 * is the first SHA256RNDS2 of a function whose bytes hash to a known value, the kernel can do
 * the whole remaining job (hash every remaining block) natively and resume at the function's
 * `ret`. If anything does not match, or user memory cannot be read, nothing is modified and the
 * normal one-instruction emulation proceeds, so this is purely an optimisation.
 *
 * Shared by the kernel (arch/x86/kernel/isa_emu.c) and the userspace test (test/fptest.c).
 */
#ifndef ISA_EMU_FASTPATH_H
#define ISA_EMU_FASTPATH_H

#define ISA_FP_SHA256_BLOCKS 1	/* void f(u32 state[8] /rdi/, const u8 *data /rsi/, size_t blocks /rdx/) */
#define ISA_FP_SHA1_BLOCKS 2	/* void f(u32 state[5] /rdi/, const u8 *data /rsi/, size_t blocks /rdx/) */

struct isa_fastpath {
	u8 kind;
	u8 head[8];	/* instruction bytes at the trap site (cheap prefilter) */
	u16 len;	/* function length, start through `ret` */
	u16 trap_off;	/* offset of the trap site */
	u16 ret_off;	/* offset of the `ret` */
	u16 mask_off;	/* bytes excluded from the hash (a RIP-relative displacement) */
	u8 mask_len;
	u64 hash;	/* FNV-1a 64 over the function bytes, masked bytes taken as 0 */
};

#include "isa_emu_fastpath_table.h"

#define ISA_FP_COUNT ((int)(sizeof(isa_fastpaths) / sizeof(isa_fastpaths[0])))
#define ISA_FP_MAX_LEN 1024

static inline u64 isa_fp_hash(const u8 *fn, const struct isa_fastpath *e)
{
	u64 h = 0xCBF29CE484222325ULL;
	unsigned int i;

	for (i = 0; i < e->len; i++) {
		u8 b = (i >= e->mask_off && i < (unsigned int)e->mask_off + e->mask_len) ? 0 : fn[i];

		h = (h ^ b) * 0x100000001B3ULL;
	}
	return h;
}

/* Next table entry at or after index i whose trap-site bytes match insn[0..8), or -1. */
static inline int isa_fp_next(const u8 *insn, int avail, int kind, int i)
{
	if (avail < 8)
		return -1;
	for (; i < ISA_FP_COUNT; i++)
		if (isa_fastpaths[i].kind == kind && isa_fastpaths[i].len <= ISA_FP_MAX_LEN &&
		    !memcmp(insn, isa_fastpaths[i].head, 8))
			return i;
	return -1;
}

/*
 * SHA-256 working state at the trap site of sha256_block_data_order_hw:
 * xmm1 = A,B,E,F and xmm2 = C,D,G,H, most significant dword first.
 */
static inline void isa_fp_sha256_state(u32 h[8], const u8 *xmm1, const u8 *xmm2)
{
	h[0] = isa_rd32(xmm1 + 12);
	h[1] = isa_rd32(xmm1 + 8);
	h[4] = isa_rd32(xmm1 + 4);
	h[5] = isa_rd32(xmm1);
	h[2] = isa_rd32(xmm2 + 12);
	h[3] = isa_rd32(xmm2 + 8);
	h[6] = isa_rd32(xmm2 + 4);
	h[7] = isa_rd32(xmm2);
}

/*
 * SHA-1 working state at the trap site of BoringSSL's SHA-NI SHA-1 loop (the first SHA1MSG1 of an
 * iteration, right after the loop head): xmm0 = A,B,C,D and xmm9 = E in its top dword, most significant
 * dword first. At that point rdx has already been decremented (blocks left after the current one) and rsi
 * has been advanced to the next block unless the current block is the last. gen_fastpath.py only accepts
 * variants whose loop head and tail are byte for byte the code this relies on.
 */
static inline void isa_fp_sha1_state(u32 h[5], const u8 *xmm0, const u8 *xmm9)
{
	h[0] = isa_rd32(xmm0 + 12);
	h[1] = isa_rd32(xmm0 + 8);
	h[2] = isa_rd32(xmm0 + 4);
	h[3] = isa_rd32(xmm0);
	h[4] = isa_rd32(xmm9 + 12);
}

/* Current block and number of blocks (including the current one) from rsi/rdx at the SHA-1 trap site. */
static inline void isa_fp_sha1_args(u64 rsi, u64 rdx, u64 *data, u64 *blocks)
{
	*blocks = rdx + 1;
	*data = rdx ? rsi - 64 : rsi;
}

#endif /* ISA_EMU_FASTPATH_H */
