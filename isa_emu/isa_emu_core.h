/* SPDX-License-Identifier: GPL-2.0 */
/*
 * isa_emu_core.h - decode and compute x86-64 instructions that Googlebook OS userland
 * uses unconditionally but pre-Ice-Lake Intel CPUs (Kaby Lake: Pixelbook 2017) lack.
 *
 * Pure, freestanding C: no kernel or libc dependencies beyond memcpy/memset, so the
 * exact same code is built into the kernel #UD handler (arch/x86/kernel/isa_emu.c)
 * and into the userspace differential tester (test/difftest.c), which checks every
 * instruction form against native execution on a CPU that has them.
 *
 * Covered (64-bit mode only):
 *   GFNI        (V)GF2P8AFFINEQB, (V)GF2P8AFFINEINVQB, (V)GF2P8MULB   legacy + VEX.128/256
 *   AVX-VNNI    VPDPBUSD(S), VPDPWSSD(S)                              VEX.128/256
 *   AVX-IFMA    VPMADD52LUQ, VPMADD52HUQ                              VEX.128/256
 *   VAES        VAESENC, VAESENCLAST, VAESDEC, VAESDECLAST            VEX.128/256
 *   VPCLMULQDQ  VPCLMULQDQ                                            VEX.128/256
 *   SHA-NI      SHA1RNDS4, SHA1NEXTE, SHA1MSG1, SHA1MSG2,
 *               SHA256RNDS2, SHA256MSG1, SHA256MSG2                   legacy
 * Not covered: EVEX encodings (AVX-512 state), AVX-VNNI-INT8/INT16, AMX.
 */
#ifndef ISA_EMU_CORE_H
#define ISA_EMU_CORE_H

#ifdef __KERNEL__
#include <linux/types.h>
#include <linux/string.h>
#else
#include <stdint.h>
#include <string.h>
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int8_t s8;
typedef int16_t s16;
typedef int32_t s32;
typedef int64_t s64;
#endif

enum isa_op {
	ISA_OP_NONE = 0,
	ISA_GF2P8AFFINEQB,
	ISA_GF2P8AFFINEINVQB,
	ISA_GF2P8MULB,
	ISA_VPDPBUSD,
	ISA_VPDPBUSDS,
	ISA_VPDPWSSD,
	ISA_VPDPWSSDS,
	ISA_VPMADD52LUQ,
	ISA_VPMADD52HUQ,
	ISA_AESENC,
	ISA_AESENCLAST,
	ISA_AESDEC,
	ISA_AESDECLAST,
	ISA_PCLMULQDQ,
	ISA_SHA1RNDS4,
	ISA_SHA1NEXTE,
	ISA_SHA1MSG1,
	ISA_SHA1MSG2,
	ISA_SHA256RNDS2,
	ISA_SHA256MSG1,
	ISA_SHA256MSG2,
	ISA_OP_COUNT
};

#define ISA_SEG_NONE 0
#define ISA_SEG_FS   1
#define ISA_SEG_GS   2

#define ISA_DEC_NOT_OURS  (-1)	/* not an instruction this emulator handles */
#define ISA_DEC_TRUNCATED (-2)	/* ran out of bytes; caller may retry with more */

struct isa_insn {
	u8 op;		/* enum isa_op */
	u8 len;		/* total instruction length in bytes */
	u8 vl;		/* vector length in bytes: 16 or 32 */
	u8 legacy;	/* legacy SSE encoding: dest is also src1, bits 255:128 preserved */
	u8 reg;		/* ModRM.reg (+R): destination register */
	u8 vvvv;	/* VEX.vvvv: first source register (VEX only) */
	u8 rm;		/* ModRM.rm (+B): second source register when !is_mem */
	u8 is_mem;	/* second source is a memory operand */
	u8 imm;		/* imm8 (0 if none) */
	u8 seg;		/* ISA_SEG_* override */
	u8 addr32;	/* 0x67 address-size prefix */
	u8 has_base, has_index, rip_rel;
	u8 base, index, scale;
	s32 disp;
};

