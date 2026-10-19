// SPDX-License-Identifier: GPL-2.0
/*
 * fptest - test the kernel's SHA-256 whole-function fast path (isa_emu_fastpath.h).
 *
 * Loads the real BoringSSL sha256_block_data_order_hw bytes and its constant table, as dumped
 * from the user's own recovery image by gen_fastpath.py --dump-dir (they are not part of this
 * repository), calls the function with random states/messages and compares the result with a
 * plain C SHA-256 compression function.
 *   - On a CPU with SHA-NI the function runs natively: this validates the harness.
 *   - In a guest without SHA-NI its first SHA256RNDS2 traps: with the fast path the kernel
 *     hashes the whole call; with isa_emu_fast=0 every SHA instruction is emulated one by one.
 * Also checks that faults behave like the real function: a message that runs into an unmapped
 * page, or a read-only state, must raise SIGSEGV and leave the state untouched.
 *
 * The same checks run for the SHA-NI path of BoringSSL's SHA-1 (test_sha1).
 *
 *   fptest sha256_fn.bin sha256_ktab.bin [sha1_fn.bin sha1_bswap.bin]
 *   (as /init it reads /fp/sha256_fn.bin, /fp/sha256_ktab.bin, /fp/sha1_fn.bin, /fp/sha1_bswap.bin)
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <signal.h>
#include <setjmp.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/reboot.h>

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
static inline u32 isa_rd32(const u8 *p) { u32 v; memcpy(&v, p, 4); return v; }
#include "../isa_emu_fastpath.h"

typedef void (*sha_fn)(u32 *state, const u8 *data, size_t blocks);

static const u32 K[64] = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};
#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void ref_blocks(u32 *h, const u8 *p, size_t n)
{
	for (; n; n--, p += 64) {
		u32 w[64], a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
		int i;

		for (i = 0; i < 16; i++)
			w[i] = (u32)p[4 * i] << 24 | (u32)p[4 * i + 1] << 16 | (u32)p[4 * i + 2] << 8 | p[4 * i + 3];
		for (; i < 64; i++) {
			u32 s0 = ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3);
			u32 s1 = ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10);

			w[i] = w[i - 16] + s0 + w[i - 7] + s1;
		}
		for (i = 0; i < 64; i++) {
			u32 t1 = hh + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i];
			u32 t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));

			hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
		}
		h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
	}
}

#define ROL(x, n) (((x) << (n)) | ((x) >> (32 - (n))))

static void ref_sha1_blocks(u32 *h, const u8 *p, size_t n)
{
	for (; n; n--, p += 64) {
		u32 w[80], a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
		int i;

		for (i = 0; i < 16; i++)
			w[i] = (u32)p[4 * i] << 24 | (u32)p[4 * i + 1] << 16 | (u32)p[4 * i + 2] << 8 | p[4 * i + 3];
		for (; i < 80; i++)
			w[i] = ROL(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
		for (i = 0; i < 80; i++) {
			u32 f, k, t;

			if (i < 20)      { f = (b & c) | (~b & d);           k = 0x5A827999; }
			else if (i < 40) { f = b ^ c ^ d;                     k = 0x6ED9EBA1; }
			else if (i < 60) { f = (b & c) | (b & d) | (c & d);  k = 0x8F1BBCDC; }
			else             { f = b ^ c ^ d;                     k = 0xCA62C1D6; }
			t = ROL(a, 5) + f + e + k + w[i];
			e = d; d = c; c = ROL(b, 30); b = a; a = t;
		}
		h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e;
	}
}

static u64 rng_s = 0x9E3779B97F4A7C15ULL;
static u64 rnd(void)
{
	rng_s ^= rng_s >> 12; rng_s ^= rng_s << 25; rng_s ^= rng_s >> 27;
	return rng_s * 0x2545F4914F6CDD1DULL;
}

static sigjmp_buf jb;
static volatile sig_atomic_t armed, last_sig;
static void on_fault(int sig)
{
	last_sig = sig;
	if (armed)
		siglongjmp(jb, 1);
	_exit(99);
}

static int load(const char *path, u8 *dst, size_t max)
{
	int fd = open(path, O_RDONLY), n;

	if (fd < 0) { perror(path); return -1; }
	n = read(fd, dst, max);
	close(fd);
	return n;
}

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec * 1e-9;
}

typedef void (*sha1_fn)(u32 *state, const u8 *data, size_t blocks);

/*
 * The SHA-NI path of BoringSSL's sha1_block_data_order, as dumped by gen_fastpath.py: same checks as for
 * SHA-256. In a guest its first SHA1MSG1 traps; the kernel recognises the function and hashes the whole call.
 * The fast path reads the working state from xmm0/xmm9 rather than memory, so random states, multi-block
 * calls (where the state in memory is stale after the first block) and every block count are exercised.
 */