/* ---- little-endian unaligned accessors ------------------------------------ */
static inline u16 isa_rd16(const u8 *p) { u16 v; memcpy(&v, p, 2); return v; }
static inline u32 isa_rd32(const u8 *p) { u32 v; memcpy(&v, p, 4); return v; }
static inline u64 isa_rd64(const u8 *p) { u64 v; memcpy(&v, p, 8); return v; }
static inline void isa_wr32(u8 *p, u32 v) { memcpy(p, &v, 4); }
static inline void isa_wr64(u8 *p, u64 v) { memcpy(p, &v, 8); }

/* ---- decoder ---------------------------------------------------------------- */

struct isa_optab {
	u8 map;		/* 2 = 0F38, 3 = 0F3A */
	u8 pp;		/* 0 = none, 1 = 66 */
	u8 opcode;
	u8 op;
	u8 w;		/* VEX.W requirement: 0, 1, or 2 = ignored */
	u8 has_imm;
	u8 vex;		/* 1 = VEX form exists */
	u8 legacy;	/* 1 = legacy SSE form exists */
};

static const struct isa_optab isa_optab[] = {
	{ 3, 1, 0xCE, ISA_GF2P8AFFINEQB,    1, 1, 1, 1 },
	{ 3, 1, 0xCF, ISA_GF2P8AFFINEINVQB, 1, 1, 1, 1 },
	{ 2, 1, 0xCF, ISA_GF2P8MULB,        0, 0, 1, 1 },
	{ 2, 1, 0x50, ISA_VPDPBUSD,         0, 0, 1, 0 },
	{ 2, 1, 0x51, ISA_VPDPBUSDS,        0, 0, 1, 0 },
	{ 2, 1, 0x52, ISA_VPDPWSSD,         0, 0, 1, 0 },
	{ 2, 1, 0x53, ISA_VPDPWSSDS,        0, 0, 1, 0 },
	{ 2, 1, 0xB4, ISA_VPMADD52LUQ,      1, 0, 1, 0 },
	{ 2, 1, 0xB5, ISA_VPMADD52HUQ,      1, 0, 1, 0 },
	{ 2, 1, 0xDC, ISA_AESENC,           2, 0, 1, 0 },
	{ 2, 1, 0xDD, ISA_AESENCLAST,       2, 0, 1, 0 },
	{ 2, 1, 0xDE, ISA_AESDEC,           2, 0, 1, 0 },
	{ 2, 1, 0xDF, ISA_AESDECLAST,       2, 0, 1, 0 },
	{ 3, 1, 0x44, ISA_PCLMULQDQ,        2, 1, 1, 0 },
	{ 3, 0, 0xCC, ISA_SHA1RNDS4,        0, 1, 0, 1 },
	{ 2, 0, 0xC8, ISA_SHA1NEXTE,        0, 0, 0, 1 },
	{ 2, 0, 0xC9, ISA_SHA1MSG1,         0, 0, 0, 1 },
	{ 2, 0, 0xCA, ISA_SHA1MSG2,         0, 0, 0, 1 },
	{ 2, 0, 0xCB, ISA_SHA256RNDS2,      0, 0, 0, 1 },
	{ 2, 0, 0xCC, ISA_SHA256MSG1,       0, 0, 0, 1 },
	{ 2, 0, 0xCD, ISA_SHA256MSG2,       0, 0, 0, 1 },
};

/*
 * Decode one instruction from b[0..n). Returns its length (> 0) and fills *in,
 * or ISA_DEC_NOT_OURS / ISA_DEC_TRUNCATED.
 */
static inline int isa_emu_decode(const u8 *b, int n, struct isa_insn *in)
{
	const struct isa_optab *t = NULL;
	int p = 0, i;
	u8 osz = 0, rep = 0, seg = ISA_SEG_NONE, addr32 = 0;
	u8 R = 0, X = 0, B = 0, W = 0, L = 0, pp = 0, map = 0, vvvv = 0, vex = 0;
	u8 opcode, modrm, mod, rmf;

#define ISA_NEED(k) do { if (p + (k) > n) return ISA_DEC_TRUNCATED; } while (0)

	memset(in, 0, sizeof(*in));
	if (n > 15)
		n = 15;

	/* legacy prefixes */
	for (;;) {
		ISA_NEED(1);
		switch (b[p]) {
		case 0x26: case 0x2E: case 0x36: case 0x3E:	/* ES/CS/SS/DS: ignored in 64-bit mode */
			p++; continue;
		case 0x64: seg = ISA_SEG_FS; p++; continue;
		case 0x65: seg = ISA_SEG_GS; p++; continue;
		case 0x66: osz = 1; p++; continue;
		case 0x67: addr32 = 1; p++; continue;
		case 0xF2: case 0xF3: rep = b[p]; p++; continue;
		case 0xF0: return ISA_DEC_NOT_OURS;		/* LOCK: #UD for all of these */
		}
		break;
	}

	if (b[p] == 0xC4) {
		/* three-byte VEX; 66/F2/F3/REX before VEX is #UD */
		if (osz || rep)
			return ISA_DEC_NOT_OURS;
		ISA_NEED(4);
		R = !(b[p + 1] & 0x80);
		X = !(b[p + 1] & 0x40);
		B = !(b[p + 1] & 0x20);
		map = b[p + 1] & 0x1F;
		W = b[p + 2] >> 7;
		vvvv = (~(b[p + 2] >> 3)) & 0x0F;
		L = (b[p + 2] >> 2) & 1;
		pp = b[p + 2] & 3;
		opcode = b[p + 3];
		p += 4;
		vex = 1;
	} else {
		u8 rex = 0;

		if ((b[p] & 0xF0) == 0x40) {
			rex = b[p++];
			ISA_NEED(1);
		}
		if (b[p] != 0x0F)
			return ISA_DEC_NOT_OURS;
		p++;
		ISA_NEED(2);
		if (b[p] == 0x38)
			map = 2;
		else if (b[p] == 0x3A)
			map = 3;
		else
			return ISA_DEC_NOT_OURS;
		opcode = b[p + 1];
		p += 2;
		if (rep)
			return ISA_DEC_NOT_OURS;
		pp = osz;
		R = (rex >> 2) & 1;
		X = (rex >> 1) & 1;
		B = rex & 1;
	}

	for (i = 0; i < (int)(sizeof(isa_optab) / sizeof(isa_optab[0])); i++) {
		const struct isa_optab *c = &isa_optab[i];

		if (c->map != map || c->pp != pp || c->opcode != opcode)
			continue;
		if (vex ? !c->vex : !c->legacy)
			continue;
		if (vex && c->w != 2 && c->w != W)
			continue;
		t = c;
		break;
	}
	if (!t)
		return ISA_DEC_NOT_OURS;

	ISA_NEED(1);
	modrm = b[p++];
	mod = modrm >> 6;
	rmf = modrm & 7;

	in->op = t->op;
	in->legacy = !vex;
	in->vl = (vex && L) ? 32 : 16;
	in->reg = ((modrm >> 3) & 7) | (R << 3);
	in->vvvv = vex ? vvvv : in->reg;
	in->seg = seg;
	in->addr32 = addr32;

	if (mod == 3) {
		in->rm = rmf | (B << 3);
	} else {
		in->is_mem = 1;
		if (rmf == 4) {
			u8 sib;

			ISA_NEED(1);
			sib = b[p++];
			in->scale = sib >> 6;
			if (((sib >> 3) & 7) != 4 || X) {
				in->has_index = 1;
				in->index = ((sib >> 3) & 7) | (X << 3);
			}
			if ((sib & 7) == 5 && mod == 0) {
				ISA_NEED(4);
				in->disp = (s32)isa_rd32(b + p);
				p += 4;
			} else {
				in->has_base = 1;
				in->base = (sib & 7) | (B << 3);
			}
		} else if (rmf == 5 && mod == 0) {
			in->rip_rel = 1;
			ISA_NEED(4);
			in->disp = (s32)isa_rd32(b + p);
			p += 4;
		} else {
			in->has_base = 1;
			in->base = rmf | (B << 3);
		}
		if (mod == 1) {
			ISA_NEED(1);
			in->disp = (s8)b[p++];
		} else if (mod == 2) {
			ISA_NEED(4);
			in->disp = (s32)isa_rd32(b + p);
			p += 4;
		}
	}
	if (t->has_imm) {
		ISA_NEED(1);
		in->imm = b[p++];
	}
	in->len = p;
	return p;
#undef ISA_NEED
}