static int test_sha1(const char *fn_path, const char *mask_path, int small, const u8 *buf)
{
	static const u32 iv[5] = { 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0 };
	int fails = 0, n, i, t, idx = -1, k;
	u8 *arena;
	sha1_fn fn;

	if (access(fn_path, R_OK) || access(mask_path, R_OK)) {
		printf("sha1: no %s / %s, skipped\n", fn_path, mask_path);
		return 0;
	}
	arena = mmap(NULL, 1 << 16, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS | MAP_32BIT, -1, 0);
	if (arena == MAP_FAILED) { perror("mmap"); return 1; }
	if (load(mask_path, arena + 0x1000, 16) != 16) { printf("FAIL: sha1: cannot load byte-swap mask\n"); return 1; }
	n = load(fn_path, arena + 0x2000, ISA_FP_MAX_LEN);
	for (k = 0; k < ISA_FP_COUNT; k++)
		if (isa_fastpaths[k].kind == ISA_FP_SHA1_BLOCKS && isa_fastpaths[k].len == n &&
		    isa_fp_hash(arena + 0x2000, &isa_fastpaths[k]) == isa_fastpaths[k].hash)
			idx = k;
	printf("sha1 function: %d bytes, %s the fast-path table\n", n, idx >= 0 ? "matches entry in" : "NOT IN");
	if (idx < 0) return 1;
	{
		/* retarget `movdqa xmm3,[rip+disp]` (displacement at +13, next instruction at +17) */
		int32_t disp = (int32_t)((arena + 0x1000) - (arena + 0x2000 + 17));

		memcpy(arena + 0x2000 + 13, &disp, 4);
	}
	fn = (sha1_fn)(arena + 0x2000);

	/* known answer: SHA-1("abc") */
	{
		u32 h[5];
		static const u32 want[5] = { 0xa9993e36, 0x4706816a, 0xba3e2571, 0x7850c26c, 0x9cd0d89d };
		u8 blk[64] = { 'a', 'b', 'c', 0x80 };

		blk[63] = 24;
		memcpy(h, iv, sizeof(h));
		fn(h, blk, 1);
		if (memcmp(h, want, sizeof(want))) { printf("FAIL: SHA-1(\"abc\") known answer\n"); fails++; }
		else printf("known answer SHA-1(\"abc\"): ok\n");
	}

	/* random states, block counts and alignments against the C reference */
	for (t = 0; t < (small ? 120 : 3000) && fails < 5; t++) {
		static const size_t lens[] = { 1, 1, 2, 3, 4, 7, 16, 63, 64, 65, 129, 1000, 4097 };
		size_t nb = t == 0 ? (small ? 300 : 100000) : lens[rnd() % (small ? 9 : 13)], off = rnd() % 4096;
		u32 h[5], r[5];

		for (i = 0; i < 5; i++) h[i] = r[i] = (u32)rnd();
		if (rnd() % 8 == 0) { memcpy(h, iv, sizeof(h)); memcpy(r, iv, sizeof(r)); }
		fn(h, buf + off, nb);
		ref_sha1_blocks(r, buf + off, nb);
		if (memcmp(h, r, sizeof(h))) { printf("FAIL: sha1 mismatch blocks=%zu off=%zu\n", nb, off); fails++; }
	}
	if (fails < 5) printf("sha1 random states/lengths/alignments vs C reference: ok (%d calls)\n", t);

	/* message runs into an unmapped page: SIGSEGV, state untouched */
	{
		u8 *m = mmap(NULL, 3 * 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		u32 h[5], keep[5];

		mprotect(m + 2 * 4096, 4096, PROT_NONE);
		for (i = 0; i < 5; i++) h[i] = keep[i] = (u32)rnd();
		last_sig = 0; armed = 1;
		if (!sigsetjmp(jb, 1))
			fn(h, m + 2 * 4096 - 5 * 64, 6);	/* 5 readable blocks, the 6th is unmapped */
		armed = 0;
		if (last_sig != SIGSEGV || memcmp(h, keep, sizeof(h))) { printf("FAIL: sha1 unmapped message tail: sig=%d state %s\n", (int)last_sig, memcmp(h, keep, sizeof(h)) ? "modified" : "intact"); fails++; }
		else printf("sha1 message running into an unmapped page -> SIGSEGV, state untouched: ok\n");

		/* read-only state: the final store must fault */
		{
			u32 *ro = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

			for (i = 0; i < 5; i++) ro[i] = keep[i];
			mprotect(ro, 4096, PROT_READ);
			last_sig = 0; armed = 1;
			if (!sigsetjmp(jb, 1))
				fn(ro, buf, 3);
			armed = 0;
			if (last_sig != SIGSEGV || memcmp(ro, keep, sizeof(keep))) { printf("FAIL: sha1 read-only state: sig=%d\n", (int)last_sig); fails++; }
			else printf("sha1 read-only state -> SIGSEGV on the final store: ok\n");
		}
	}

	/* throughput */
	{
		u32 h[5] = { 1, 2, 3, 4, 5 };
		size_t nb = small ? 256 : 16384, reps = 0;
		double t0 = now(), dt;

		do { fn(h, buf, nb); reps++; dt = now() - t0; } while (dt < 2.0 && reps < 256);
		printf("sha1 throughput: %.3f MiB/s (%.2f MiB in %.2f s)\n", reps * nb / 16384.0 / dt, reps * nb / 16384.0, dt);
	}
	return fails;
}

int main(int argc, char **argv)
{
	const char *fn_path = argc > 2 ? argv[1] : "/fp/sha256_fn.bin";
	const char *kt_path = argc > 2 ? argv[2] : "/fp/sha256_ktab.bin";
	const char *s1_path = argc > 4 ? argv[3] : "/fp/sha1_fn.bin";
	const char *s1_mask = argc > 4 ? argv[4] : "/fp/sha1_bswap.bin";
	int pid1 = getpid() == 1, fails = 0, n, i, t, small = 0;
	struct sigaction sa;
	u8 *arena, *buf;
	sha_fn fn;

	if (pid1) {
		mkdir("/proc", 0755);
		mount("proc", "/proc", "proc", 0, NULL);
	}
	setvbuf(stdout, NULL, _IOLBF, 0);
	{
		/* without the fast path every SHA instruction traps: keep the workload small */
		FILE *f = fopen("/proc/isa_emu", "r");
		char line[128];

		while (f && fgets(line, sizeof(line), f))
			if (strstr(line, "fastpath off"))
				small = 1;
		if (f)
			fclose(f);
		if (small)
			printf("fast path is off: using the reduced workload\n");
	}
	arena = mmap(NULL, 1 << 16, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS | MAP_32BIT, -1, 0);
	if (arena == MAP_FAILED) { perror("mmap"); return 2; }
	if (load(kt_path, arena + 0x1000, 0x1000) < 0x210) { printf("FAIL: cannot load constant table\n"); fails++; goto done; }
	n = load(fn_path, arena + 0x2000, ISA_FP_MAX_LEN);
	if (n < 64) { printf("FAIL: cannot load function\n"); fails++; goto done; }
	{
		int idx = -1, k;
		int32_t disp = (int32_t)((arena + 0x1000 + 0x80) - (arena + 0x2000 + 7));

		for (k = 0; k < ISA_FP_COUNT; k++)
			if (isa_fastpaths[k].len == n && isa_fp_hash(arena + 0x2000, &isa_fastpaths[k]) == isa_fastpaths[k].hash)
				idx = k;
		printf("function: %d bytes, %s the fast-path table\n", n, idx >= 0 ? "matches entry in" : "NOT IN");
		if (idx < 0) fails++;
		memcpy(arena + 0x2000 + 3, &disp, 4);	/* retarget the RIP-relative constant-table reference */
	}
	fn = (sha_fn)(arena + 0x2000);

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_fault;
	sa.sa_flags = SA_NODEFER;
	sigaction(SIGSEGV, &sa, NULL);
	sigaction(SIGILL, &sa, NULL);
	sigaction(SIGBUS, &sa, NULL);

	/* known answer: SHA-256("abc") */
	{
		u32 h[8] = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 };
		static const u32 want[8] = { 0xba7816bf, 0x8f01cfea, 0x414140de, 0x5dae2223, 0xb00361a3, 0x96177a9c, 0xb410ff61, 0xf20015ad };
		u8 blk[64] = { 'a', 'b', 'c', 0x80 };

		blk[63] = 24;
		fn(h, blk, 1);
		if (memcmp(h, want, sizeof(want))) { printf("FAIL: SHA-256(\"abc\") known answer\n"); fails++; }
		else printf("known answer SHA-256(\"abc\"): ok\n");
	}

	/* random states, lengths and alignments against the C reference */
	buf = mmap(NULL, 8 << 20, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	for (i = 0; i < 8 << 20; i += 8) { u64 r = rnd(); memcpy(buf + i, &r, 8); }
	for (t = 0; t < (small ? 120 : 3000) && fails < 5; t++) {
		static const size_t lens[] = { 1, 1, 2, 3, 4, 7, 16, 63, 64, 65, 129, 1000, 4097 };
		size_t nb = t == 0 ? (small ? 300 : 100000) : lens[rnd() % (small ? 9 : 13)], off = rnd() % 4096;
		u32 h[8], r[8];

		for (i = 0; i < 8; i++) h[i] = r[i] = (u32)rnd();
		if (rnd() % 8 == 0) { static const u32 iv[8] = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }; memcpy(h, iv, 32); memcpy(r, iv, 32); }
		fn(h, buf + off, nb);
		ref_blocks(r, buf + off, nb);
		if (memcmp(h, r, 32)) { printf("FAIL: mismatch blocks=%zu off=%zu\n", nb, off); fails++; }
	}
	if (fails < 5) printf("random states/lengths/alignments vs C reference: ok (%d calls)\n", t);

	/* message runs into an unmapped page: SIGSEGV, state untouched */
	{
		u8 *m = mmap(NULL, 3 * 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		u32 h[8], keep[8];

		mprotect(m + 2 * 4096, 4096, PROT_NONE);
		for (i = 0; i < 8; i++) h[i] = keep[i] = (u32)rnd();
		last_sig = 0; armed = 1;
		if (!sigsetjmp(jb, 1))
			fn(h, m + 2 * 4096 - 5 * 64, 6);	/* 5 readable blocks, the 6th is unmapped */
		armed = 0;
		if (last_sig != SIGSEGV || memcmp(h, keep, 32)) { printf("FAIL: unmapped message tail: sig=%d state %s\n", (int)last_sig, memcmp(h, keep, 32) ? "modified" : "intact"); fails++; }
		else printf("message running into an unmapped page -> SIGSEGV, state untouched: ok\n");

		/* read-only state: the final store must fault */
		{
			u32 *ro = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

			for (i = 0; i < 8; i++) ro[i] = keep[i];
			mprotect(ro, 4096, PROT_READ);
			last_sig = 0; armed = 1;
			if (!sigsetjmp(jb, 1))
				fn(ro, buf, 3);
			armed = 0;
			if (last_sig != SIGSEGV || memcmp(ro, keep, 32)) { printf("FAIL: read-only state: sig=%d\n", (int)last_sig); fails++; }
			else printf("read-only state -> SIGSEGV on the final store: ok\n");
		}
	}

	/* throughput */
	{
		u32 h[8] = { 1, 2, 3, 4, 5, 6, 7, 8 };
		size_t nb = small ? 256 : 16384, reps = 0;	/* 1 MiB (or 16 KiB) per call */
		double t0 = now(), dt;

		do { fn(h, buf, nb); reps++; dt = now() - t0; } while (dt < 2.0 && reps < 256);
		printf("throughput: %.3f MiB/s (%.2f MiB in %.2f s)\n", reps * nb / 16384.0 / dt, reps * nb / 16384.0, dt);
	}
	fails += test_sha1(s1_path, s1_mask, small, buf);
done:
	{
		FILE *f = fopen("/proc/isa_emu", "r");
		char line[128];

		while (f && fgets(line, sizeof(line), f))
			if (strstr(line, "fast") || strstr(line, "sha256") || strstr(line, "mode"))
				printf("  /proc/isa_emu: %s", line);
	}
	printf("%s: %d failures\n", fails ? "ISA_FP_TEST_FAILED" : "ISA_FP_TEST_PASSED", fails);
	fflush(stdout);
	if (pid1) { sync(); reboot(RB_POWER_OFF); }
	return fails ? 1 : 0;
}