/*
 * Effective address of the memory operand. gpr[] is indexed by x86 register number
 * (0 = rax, 1 = rcx, 2 = rdx, 3 = rbx, 4 = rsp, 5 = rbp, 6 = rsi, 7 = rdi, 8..15 = r8..r15);
 * ip is the address of the instruction; segbase is the FS/GS base when in->seg is set.
 */
static inline u64 isa_emu_ea(const struct isa_insn *in, const u64 *gpr, u64 ip, u64 segbase)
{
	u64 ea = (u64)(s64)in->disp;

	if (in->rip_rel)
		ea += ip + in->len;
	if (in->has_base)
		ea += gpr[in->base];
	if (in->has_index)
		ea += gpr[in->index] << in->scale;
	if (in->addr32)
		ea = (u32)ea;
	return ea + segbase;
}

/* ---- GF(2^8) and AES tables -------------------------------------------------- */

struct isa_tables {
	u8 gf_inv[256];
	u8 sbox[256];
	u8 inv_sbox[256];
};

static inline u8 isa_gf_mul(u8 a, u8 b)
{
	u8 r = 0;

	while (b) {
		if (b & 1)
			r ^= a;
		a = (u8)(a << 1) ^ ((a & 0x80) ? 0x1B : 0);
		b >>= 1;
	}
	return r;
}

static inline u8 isa_parity8(u8 v)
{
	v ^= v >> 4;
	v ^= v >> 2;
	v ^= v >> 1;
	return v & 1;
}

/* SDM: out.bit[i] = parity(matrix.byte[7 - i] & x) ^ imm.bit[i] */
static inline u8 isa_affine_byte(u64 m, u8 x, u8 imm)
{
	u8 r = 0;
	int i;

	for (i = 0; i < 8; i++)
		r |= (u8)(isa_parity8((u8)(m >> (8 * (7 - i))) & x) << i);
	return r ^ imm;
}

static inline void isa_emu_init_tables(struct isa_tables *t)
{
	int a, b;

	t->gf_inv[0] = 0;
	for (a = 1; a < 256; a++)
		for (b = 1; b < 256; b++)
			if (isa_gf_mul((u8)a, (u8)b) == 1) {
				t->gf_inv[a] = (u8)b;
				break;
			}
	/* AES S-box = affine(inverse(x)) with the AES matrix and constant 0x63 */
	for (a = 0; a < 256; a++) {
		u8 s = isa_affine_byte(0xF1E3C78F1F3E7CF8ULL, t->gf_inv[a], 0x63);

		t->sbox[a] = s;
		t->inv_sbox[s] = (u8)a;
	}
}

/* ---- AES rounds (one 128-bit lane) ------------------------------------------- */

static inline void isa_aes_round(const struct isa_tables *t, int op, u8 *out,
				 const u8 *state, const u8 *key)
{
	u8 s[16], m[16];
	int r, c, i;
	int dec = (op == ISA_AESDEC || op == ISA_AESDECLAST);
	int last = (op == ISA_AESENCLAST || op == ISA_AESDECLAST);

	for (c = 0; c < 4; c++)
		for (r = 0; r < 4; r++) {
			if (!dec)
				s[r + 4 * c] = t->sbox[state[r + 4 * ((c + r) & 3)]];
			else
				s[r + 4 * c] = t->inv_sbox[state[r + 4 * ((c - r) & 3)]];
		}
	if (last) {
		memcpy(m, s, 16);
	} else if (!dec) {
		for (c = 0; c < 4; c++) {
			const u8 *a = s + 4 * c;

			m[4 * c + 0] = isa_gf_mul(a[0], 2) ^ isa_gf_mul(a[1], 3) ^ a[2] ^ a[3];
			m[4 * c + 1] = a[0] ^ isa_gf_mul(a[1], 2) ^ isa_gf_mul(a[2], 3) ^ a[3];
			m[4 * c + 2] = a[0] ^ a[1] ^ isa_gf_mul(a[2], 2) ^ isa_gf_mul(a[3], 3);
			m[4 * c + 3] = isa_gf_mul(a[0], 3) ^ a[1] ^ a[2] ^ isa_gf_mul(a[3], 2);
		}
	} else {
		for (c = 0; c < 4; c++) {
			const u8 *a = s + 4 * c;

			m[4 * c + 0] = isa_gf_mul(a[0], 14) ^ isa_gf_mul(a[1], 11) ^ isa_gf_mul(a[2], 13) ^ isa_gf_mul(a[3], 9);
			m[4 * c + 1] = isa_gf_mul(a[0], 9) ^ isa_gf_mul(a[1], 14) ^ isa_gf_mul(a[2], 11) ^ isa_gf_mul(a[3], 13);
			m[4 * c + 2] = isa_gf_mul(a[0], 13) ^ isa_gf_mul(a[1], 9) ^ isa_gf_mul(a[2], 14) ^ isa_gf_mul(a[3], 11);
			m[4 * c + 3] = isa_gf_mul(a[0], 11) ^ isa_gf_mul(a[1], 13) ^ isa_gf_mul(a[2], 9) ^ isa_gf_mul(a[3], 14);
		}
	}
	for (i = 0; i < 16; i++)
		out[i] = m[i] ^ key[i];
}

/* ---- SHA helpers --------------------------------------------------------------- */

static inline u32 isa_rol32(u32 v, int n) { return (v << n) | (v >> (32 - n)); }
static inline u32 isa_ror32(u32 v, int n) { return (v >> n) | (v << (32 - n)); }

static inline void isa_sha1rnds4(u8 *out, const u8 *s1, const u8 *s2, u8 imm)
{
	static const u32 K[4] = { 0x5A827999, 0x6ED9EBA1, 0x8F1BBCDC, 0xCA62C1D6 };
	u32 a = isa_rd32(s1 + 12), b = isa_rd32(s1 + 8), c = isa_rd32(s1 + 4), d = isa_rd32(s1);
	u32 w[4] = { isa_rd32(s2 + 12), isa_rd32(s2 + 8), isa_rd32(s2 + 4), isa_rd32(s2) };
	u32 e = 0, k = K[imm & 3];
	int i;

	for (i = 0; i < 4; i++) {
		u32 f, tmp;

		switch (imm & 3) {
		case 0: f = (b & c) ^ (~b & d); break;
		case 2: f = (b & c) ^ (b & d) ^ (c & d); break;
		default: f = b ^ c ^ d; break;
		}
		tmp = f + isa_rol32(a, 5) + w[i] + e + k;
		e = d;
		d = c;
		c = isa_rol32(b, 30);
		b = a;
		a = tmp;
	}
	isa_wr32(out + 12, a);
	isa_wr32(out + 8, b);
	isa_wr32(out + 4, c);
	isa_wr32(out, d);
}

static inline void isa_sha256rnds2(u8 *out, const u8 *s1, const u8 *s2, const u8 *xmm0)
{
	u32 a = isa_rd32(s2 + 12), b = isa_rd32(s2 + 8), e = isa_rd32(s2 + 4), f = isa_rd32(s2);
	u32 c = isa_rd32(s1 + 12), d = isa_rd32(s1 + 8), g = isa_rd32(s1 + 4), h = isa_rd32(s1);
	int i;

	for (i = 0; i < 2; i++) {
		u32 wk = isa_rd32(xmm0 + 4 * i);
		u32 ch = (e & f) ^ (~e & g);
		u32 maj = (a & b) ^ (a & c) ^ (b & c);
		u32 s1e = isa_ror32(e, 6) ^ isa_ror32(e, 11) ^ isa_ror32(e, 25);
		u32 s0a = isa_ror32(a, 2) ^ isa_ror32(a, 13) ^ isa_ror32(a, 22);
		u32 t1 = ch + s1e + wk + h;
		u32 na = t1 + maj + s0a;
		u32 ne = t1 + d;

		h = g; g = f; f = e; e = ne;
		d = c; c = b; b = a; a = na;
	}
	isa_wr32(out + 12, a);
	isa_wr32(out + 8, b);
	isa_wr32(out + 4, e);
	isa_wr32(out, f);
}

static inline u32 isa_sig0(u32 x) { return isa_ror32(x, 7) ^ isa_ror32(x, 18) ^ (x >> 3); }
static inline u32 isa_sig1(u32 x) { return isa_ror32(x, 17) ^ isa_ror32(x, 19) ^ (x >> 10); }

/* ---- carry-less multiply --------------------------------------------------------- */

static inline void isa_clmul64(u64 a, u64 b, u64 *lo, u64 *hi)
{
	u64 l = 0, h = 0;
	int i;

	for (i = 0; i < 64; i++)
		if ((b >> i) & 1) {
			l ^= a << i;
			if (i)
				h ^= a >> (64 - i);
		}
	*lo = l;
	*hi = h;
}

static inline s32 isa_sat32(s64 v)
{
	if (v > 2147483647LL)
		return 2147483647;
	if (v < -2147483648LL)
		return (s32)(-2147483647 - 1);
	return (s32)v;
}

/*
 * Compute one instruction.
 *   dst   in: current value of the destination register (32 bytes)
 *         out: new value of the destination register (32 bytes). Legacy encodings
 *              keep bytes 16..31; VEX.128 zeroes them.
 *   src1  first source (VEX.vvvv register; for legacy encodings the destination)
 *   src2  second source (register or memory), vl bytes valid
 *   xmm0  low 16 bytes of XMM0 (only read by SHA256RNDS2)
 * Sources may alias dst.
 */
static inline void isa_emu_compute(const struct isa_tables *t, const struct isa_insn *in,
				   u8 *dst, const u8 *src1, const u8 *src2, const u8 *xmm0)
{
	u8 a[32], b[32], d[32], r[32];
	int vl = in->vl, i, j;

	memcpy(d, dst, 32);
	memcpy(a, src1, 32);
	memset(b, 0, 32);
	memcpy(b, src2, vl);
	memset(r, 0, 32);

	switch (in->op) {
	case ISA_GF2P8AFFINEQB:
	case ISA_GF2P8AFFINEINVQB:
		for (i = 0; i < vl; i++) {
			u8 x = a[i];

			if (in->op == ISA_GF2P8AFFINEINVQB)
				x = t->gf_inv[x];
			r[i] = isa_affine_byte(isa_rd64(b + (i & ~7)), x, in->imm);
		}
		break;
	case ISA_GF2P8MULB:
		for (i = 0; i < vl; i++)
			r[i] = isa_gf_mul(a[i], b[i]);
		break;
	case ISA_VPDPBUSD:
	case ISA_VPDPBUSDS:
		for (i = 0; i < vl; i += 4) {
			s64 sum = 0;

			for (j = 0; j < 4; j++)
				sum += (s64)a[i + j] * (s64)(s8)b[i + j];
			if (in->op == ISA_VPDPBUSDS)
				isa_wr32(r + i, (u32)isa_sat32((s64)(s32)isa_rd32(d + i) + sum));
			else
				isa_wr32(r + i, isa_rd32(d + i) + (u32)sum);
		}
		break;
	case ISA_VPDPWSSD:
	case ISA_VPDPWSSDS:
		for (i = 0; i < vl; i += 4) {
			s64 sum = (s64)(s16)isa_rd16(a + i) * (s64)(s16)isa_rd16(b + i) +
				  (s64)(s16)isa_rd16(a + i + 2) * (s64)(s16)isa_rd16(b + i + 2);

			if (in->op == ISA_VPDPWSSDS)
				isa_wr32(r + i, (u32)isa_sat32((s64)(s32)isa_rd32(d + i) + sum));
			else
				isa_wr32(r + i, isa_rd32(d + i) + (u32)sum);
		}
		break;
	case ISA_VPMADD52LUQ:
	case ISA_VPMADD52HUQ:
		for (i = 0; i < vl; i += 8) {
			unsigned __int128 p = (unsigned __int128)(isa_rd64(a + i) & 0xFFFFFFFFFFFFFULL) *
					      (isa_rd64(b + i) & 0xFFFFFFFFFFFFFULL);
			u64 part = in->op == ISA_VPMADD52LUQ ? (u64)p & 0xFFFFFFFFFFFFFULL
							    : (u64)(p >> 52);

			isa_wr64(r + i, isa_rd64(d + i) + part);
		}
		break;
	case ISA_AESENC:
	case ISA_AESENCLAST:
	case ISA_AESDEC:
	case ISA_AESDECLAST:
		for (i = 0; i < vl; i += 16)
			isa_aes_round(t, in->op, r + i, a + i, b + i);
		break;
	case ISA_PCLMULQDQ:
		for (i = 0; i < vl; i += 16) {
			u64 lo, hi;

			isa_clmul64(isa_rd64(a + i + ((in->imm & 0x01) ? 8 : 0)),
				    isa_rd64(b + i + ((in->imm & 0x10) ? 8 : 0)), &lo, &hi);
			isa_wr64(r + i, lo);
			isa_wr64(r + i + 8, hi);
		}
		break;
	case ISA_SHA1RNDS4:
		isa_sha1rnds4(r, a, b, in->imm);
		break;
	case ISA_SHA1NEXTE:
		memcpy(r, b, 12);
		isa_wr32(r + 12, isa_rd32(b + 12) + isa_rol32(isa_rd32(a + 12), 30));
		break;
	case ISA_SHA1MSG1:
		isa_wr32(r + 12, isa_rd32(a + 4) ^ isa_rd32(a + 12));
		isa_wr32(r + 8, isa_rd32(a) ^ isa_rd32(a + 8));
		isa_wr32(r + 4, isa_rd32(b + 12) ^ isa_rd32(a + 4));
		isa_wr32(r, isa_rd32(b + 8) ^ isa_rd32(a));
		break;
	case ISA_SHA1MSG2: {
		u32 w16 = isa_rol32(isa_rd32(a + 12) ^ isa_rd32(b + 8), 1);
		u32 w17 = isa_rol32(isa_rd32(a + 8) ^ isa_rd32(b + 4), 1);
		u32 w18 = isa_rol32(isa_rd32(a + 4) ^ isa_rd32(b), 1);
		u32 w19 = isa_rol32(isa_rd32(a) ^ w16, 1);

		isa_wr32(r + 12, w16);
		isa_wr32(r + 8, w17);
		isa_wr32(r + 4, w18);
		isa_wr32(r, w19);
		break;
	}
	case ISA_SHA256RNDS2:
		isa_sha256rnds2(r, a, b, xmm0);
		break;
	case ISA_SHA256MSG1:
		isa_wr32(r + 12, isa_rd32(a + 12) + isa_sig0(isa_rd32(b)));
		isa_wr32(r + 8, isa_rd32(a + 8) + isa_sig0(isa_rd32(a + 12)));
		isa_wr32(r + 4, isa_rd32(a + 4) + isa_sig0(isa_rd32(a + 8)));
		isa_wr32(r, isa_rd32(a) + isa_sig0(isa_rd32(a + 4)));
		break;
	case ISA_SHA256MSG2: {
		u32 w16 = isa_rd32(a) + isa_sig1(isa_rd32(b + 8));
		u32 w17 = isa_rd32(a + 4) + isa_sig1(isa_rd32(b + 12));
		u32 w18 = isa_rd32(a + 8) + isa_sig1(w16);
		u32 w19 = isa_rd32(a + 12) + isa_sig1(w17);

		isa_wr32(r, w16);
		isa_wr32(r + 4, w17);
		isa_wr32(r + 8, w18);
		isa_wr32(r + 12, w19);
		break;
	}
	default:
		memcpy(r, d, 32);
		break;
	}

	if (in->legacy)
		memcpy(r + 16, d + 16, 16);	/* legacy SSE leaves bits 255:128 alone */
	memcpy(dst, r, 32);
}

#endif /* ISA_EMU_CORE_H */
