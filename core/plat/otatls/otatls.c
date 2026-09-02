/* Minimal TLS 1.2 client: TLS_RSA_WITH_AES_128_CBC_SHA.
 * Freestanding. Session state in the .otatls_cmd mailbox. */
#include "otatls.h"

#include <stddef.h>
#include <stdint.h>

#if defined(__APPLE__)
struct OtaTlsCmd otatls_guest_cmd = {
#else
__attribute__((section(".otatls_cmd"), used)) struct OtaTlsCmd otatls_guest_cmd = {
#endif
    OTATLS_MAGIC, 0, {0}, 0, 0, 0, 0, {0}, {0}, {0},
    {0}, {0}, {0}, {0}, {0}, 0, 0, 0, 0, {0}, 0, {0}, {0},
    {0}, {0}, {0}, {0}, {0}};

static void mem_set(void *p, uint8_t v, size_t n) {
  uint8_t *d = (uint8_t *)p;
  size_t i;
  for (i = 0; i < n; i++) {
    d[i] = v;
  }
}

static void mem_cpy(void *dst, const void *src, size_t n) {
  uint8_t *d = (uint8_t *)dst;
  const uint8_t *s = (const uint8_t *)src;
  size_t i;
  for (i = 0; i < n; i++) {
    d[i] = s[i];
  }
}

static int mem_eq(const void *a, const void *b, size_t n) {
  const uint8_t *x = (const uint8_t *)a;
  const uint8_t *y = (const uint8_t *)b;
  size_t i;
  uint8_t d = 0;
  for (i = 0; i < n; i++) {
    d = (uint8_t)(d | (x[i] ^ y[i]));
  }
  return d == 0;
}

static uint64_t rdtsc(void) {
#if defined(__x86_64__) || defined(__i386__)
  uint32_t lo, hi;
  __asm__ volatile("rdtsc" : "=a"(lo), "=d"(hi));
  return ((uint64_t)hi << 32) | lo;
#else
  static uint64_t x = 0x0A014149ULL;
  x = x * 6364136223846793005ULL + 1ULL;
  return x;
#endif
}

static void fill_rand(uint8_t *p, size_t n) {
  size_t i;
  uint64_t x = rdtsc() ^ 0x0A014149ULL;
  for (i = 0; i < n; i++) {
    x = x * 6364136223846793005ULL + 1ULL;
    p[i] = (uint8_t)(x >> 33);
  }
}

static uint32_t be16(const uint8_t *p) {
  return ((uint32_t)p[0] << 8) | p[1];
}

static uint32_t be24(const uint8_t *p) {
  return ((uint32_t)p[0] << 16) | ((uint32_t)p[1] << 8) | p[2];
}

static void put_be16(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)(v >> 8);
  p[1] = (uint8_t)v;
}

static void put_be24(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)(v >> 16);
  p[1] = (uint8_t)(v >> 8);
  p[2] = (uint8_t)v;
}

static void put_be64(uint8_t *p, uint64_t v) {
  int i;
  for (i = 7; i >= 0; i--) {
    p[i] = (uint8_t)v;
    v >>= 8;
  }
}

/* ---- SHA-1 ---- */
static void sha1_transform(uint32_t s[5], const uint8_t block[64]) {
  uint32_t w[80];
  uint32_t a, b, c, d, e;
  int i;
  for (i = 0; i < 16; i++) {
    w[i] = ((uint32_t)block[4 * i] << 24) | ((uint32_t)block[4 * i + 1] << 16) |
           ((uint32_t)block[4 * i + 2] << 8) | block[4 * i + 3];
  }
  for (i = 16; i < 80; i++) {
    uint32_t x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16];
    w[i] = (x << 1) | (x >> 31);
  }
  a = s[0];
  b = s[1];
  c = s[2];
  d = s[3];
  e = s[4];
  for (i = 0; i < 80; i++) {
    uint32_t f, k, t;
    if (i < 20) {
      f = (b & c) | ((~b) & d);
      k = 0x5A827999U;
    } else if (i < 40) {
      f = b ^ c ^ d;
      k = 0x6ED9EBA1U;
    } else if (i < 60) {
      f = (b & c) | (b & d) | (c & d);
      k = 0x8F1BBCDCU;
    } else {
      f = b ^ c ^ d;
      k = 0xCA62C1D6U;
    }
    t = ((a << 5) | (a >> 27)) + f + e + k + w[i];
    e = d;
    d = c;
    c = (b << 30) | (b >> 2);
    b = a;
    a = t;
  }
  s[0] += a;
  s[1] += b;
  s[2] += c;
  s[3] += d;
  s[4] += e;
}

static void sha1(const uint8_t *msg, size_t len, uint8_t out[20]) {
  uint32_t s[5] = {0x67452301U, 0xEFCDAB89U, 0x98BADCFEU, 0x10325476U,
                   0xC3D2E1F0U};
  uint8_t block[64];
  size_t i;
  uint64_t bitlen = (uint64_t)len * 8ULL;
  while (len >= 64) {
    sha1_transform(s, msg);
    msg += 64;
    len -= 64;
  }
  mem_set(block, 0, 64);
  mem_cpy(block, msg, len);
  block[len] = 0x80;
  if (len >= 56) {
    sha1_transform(s, block);
    mem_set(block, 0, 64);
  }
  for (i = 0; i < 8; i++) {
    block[63 - i] = (uint8_t)(bitlen >> (8 * i));
  }
  sha1_transform(s, block);
  for (i = 0; i < 5; i++) {
    out[4 * i] = (uint8_t)(s[i] >> 24);
    out[4 * i + 1] = (uint8_t)(s[i] >> 16);
    out[4 * i + 2] = (uint8_t)(s[i] >> 8);
    out[4 * i + 3] = (uint8_t)s[i];
  }
}

/* ---- SHA-256 ---- */
static const uint32_t K256[64] = {
    0x428A2F98U, 0x71374491U, 0xB5C0FBCFU, 0xE9B5DBA5U, 0x3956C25BU,
    0x59F111F1U, 0x923F82A4U, 0xAB1C5ED5U, 0xD807AA98U, 0x12835B01U,
    0x243185BEU, 0x550C7DC3U, 0x72BE5D74U, 0x80DEB1FEU, 0x9BDC06A7U,
    0xC19BF174U, 0xE49B69C1U, 0xEFBE4786U, 0x0FC19DC6U, 0x240CA1CCU,
    0x2DE92C6FU, 0x4A7484AAU, 0x5CB0A9DCU, 0x76F988DAU, 0x983E5152U,
    0xA831C66DU, 0xB00327C8U, 0xBF597FC7U, 0xC6E00BF3U, 0xD5A79147U,
    0x06CA6351U, 0x14292967U, 0x27B70A85U, 0x2E1B2138U, 0x4D2C6DFCU,
    0x53380D13U, 0x650A7354U, 0x766A0ABBU, 0x81C2C92EU, 0x92722C85U,
    0xA2BFE8A1U, 0xA81A664BU, 0xC24B8B70U, 0xC76C51A3U, 0xD192E819U,
    0xD6990624U, 0xF40E3585U, 0x106AA070U, 0x19A4C116U, 0x1E376C08U,
    0x2748774CU, 0x34B0BCB5U, 0x391C0CB3U, 0x4ED8AA4AU, 0x5B9CCA4FU,
    0x682E6FF3U, 0x748F82EEU, 0x78A5636FU, 0x84C87814U, 0x8CC70208U,
    0x90BEFFFAU, 0xA4506CEBU, 0xBEF9A3F7U, 0xC67178F2U};

static uint32_t rotr(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

static void sha256_transform(uint32_t s[8], const uint8_t block[64]) {
  uint32_t w[64];
  uint32_t a, b, c, d, e, f, g, h;
  int i;
  for (i = 0; i < 16; i++) {
    w[i] = ((uint32_t)block[4 * i] << 24) | ((uint32_t)block[4 * i + 1] << 16) |
           ((uint32_t)block[4 * i + 2] << 8) | block[4 * i + 3];
  }
  for (i = 16; i < 64; i++) {
    uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
    uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }
  a = s[0];
  b = s[1];
  c = s[2];
  d = s[3];
  e = s[4];
  f = s[5];
  g = s[6];
  h = s[7];
  for (i = 0; i < 64; i++) {
    uint32_t S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
    uint32_t ch = (e & f) ^ ((~e) & g);
    uint32_t t1 = h + S1 + ch + K256[i] + w[i];
    uint32_t S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
    uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
    uint32_t t2 = S0 + maj;
    h = g;
    g = f;
    f = e;
    e = d + t1;
    d = c;
    c = b;
    b = a;
    a = t1 + t2;
  }
  s[0] += a;
  s[1] += b;
  s[2] += c;
  s[3] += d;
  s[4] += e;
  s[5] += f;
  s[6] += g;
  s[7] += h;
}

static void sha256(const uint8_t *msg, size_t len, uint8_t out[32]) {
  uint32_t s[8] = {0x6A09E667U, 0xBB67AE85U, 0x3C6EF372U, 0xA54FF53AU,
                   0x510E527FU, 0x9B05688CU, 0x1F83D9ABU, 0x5BE0CD19U};
  uint8_t block[64];
  size_t i;
  uint64_t bitlen = (uint64_t)len * 8ULL;
  while (len >= 64) {
    sha256_transform(s, msg);
    msg += 64;
    len -= 64;
  }
  mem_set(block, 0, 64);
  mem_cpy(block, msg, len);
  block[len] = 0x80;
  if (len >= 56) {
    sha256_transform(s, block);
    mem_set(block, 0, 64);
  }
  for (i = 0; i < 8; i++) {
    block[63 - i] = (uint8_t)(bitlen >> (8 * i));
  }
  sha256_transform(s, block);
  for (i = 0; i < 8; i++) {
    out[4 * i] = (uint8_t)(s[i] >> 24);
    out[4 * i + 1] = (uint8_t)(s[i] >> 16);
    out[4 * i + 2] = (uint8_t)(s[i] >> 8);
    out[4 * i + 3] = (uint8_t)s[i];
  }
}

static void hmac_sha(int sha256p, const uint8_t *key, size_t key_len,
                     const uint8_t *msg, size_t msg_len, uint8_t *out) {
  uint8_t k[64];
  uint8_t kipad[64];
  uint8_t kopad[64];
  uint8_t inner[64 + 2048];
  uint8_t ih[32];
  uint8_t outer[64 + 32];
  size_t dig = sha256p ? 32u : 20u;
  size_t i;
  mem_set(k, 0, 64);
  if (key_len > 64) {
    if (sha256p) {
      sha256(key, key_len, k);
    } else {
      sha1(key, key_len, k);
    }
  } else {
    mem_cpy(k, key, key_len);
  }
  for (i = 0; i < 64; i++) {
    kipad[i] = (uint8_t)(k[i] ^ 0x36);
    kopad[i] = (uint8_t)(k[i] ^ 0x5c);
  }
  mem_cpy(inner, kipad, 64);
  mem_cpy(inner + 64, msg, msg_len);
  if (sha256p) {
    sha256(inner, 64 + msg_len, ih);
  } else {
    sha1(inner, 64 + msg_len, ih);
  }
  mem_cpy(outer, kopad, 64);
  mem_cpy(outer + 64, ih, dig);
  if (sha256p) {
    sha256(outer, 64 + dig, out);
  } else {
    sha1(outer, 64 + dig, out);
  }
}

static void hmac_sha1(const uint8_t *key, size_t key_len, const uint8_t *msg,
                      size_t msg_len, uint8_t out[20]) {
  hmac_sha(0, key, key_len, msg, msg_len, out);
}

static void hmac_sha256(const uint8_t *key, size_t key_len, const uint8_t *msg,
                        size_t msg_len, uint8_t out[32]) {
  hmac_sha(1, key, key_len, msg, msg_len, out);
}

/* TLS 1.2 PRF (SHA-256). */
static void tls_prf(const uint8_t *secret, size_t secret_len, const char *label,
                    const uint8_t *seed, size_t seed_len, uint8_t *out,
                    size_t out_len) {
  uint8_t label_seed[128];
  size_t label_len = 0;
  uint8_t a[32];
  uint8_t buf[32];
  size_t produced = 0;
  while (label[label_len]) {
    label_len++;
  }
  mem_cpy(label_seed, label, label_len);
  mem_cpy(label_seed + label_len, seed, seed_len);
  hmac_sha256(secret, secret_len, label_seed, label_len + seed_len, a);
  while (produced < out_len) {
    uint8_t cat[32 + 128];
    size_t n;
    size_t take;
    mem_cpy(cat, a, 32);
    mem_cpy(cat + 32, label_seed, label_len + seed_len);
    hmac_sha256(secret, secret_len, cat, 32 + label_len + seed_len, buf);
    take = out_len - produced;
    if (take > 32) {
      take = 32;
    }
    mem_cpy(out + produced, buf, take);
    produced += take;
    hmac_sha256(secret, secret_len, a, 32, a);
    (void)n;
  }
}

/* ---- AES-128 ---- */
static const uint8_t sbox[256] = {
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b,
    0xfe, 0xd7, 0xab, 0x76, 0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0,
    0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0, 0xb7, 0xfd, 0x93, 0x26,
    0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2,
    0xeb, 0x27, 0xb2, 0x75, 0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0,
    0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84, 0x53, 0xd1, 0x00, 0xed,
    0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f,
    0x50, 0x3c, 0x9f, 0xa8, 0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5,
    0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2, 0xcd, 0x0c, 0x13, 0xec,
    0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14,
    0xde, 0x5e, 0x0b, 0xdb, 0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c,
    0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79, 0xe7, 0xc8, 0x37, 0x6d,
    0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f,
    0x4b, 0xbd, 0x8b, 0x8a, 0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e,
    0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e, 0xe1, 0xf8, 0x98, 0x11,
    0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f,
    0xb0, 0x54, 0xbb, 0x16};

static const uint8_t rsbox[256] = {
    0x52, 0x09, 0x6a, 0xd5, 0x30, 0x36, 0xa5, 0x38, 0xbf, 0x40, 0xa3, 0x9e,
    0x81, 0xf3, 0xd7, 0xfb, 0x7c, 0xe3, 0x39, 0x82, 0x9b, 0x2f, 0xff, 0x87,
    0x34, 0x8e, 0x43, 0x44, 0xc4, 0xde, 0xe9, 0xcb, 0x54, 0x7b, 0x94, 0x32,
    0xa6, 0xc2, 0x23, 0x3d, 0xee, 0x4c, 0x95, 0x0b, 0x42, 0xfa, 0xc3, 0x4e,
    0x08, 0x2e, 0xa1, 0x66, 0x28, 0xd9, 0x24, 0xb2, 0x76, 0x5b, 0xa2, 0x49,
    0x6d, 0x8b, 0xd1, 0x25, 0x72, 0xf8, 0xf6, 0x64, 0x86, 0x68, 0x98, 0x16,
    0xd4, 0xa4, 0x5c, 0xcc, 0x5d, 0x65, 0xb6, 0x92, 0x6c, 0x70, 0x48, 0x50,
    0xfd, 0xed, 0xb9, 0xda, 0x5e, 0x15, 0x46, 0x57, 0xa7, 0x8d, 0x9d, 0x84,
    0x90, 0xd8, 0xab, 0x00, 0x8c, 0xbc, 0xd3, 0x0a, 0xf7, 0xe4, 0x58, 0x05,
    0xb8, 0xb3, 0x45, 0x06, 0xd0, 0x2c, 0x1e, 0x8f, 0xca, 0x3f, 0x0f, 0x02,
    0xc1, 0xaf, 0xbd, 0x03, 0x01, 0x13, 0x8a, 0x6b, 0x3a, 0x91, 0x11, 0x41,
    0x4f, 0x67, 0xdc, 0xea, 0x97, 0xf2, 0xcf, 0xce, 0xf0, 0xb4, 0xe6, 0x73,
    0x96, 0xac, 0x74, 0x22, 0xe7, 0xad, 0x35, 0x85, 0xe2, 0xf9, 0x37, 0xe8,
    0x1c, 0x75, 0xdf, 0x6e, 0x47, 0xf1, 0x1a, 0x71, 0x1d, 0x29, 0xc5, 0x89,
    0x6f, 0xb7, 0x62, 0x0e, 0xaa, 0x18, 0xbe, 0x1b, 0xfc, 0x56, 0x3e, 0x4b,
    0xc6, 0xd2, 0x79, 0x20, 0x9a, 0xdb, 0xc0, 0xfe, 0x78, 0xcd, 0x5a, 0xf4,
    0x1f, 0xdd, 0xa8, 0x33, 0x88, 0x07, 0xc7, 0x31, 0xb1, 0x12, 0x10, 0x59,
    0x27, 0x80, 0xec, 0x5f, 0x60, 0x51, 0x7f, 0xa9, 0x19, 0xb5, 0x4a, 0x0d,
    0x2d, 0xe5, 0x7a, 0x9f, 0x93, 0xc9, 0x9c, 0xef, 0xa0, 0xe0, 0x3b, 0x4d,
    0xae, 0x2a, 0xf5, 0xb0, 0xc8, 0xeb, 0xbb, 0x3c, 0x83, 0x53, 0x99, 0x61,
    0x17, 0x2b, 0x04, 0x7e, 0xba, 0x77, 0xd6, 0x26, 0xe1, 0x69, 0x14, 0x63,
    0x55, 0x21, 0x0c, 0x7d};

static const uint8_t rcon[11] = {0x00, 0x01, 0x02, 0x04, 0x08, 0x10,
                                 0x20, 0x40, 0x80, 0x1b, 0x36};

static void aes_key_expand(const uint8_t key[16], uint8_t rk[176]) {
  int i;
  mem_cpy(rk, key, 16);
  for (i = 4; i < 44; i++) {
    uint8_t t[4];
    t[0] = rk[4 * (i - 1)];
    t[1] = rk[4 * (i - 1) + 1];
    t[2] = rk[4 * (i - 1) + 2];
    t[3] = rk[4 * (i - 1) + 3];
    if ((i % 4) == 0) {
      uint8_t tmp = t[0];
      t[0] = (uint8_t)(sbox[t[1]] ^ rcon[i / 4]);
      t[1] = sbox[t[2]];
      t[2] = sbox[t[3]];
      t[3] = sbox[tmp];
    }
    rk[4 * i] = (uint8_t)(rk[4 * (i - 4)] ^ t[0]);
    rk[4 * i + 1] = (uint8_t)(rk[4 * (i - 4) + 1] ^ t[1]);
    rk[4 * i + 2] = (uint8_t)(rk[4 * (i - 4) + 2] ^ t[2]);
    rk[4 * i + 3] = (uint8_t)(rk[4 * (i - 4) + 3] ^ t[3]);
  }
}

static uint8_t xtime(uint8_t x) {
  return (uint8_t)((x << 1) ^ (((x >> 7) & 1) * 0x1b));
}

static void aes_encrypt_block(const uint8_t rk[176], const uint8_t in[16],
                              uint8_t out[16]) {
  uint8_t s[16];
  int round, i;
  mem_cpy(s, in, 16);
  for (i = 0; i < 16; i++) {
    s[i] ^= rk[i];
  }
  for (round = 1; round <= 10; round++) {
    uint8_t t[16];
    for (i = 0; i < 16; i++) {
      s[i] = sbox[s[i]];
    }
    t[0] = s[0];
    t[1] = s[5];
    t[2] = s[10];
    t[3] = s[15];
    t[4] = s[4];
    t[5] = s[9];
    t[6] = s[14];
    t[7] = s[3];
    t[8] = s[8];
    t[9] = s[13];
    t[10] = s[2];
    t[11] = s[7];
    t[12] = s[12];
    t[13] = s[1];
    t[14] = s[6];
    t[15] = s[11];
    mem_cpy(s, t, 16);
    if (round < 10) {
      for (i = 0; i < 4; i++) {
        uint8_t a0 = s[4 * i];
        uint8_t a1 = s[4 * i + 1];
        uint8_t a2 = s[4 * i + 2];
        uint8_t a3 = s[4 * i + 3];
        s[4 * i] = (uint8_t)(xtime(a0) ^ xtime(a1) ^ a1 ^ a2 ^ a3);
        s[4 * i + 1] = (uint8_t)(a0 ^ xtime(a1) ^ xtime(a2) ^ a2 ^ a3);
        s[4 * i + 2] = (uint8_t)(a0 ^ a1 ^ xtime(a2) ^ xtime(a3) ^ a3);
        s[4 * i + 3] = (uint8_t)(xtime(a0) ^ a0 ^ a1 ^ a2 ^ xtime(a3));
      }
    }
    for (i = 0; i < 16; i++) {
      s[i] ^= rk[16 * round + i];
    }
  }
  mem_cpy(out, s, 16);
}

static uint8_t gf_mul(uint8_t a, uint8_t b) {
  uint8_t p = 0;
  int i;
  for (i = 0; i < 8; i++) {
    if (b & 1) {
      p = (uint8_t)(p ^ a);
    }
    {
      uint8_t hi = (uint8_t)(a & 0x80);
      a = (uint8_t)(a << 1);
      if (hi) {
        a = (uint8_t)(a ^ 0x1b);
      }
    }
    b = (uint8_t)(b >> 1);
  }
  return p;
}

static void aes_decrypt_block(const uint8_t rk[176], const uint8_t in[16],
                              uint8_t out[16]) {
  uint8_t s[16];
  int round, i;
  mem_cpy(s, in, 16);
  for (i = 0; i < 16; i++) {
    s[i] ^= rk[160 + i];
  }
  for (round = 9; round >= 0; round--) {
    uint8_t t[16];
    t[0] = s[0];
    t[1] = s[13];
    t[2] = s[10];
    t[3] = s[7];
    t[4] = s[4];
    t[5] = s[1];
    t[6] = s[14];
    t[7] = s[11];
    t[8] = s[8];
    t[9] = s[5];
    t[10] = s[2];
    t[11] = s[15];
    t[12] = s[12];
    t[13] = s[9];
    t[14] = s[6];
    t[15] = s[3];
    mem_cpy(s, t, 16);
    for (i = 0; i < 16; i++) {
      s[i] = rsbox[s[i]];
    }
    for (i = 0; i < 16; i++) {
      s[i] ^= rk[16 * round + i];
    }
    if (round > 0) {
      for (i = 0; i < 4; i++) {
        uint8_t a0 = s[4 * i];
        uint8_t a1 = s[4 * i + 1];
        uint8_t a2 = s[4 * i + 2];
        uint8_t a3 = s[4 * i + 3];
        s[4 * i] = (uint8_t)(gf_mul(a0, 0x0e) ^ gf_mul(a1, 0x0b) ^
                             gf_mul(a2, 0x0d) ^ gf_mul(a3, 0x09));
        s[4 * i + 1] = (uint8_t)(gf_mul(a0, 0x09) ^ gf_mul(a1, 0x0e) ^
                                 gf_mul(a2, 0x0b) ^ gf_mul(a3, 0x0d));
        s[4 * i + 2] = (uint8_t)(gf_mul(a0, 0x0d) ^ gf_mul(a1, 0x09) ^
                                 gf_mul(a2, 0x0e) ^ gf_mul(a3, 0x0b));
        s[4 * i + 3] = (uint8_t)(gf_mul(a0, 0x0b) ^ gf_mul(a1, 0x0d) ^
                                 gf_mul(a2, 0x09) ^ gf_mul(a3, 0x0e));
      }
    }
  }
  mem_cpy(out, s, 16);
}

/* ---- RSA PKCS#1 v1.5 encrypt (64-bit limb LE modexp) ---- */
typedef unsigned __int128 u128;

static void lim_zero(uint64_t *a, int n) {
  int i;
  for (i = 0; i < n; i++) {
    a[i] = 0;
  }
}

static void lim_from_be(uint64_t *a, int n, const uint8_t *be, int len) {
  int i;
  lim_zero(a, n);
  for (i = 0; i < len; i++) {
    int bit = (len - 1 - i) * 8;
    int limb = bit / 64;
    int shift = bit % 64;
    if (limb < n) {
      a[limb] |= ((uint64_t)be[i]) << shift;
    }
  }
}

static void lim_to_be(const uint64_t *a, int n, uint8_t *be, int len) {
  int i;
  mem_set(be, 0, (size_t)len);
  for (i = 0; i < len; i++) {
    int bit = (len - 1 - i) * 8;
    int limb = bit / 64;
    int shift = bit % 64;
    if (limb < n) {
      be[i] = (uint8_t)(a[limb] >> shift);
    }
  }
}

static int lim_cmp(const uint64_t *a, const uint64_t *b, int n) {
  int i;
  for (i = n - 1; i >= 0; i--) {
    if (a[i] < b[i]) {
      return -1;
    }
    if (a[i] > b[i]) {
      return 1;
    }
  }
  return 0;
}

static void lim_sub2(uint64_t *a, const uint64_t *b, int n) {
  uint64_t borrow = 0;
  int i;
  for (i = 0; i < n; i++) {
    uint64_t x = a[i];
    uint64_t y = b[i];
    uint64_t z = x - borrow;
    uint64_t b1 = (x < borrow) ? 1ULL : 0ULL;
    uint64_t z2 = z - y;
    uint64_t b2 = (z < y) ? 1ULL : 0ULL;
    a[i] = z2;
    borrow = b1 | b2;
  }
}

static void lim_modmul(uint64_t *r, const uint64_t *a, const uint64_t *b,
                       const uint64_t *m, int n) {
  uint64_t t[64];
  int i, j, bit;
  lim_zero(t, 2 * n);
  for (i = 0; i < n; i++) {
    u128 carry = 0;
    for (j = 0; j < n; j++) {
      u128 cur = (u128)t[i + j] + (u128)a[i] * (u128)b[j] + carry;
      t[i + j] = (uint64_t)cur;
      carry = cur >> 64;
    }
    {
      u128 cur = (u128)t[i + n] + carry;
      t[i + n] = (uint64_t)cur;
      if (i + n + 1 < 2 * n) {
        t[i + n + 1] += (uint64_t)(cur >> 64);
      }
    }
  }
  for (bit = n * 64; bit >= 0; bit--) {
    uint64_t sh[64];
    int limb_sh = bit / 64;
    int bit_sh = bit % 64;
    lim_zero(sh, 2 * n);
    if (bit_sh == 0) {
      for (j = 0; j < n; j++) {
        if (j + limb_sh < 2 * n) {
          sh[j + limb_sh] = m[j];
        }
      }
    } else {
      for (j = 0; j < n; j++) {
        uint64_t lo = m[j] << bit_sh;
        uint64_t hi = m[j] >> (64 - bit_sh);
        if (j + limb_sh < 2 * n) {
          sh[j + limb_sh] |= lo;
        }
        if (j + limb_sh + 1 < 2 * n) {
          sh[j + limb_sh + 1] |= hi;
        }
      }
    }
    if (lim_cmp(t, sh, 2 * n) >= 0) {
      lim_sub2(t, sh, 2 * n);
    }
  }
  for (i = 0; i < n; i++) {
    r[i] = t[i];
  }
}

static void lim_modexp(uint64_t *r, const uint64_t *base, uint32_t e,
                       const uint64_t *m, int n) {
  uint64_t result[32];
  uint64_t b[32];
  lim_zero(result, n);
  result[0] = 1;
  mem_cpy(b, base, (size_t)n * sizeof(uint64_t));
  while (e > 0) {
    if (e & 1U) {
      uint64_t tmp[32];
      lim_modmul(tmp, result, b, m, n);
      mem_cpy(result, tmp, (size_t)n * sizeof(uint64_t));
    }
    {
      uint64_t tmp[32];
      lim_modmul(tmp, b, b, m, n);
      mem_cpy(b, tmp, (size_t)n * sizeof(uint64_t));
    }
    e >>= 1;
  }
  mem_cpy(r, result, (size_t)n * sizeof(uint64_t));
}

static int rsa_pkcs1_encrypt(const uint8_t *mod, int mod_len, uint32_t exp,
                             const uint8_t *msg, int msg_len, uint8_t *out) {
  uint8_t em[256];
  uint64_t mb[32];
  uint64_t nb[32];
  uint64_t cb[32];
  int nlimbs = (mod_len * 8 + 63) / 64;
  int ps_len;
  int i;
  if (mod_len > 256 || msg_len > mod_len - 11 || nlimbs > 32) {
    return -1;
  }
  mem_set(em, 0, (size_t)mod_len);
  em[0] = 0x00;
  em[1] = 0x02;
  ps_len = mod_len - msg_len - 3;
  fill_rand(em + 2, (size_t)ps_len);
  for (i = 0; i < ps_len; i++) {
    if (em[2 + i] == 0) {
      em[2 + i] = 0xA5;
    }
  }
  em[2 + ps_len] = 0x00;
  mem_cpy(em + 3 + ps_len, msg, (size_t)msg_len);
  lim_from_be(mb, nlimbs, em, mod_len);
  lim_from_be(nb, nlimbs, mod, mod_len);
  lim_modexp(cb, mb, exp, nb, nlimbs);
  lim_to_be(cb, nlimbs, out, mod_len);
  return 0;
}

/* DER length at p+1. Returns header size into *hdr, content length into *len. */
static int der_len_at(const uint8_t *p, const uint8_t *end, int *hdr, int *len) {
  int L;
  if (p + 1 >= end) {
    return -1;
  }
  L = p[1];
  if (L < 0x80) {
    *hdr = 2;
    *len = L;
    return (p + 2 + L <= end) ? 0 : -1;
  }
  if (L == 0x81) {
    if (p + 2 >= end) {
      return -1;
    }
    *hdr = 3;
    *len = p[2];
    return (p + 3 + *len <= end) ? 0 : -1;
  }
  if (L == 0x82) {
    if (p + 3 >= end) {
      return -1;
    }
    *hdr = 4;
    *len = (p[2] << 8) | p[3];
    return (p + 4 + *len <= end) ? 0 : -1;
  }
  return -1;
}

/* Split X.509 Certificate into TBSCertificate DER and signature bytes. */
static int x509_tbs_sig(const uint8_t *der, int der_len, const uint8_t **tbs,
                        int *tbs_len, const uint8_t **sig, int *sig_len) {
  const uint8_t *end = der + der_len;
  const uint8_t *p = der;
  int hdr, len, ah, al, sh, sl;
  if (der_len < 8 || der[0] != 0x30) {
    return -1;
  }
  if (der_len_at(p, end, &hdr, &len) != 0) {
    return -1;
  }
  p += hdr;
  /* tbsCertificate SEQUENCE — include its tag+len in the hash. */
  if (p >= end || p[0] != 0x30) {
    return -1;
  }
  if (der_len_at(p, end, &hdr, &len) != 0) {
    return -1;
  }
  *tbs = p;
  *tbs_len = hdr + len;
  p += hdr + len;
  /* signatureAlgorithm */
  if (p >= end || p[0] != 0x30) {
    return -1;
  }
  if (der_len_at(p, end, &ah, &al) != 0) {
    return -1;
  }
  p += ah + al;
  /* signatureValue BIT STRING */
  if (p >= end || p[0] != 0x03) {
    return -1;
  }
  if (der_len_at(p, end, &sh, &sl) != 0 || sl < 2) {
    return -1;
  }
  p += sh;
  if (p[0] != 0x00) {
    return -1; /* unused bits must be 0 for RSA */
  }
  *sig = p + 1;
  *sig_len = sl - 1;
  return 0;
}

/* Verify RSA-PKCS1-v1_5 SHA-256 signature over [msg,msg_len]. */
static int rsa_pkcs1_sha256_verify(const uint8_t *mod, int mod_len, uint32_t exp,
                                   const uint8_t *sig, int sig_len,
                                   const uint8_t *msg, int msg_len) {
  static const uint8_t digest_info_prefix[19] = {
      0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01,
      0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20};
  uint8_t em[256];
  uint8_t hash[32];
  uint8_t sigbuf[256];
  uint64_t sb[32];
  uint64_t nb[32];
  uint64_t cb[32];
  int nlimbs;
  int i;
  int di_off;
  if (mod_len < 64 || mod_len > 256 || sig_len < 1 || sig_len > mod_len) {
    return -1;
  }
  nlimbs = (mod_len * 8 + 63) / 64;
  if (nlimbs > 32) {
    return -1;
  }
  mem_set(sigbuf, 0, (size_t)mod_len);
  mem_cpy(sigbuf + (mod_len - sig_len), sig, (size_t)sig_len);
  lim_from_be(sb, nlimbs, sigbuf, mod_len);
  lim_from_be(nb, nlimbs, mod, mod_len);
  lim_modexp(cb, sb, exp, nb, nlimbs);
  lim_to_be(cb, nlimbs, em, mod_len);
  if (em[0] != 0x00 || em[1] != 0x01) {
    return -1;
  }
  i = 2;
  while (i < mod_len && em[i] == 0xff) {
    i++;
  }
  if (i < 10 || i >= mod_len || em[i] != 0x00) {
    return -1;
  }
  i++;
  di_off = i;
  if (mod_len - di_off != 51) {
    return -1;
  }
  if (!mem_eq(em + di_off, digest_info_prefix, 19)) {
    return -1;
  }
  sha256(msg, (uint32_t)msg_len, hash);
  if (!mem_eq(em + di_off + 19, hash, 32)) {
    return -1;
  }
  return 0;
}

/* Find RSA modulus/exponent in a DER certificate (shallow scan). */
static int parse_rsa_pubkey(const uint8_t *der, int der_len, uint8_t *mod,
                            int *mod_len, uint32_t *exp) {
  int i;
  for (i = 0; i + 8 < der_len; i++) {
    /* BIT STRING wrapping RSAPublicKey SEQUENCE — short, 0x81, or 0x82. */
    if (der[i] != 0x03) {
      continue;
    }
    {
      int bitlen;
      int p;
      if (der[i + 1] == 0x82 && i + 4 < der_len) {
        bitlen = (der[i + 2] << 8) | der[i + 3];
        p = i + 4;
      } else if (der[i + 1] == 0x81 && i + 3 < der_len) {
        bitlen = der[i + 2];
        p = i + 3;
      } else if (der[i + 1] < 0x80) {
        bitlen = der[i + 1];
        p = i + 2;
      } else {
        continue;
      }
      if (p >= der_len) {
        continue;
      }
      if (der[p] != 0x00) {
        continue;
      }
      p++;
      if (p + 2 >= der_len || der[p] != 0x30) {
        continue;
      }
      {
        int sh, sl;
        if (der[p + 1] == 0x82 && p + 3 < der_len) {
          sh = 4;
          sl = (der[p + 2] << 8) | der[p + 3];
        } else if (der[p + 1] == 0x81 && p + 2 < der_len) {
          sh = 3;
          sl = der[p + 2];
        } else if (der[p + 1] < 0x80) {
          sh = 2;
          sl = der[p + 1];
        } else {
          continue;
        }
        (void)sl;
        (void)bitlen;
        p += sh;
      }
      if (p + 2 >= der_len || der[p] != 0x02) {
        continue;
      }
      {
        int mlen;
        int q;
        if (der[p + 1] == 0x82 && p + 3 < der_len) {
          mlen = (der[p + 2] << 8) | der[p + 3];
          q = p + 4;
        } else if (der[p + 1] == 0x81 && p + 2 < der_len) {
          mlen = der[p + 2];
          q = p + 3;
        } else if (der[p + 1] < 0x80) {
          mlen = der[p + 1];
          q = p + 2;
        } else {
          continue;
        }
        if (mlen < 64 || mlen > 257 || q + mlen > der_len) {
          continue;
        }
        if (der[q] == 0x00) {
          q++;
          mlen--;
        }
        if (mlen < 64 || mlen > 256) {
          continue;
        }
        mem_cpy(mod, der + q, (size_t)mlen);
        *mod_len = mlen;
        q += mlen;
        if (q + 2 >= der_len || der[q] != 0x02) {
          continue;
        }
        {
          int elen = der[q + 1];
          int k;
          uint32_t e = 0;
          if (elen < 1 || elen > 4 || q + 2 + elen > der_len) {
            continue;
          }
          for (k = 0; k < elen; k++) {
            e = (e << 8) | der[q + 2 + k];
          }
          *exp = e;
          return 0;
        }
      }
    }
  }
  return -1;
}

static void hs_append(struct OtaTlsCmd *m, const uint8_t *p, uint32_t n) {
  if (m->hs_len + n > (uint32_t)sizeof(m->hs)) {
    return;
  }
  mem_cpy(m->hs + m->hs_len, p, n);
  m->hs_len += n;
}

static void fail(struct OtaTlsCmd *m) {
  m->flags = OTATLS_FAIL;
  m->stage = 99;
}

static void badcert(struct OtaTlsCmd *m) {
  m->flags = OTATLS_BADCERT;
  m->stage = 98;
}

/* Trust leaf fingerprint (ADR-0154) or CA chain (ADR-0168).
 * One cert: SHA-256(leaf) must equal trust.
 * Two+ certs: some non-leaf cert's SHA-256 equals trust (planted CA);
 * leaf signature must verify under that CA's RSA key. */
static int trust_cert_list(struct OtaTlsCmd *m, const uint8_t *list,
                           uint32_t list_len, int entry_ext) {
  const uint8_t *cp = list;
  const uint8_t *cend = list + list_len;
  const uint8_t *leaf = 0;
  uint32_t leaf_len = 0;
  const uint8_t *ca = 0;
  uint32_t ca_len = 0;
  uint8_t leaf_hash[32];
  uint8_t ca_mod[256];
  int ca_mod_len = 0;
  uint32_t ca_exp = 0;
  const uint8_t *tbs = 0;
  const uint8_t *sig = 0;
  int tbs_len = 0, sig_len = 0;
  int ncerts = 0;

  while (cp + 3 <= cend) {
    uint32_t cl = be24(cp);
    uint32_t ext_len;
    uint8_t h[32];
    if (cp + 3 + cl > cend || cl < 64) {
      fail(m);
      return -1;
    }
    if (ncerts == 0) {
      leaf = cp + 3;
      leaf_len = cl;
    }
    sha256(cp + 3, cl, h);
    if (ncerts > 0 && mem_eq(h, m->trust, 32)) {
      ca = cp + 3;
      ca_len = cl;
    }
    if (ncerts == 0) {
      mem_cpy(leaf_hash, h, 32);
    }
    cp += 3 + cl;
    if (entry_ext) {
      if (cp + 2 > cend) {
        fail(m);
        return -1;
      }
      ext_len = be16(cp);
      cp += 2;
      if (cp + ext_len > cend) {
        fail(m);
        return -1;
      }
      cp += ext_len;
    }
    ncerts++;
  }
  if (ncerts < 1 || !leaf) {
    fail(m);
    return -1;
  }
  if (ncerts == 1) {
    if (!mem_eq(leaf_hash, m->trust, 32)) {
      badcert(m);
      return -1;
    }
    if (parse_rsa_pubkey(leaf, (int)leaf_len, m->rsa_n, (int *)&m->rsa_n_len,
                         &m->rsa_e) != 0) {
      fail(m);
      return -1;
    }
    return 0;
  }
  /* Chain: planted CA must appear after the leaf. */
  if (!ca) {
    badcert(m);
    return -1;
  }
  if (parse_rsa_pubkey(ca, (int)ca_len, ca_mod, &ca_mod_len, &ca_exp) != 0) {
    fail(m);
    return -1;
  }
  if (x509_tbs_sig(leaf, (int)leaf_len, &tbs, &tbs_len, &sig, &sig_len) != 0) {
    badcert(m);
    return -1;
  }
  if (rsa_pkcs1_sha256_verify(ca_mod, ca_mod_len, ca_exp, sig, sig_len, tbs,
                              tbs_len) != 0) {
    badcert(m);
    return -1;
  }
  if (parse_rsa_pubkey(leaf, (int)leaf_len, m->rsa_n, (int *)&m->rsa_n_len,
                       &m->rsa_e) != 0) {
    fail(m);
    return -1;
  }
  return 0;
}

static int build_client_hello(struct OtaTlsCmd *m) {
  uint8_t *t = m->tx;
  uint32_t body;
  fill_rand(m->client_random, 32);
  /* TLS record */
  t[0] = 0x16;
  t[1] = 0x03;
  t[2] = 0x01;
  /* handshake ClientHello */
  t[5] = 0x01;
  t[9] = 0x03;
  t[10] = 0x03; /* TLS 1.2 */
  mem_cpy(t + 11, m->client_random, 32);
  t[43] = 0; /* session id len */
  put_be16(t + 44, 2);
  put_be16(t + 46, 0x002f); /* TLS_RSA_WITH_AES_128_CBC_SHA */
  t[48] = 1;
  t[49] = 0; /* null compression */
  put_be16(t + 50, 8);
  put_be16(t + 52, 0x000d); /* signature_algorithms */
  put_be16(t + 54, 4);
  put_be16(t + 56, 2);
  put_be16(t + 58, 0x0401); /* rsa_pkcs1_sha256 */
  body = 51; /* version..extensions */
  put_be24(t + 6, body);
  put_be16(t + 3, body + 4);
  m->tx_len = body + 9;
  hs_append(m, t + 5, body + 4);
  return 0;
}

static const uint8_t *skip_hs(const uint8_t *p, const uint8_t *end, uint8_t want,
                              const uint8_t **body, uint32_t *blen) {
  while (p + 4 <= end) {
    uint8_t typ = p[0];
    uint32_t n = be24(p + 1);
    if (p + 4 + n > end) {
      return 0;
    }
    if (typ == want) {
      *body = p + 4;
      *blen = n;
      return p + 4 + n;
    }
    p += 4 + n;
  }
  return 0;
}

static int process_server_flight(struct OtaTlsCmd *m) {
  const uint8_t *p = m->rx;
  const uint8_t *end = m->rx + m->rx_len;
  const uint8_t *sh = 0;
  const uint8_t *cert = 0;
  const uint8_t *done = 0;
  uint32_t sh_len = 0, cert_len = 0, done_len = 0;
  uint32_t base = m->hs_len;
  uint32_t acc_len = 0;

  /* Collect handshake record payloads into hs[] after ClientHello
   * (no large IRQ stack buffer; room for a leaf+CA chain). */
  while (p + 5 <= end) {
    uint8_t typ = p[0];
    uint32_t n = be16(p + 3);
    if (p + 5 + n > end) {
      return 1; /* need more */
    }
    if (typ == 22) {
      if (base + acc_len + n > (uint32_t)sizeof(m->hs)) {
        fail(m);
        return -1;
      }
      mem_cpy(m->hs + base + acc_len, p + 5, n);
      acc_len += n;
    } else if (typ == 21) {
      fail(m);
      return -1;
    }
    p += 5 + n;
  }
  if (acc_len < 4) {
    return 1;
  }
  end = m->hs + base + acc_len;
  p = m->hs + base;
  p = skip_hs(p, end, 2, &sh, &sh_len);
  if (!p || sh_len < 34) {
    return 1;
  }
  p = skip_hs(p, end, 11, &cert, &cert_len);
  if (!p) {
    return 1;
  }
  p = skip_hs(p, end, 14, &done, &done_len);
  if (!p) {
    return 1;
  }
  /* Transcript already lives at hs[base..]; commit length. */
  m->hs_len = base + acc_len;
  mem_cpy(m->server_random, sh + 2, 32);
  /* Certificate list — leaf fingerprint or CA chain (ADR-0168). */
  {
    uint32_t list_len;
    if (cert_len < 6) {
      fail(m);
      return -1;
    }
    list_len = be24(cert);
    if (list_len + 3 > cert_len) {
      fail(m);
      return -1;
    }
    if (trust_cert_list(m, cert + 3, list_len, 0) != 0) {
      return -1;
    }
  }
  return 0;
}

static int build_client_finish_flight(struct OtaTlsCmd *m) {
  uint8_t seed[64];
  uint8_t verify[12];
  uint8_t hs_hash[32];
  uint8_t finished_msg[16];
  uint8_t *t = m->tx;
  uint32_t off = 0;
  int klen = (int)m->rsa_n_len;
  uint8_t enc[256];
  uint8_t mac_secret[20];
  uint8_t enc_key[16];
  uint8_t iv_implicit[16];
  uint8_t rk[176];
  uint8_t plain[64];
  uint8_t mac[20];
  uint8_t iv[16];
  uint8_t cbc[64];
  int plain_len;
  int i;

  m->premaster[0] = 0x03;
  m->premaster[1] = 0x03;
  fill_rand(m->premaster + 2, 46);
  if (rsa_pkcs1_encrypt(m->rsa_n, klen, m->rsa_e, m->premaster, 48, enc) != 0) {
    fail(m);
    return -1;
  }
  mem_cpy(seed, m->client_random, 32);
  mem_cpy(seed + 32, m->server_random, 32);
  tls_prf(m->premaster, 48, "master secret", seed, 64, m->master, 48);
  mem_cpy(seed, m->server_random, 32);
  mem_cpy(seed + 32, m->client_random, 32);
  tls_prf(m->master, 48, "key expansion", seed, 64, m->key_block, 104);
  /* client_write_MAC_key[20] server_write_MAC_key[20]
   * client_write_key[16] server_write_key[16]
   * client_write_IV[16] server_write_IV[16] */
  mem_cpy(mac_secret, m->key_block, 20);
  mem_cpy(enc_key, m->key_block + 40, 16);
  mem_cpy(iv_implicit, m->key_block + 72, 16);
  (void)iv_implicit;

  /* ClientKeyExchange record */
  t[off] = 0x16;
  t[off + 1] = 0x03;
  t[off + 2] = 0x03;
  put_be16(t + off + 3, (uint32_t)(2 + klen + 4));
  t[off + 5] = 0x10;
  put_be24(t + off + 6, (uint32_t)(2 + klen));
  put_be16(t + off + 9, (uint32_t)klen);
  mem_cpy(t + off + 11, enc, (size_t)klen);
  hs_append(m, t + off + 5, (uint32_t)(4 + 2 + klen));
  off += 11 + (uint32_t)klen;

  /* ChangeCipherSpec */
  t[off] = 0x14;
  t[off + 1] = 0x03;
  t[off + 2] = 0x03;
  put_be16(t + off + 3, 1);
  t[off + 5] = 0x01;
  off += 6;

  /* Finished (encrypted) */
  sha256(m->hs, m->hs_len, hs_hash);
  tls_prf(m->master, 48, "client finished", hs_hash, 32, verify, 12);
  finished_msg[0] = 0x14;
  put_be24(finished_msg + 1, 12);
  mem_cpy(finished_msg + 4, verify, 12);
  hs_append(m, finished_msg, 16);

  aes_key_expand(enc_key, rk);
  /* TLS 1.2 CBC: explicit IV + ciphertext */
  fill_rand(iv, 16);
  /* plaintext = finished_msg || MAC || padding */
  mem_cpy(plain, finished_msg, 16);
  {
    uint8_t seqmac[8 + 5 + 16];
    put_be64(seqmac, m->seq_c);
    seqmac[8] = 0x16;
    seqmac[9] = 0x03;
    seqmac[10] = 0x03;
    put_be16(seqmac + 11, 16);
    mem_cpy(seqmac + 13, finished_msg, 16);
    hmac_sha1(mac_secret, 20, seqmac, 8 + 5 + 16, mac);
  }
  mem_cpy(plain + 16, mac, 20);
  plain_len = 16 + 20;
  {
    int pad = 16 - ((plain_len + 1) % 16);
    if (pad == 16) {
      pad = 15; /* still need length byte; standard: pad_len = 15 for align */
    }
    /* Want (plain_len + 1 + pad) % 16 == 0 where last byte is pad length */
    pad = 15 - (plain_len % 16);
    for (i = 0; i <= pad; i++) {
      plain[plain_len + i] = (uint8_t)pad;
    }
    plain_len += pad + 1;
  }
  mem_cpy(cbc, iv, 16);
  {
    uint8_t prev[16];
    mem_cpy(prev, iv, 16);
    for (i = 0; i < plain_len; i += 16) {
      uint8_t block[16];
      int j;
      for (j = 0; j < 16; j++) {
        block[j] = (uint8_t)(plain[i + j] ^ prev[j]);
      }
      aes_encrypt_block(rk, block, cbc + 16 + i);
      mem_cpy(prev, cbc + 16 + i, 16);
    }
  }
  t[off] = 0x16;
  t[off + 1] = 0x03;
  t[off + 2] = 0x03;
  put_be16(t + off + 3, (uint32_t)(16 + plain_len));
  mem_cpy(t + off + 5, cbc, (size_t)(16 + plain_len));
  off += 5 + 16 + (uint32_t)plain_len;
  m->seq_c++;
  m->tx_len = off;
  return 0;
}

static int decrypt_record(struct OtaTlsCmd *m, const uint8_t *rec, uint32_t rec_len,
                          uint8_t *out, uint32_t *out_len, uint8_t expect_type) {
  uint8_t mac_secret[20];
  uint8_t enc_key[16];
  uint8_t rk[176];
  uint8_t prev[16];
  uint8_t plain[2048];
  uint32_t ct_len;
  uint32_t i;
  uint8_t pad;
  uint32_t content_len;
  uint8_t mac[20];
  uint8_t seqmac[8 + 5 + 2048];
  if (rec_len < 5 + 16 + 16) {
    return 1;
  }
  if (rec[0] != expect_type && !(expect_type == 0 && (rec[0] == 0x16 || rec[0] == 0x17))) {
    /* allow either hs or app when expect_type==0 */
  }
  if (expect_type != 0 && rec[0] != expect_type) {
    return -1;
  }
  ct_len = be16(rec + 3);
  if (5 + ct_len > rec_len || ct_len < 32) {
    return 1;
  }
  mem_cpy(mac_secret, m->key_block + 20, 20); /* server MAC */
  mem_cpy(enc_key, m->key_block + 56, 16);    /* server key */
  aes_key_expand(enc_key, rk);
  mem_cpy(prev, rec + 5, 16);
  for (i = 0; i + 16 < ct_len; i += 16) {
    uint8_t block[16];
    uint8_t dec[16];
    int j;
    mem_cpy(block, rec + 5 + 16 + i, 16);
    aes_decrypt_block(rk, block, dec);
    for (j = 0; j < 16; j++) {
      plain[i + j] = (uint8_t)(dec[j] ^ prev[j]);
    }
    mem_cpy(prev, block, 16);
  }
  {
    uint32_t plen = ct_len - 16;
    pad = plain[plen - 1];
    if (pad + 1 > plen) {
      return -1;
    }
    content_len = plen - 1 - pad - 20;
    if (content_len > plen) {
      return -1;
    }
    put_be64(seqmac, m->seq_s);
    seqmac[8] = rec[0];
    seqmac[9] = 0x03;
    seqmac[10] = 0x03;
    put_be16(seqmac + 11, (uint32_t)content_len);
    mem_cpy(seqmac + 13, plain, content_len);
    hmac_sha1(mac_secret, 20, seqmac, 8 + 5 + content_len, mac);
    if (!mem_eq(mac, plain + content_len, 20)) {
      return -1;
    }
    mem_cpy(out, plain, content_len);
    *out_len = content_len;
    m->seq_s++;
  }
  return 0;
}

static int process_server_finish_and_app(struct OtaTlsCmd *m) {
  const uint8_t *p = m->rx;
  const uint8_t *end = m->rx + m->rx_len;
  while (p + 5 <= end) {
    uint8_t typ = p[0];
    uint32_t n = be16(p + 3);
    if (p + 5 + n > end) {
      /* Keep unparsed tail. */
      uint32_t keep = (uint32_t)(end - p);
      if (p != m->rx) {
        mem_cpy(m->rx, p, keep);
        m->rx_len = keep;
      }
      return 1;
    }
    if (m->stage == 2 && typ == 0x14) {
      p += 5 + n;
      continue;
    }
    if (m->stage == 2 && typ == 0x16) {
      uint8_t plain[64];
      uint32_t plen = 0;
      int r = decrypt_record(m, p, 5 + n, plain, &plen, 0x16);
      if (r == 1) {
        return 1;
      }
      if (r < 0 || plen < 16 || plain[0] != 0x14) {
        fail(m);
        return -1;
      }
      p += 5 + n;
      m->stage = 3;
      continue;
    }
    if (m->stage == 3 && typ == 0x17) {
      uint8_t plain[OTATLS_PLAIN_MAX];
      uint32_t plen = 0;
      int r = decrypt_record(m, p, 5 + n, plain, &plen, 0x17);
      if (r == 1) {
        return 1;
      }
      if (r < 0 || plen < 1 || plen > OTATLS_PLAIN_MAX) {
        fail(m);
        return -1;
      }
      mem_cpy(m->plain, plain, plen);
      m->plain_len = plen;
      m->rx_len = 0;
      m->flags = OTATLS_DONE;
      m->stage = 4;
      return 0;
    }
    /* Unexpected record. */
    fail(m);
    return -1;
  }
  m->rx_len = 0;
  return 1;
}

#define memcpy mem_cpy
#define memset mem_set
#include "curve25519-donna.inc"

#include "otatls13.inc"

#if defined(__APPLE__)
#include <stdio.h>
#endif

/* Clang -O2 may emit library `memset` for large stack clears inside
 * inlined c25519 even with -fno-builtin; the #define above only
 * rewrites source tokens. Export a real symbol so the lean kernel
 * link does not pull a host libc. */
#undef memset
__attribute__((weak)) void *memset(void *p, int v, size_t n) {
  mem_set(p, (uint8_t)v, n);
  return p;
}

void otatls_guest_tick(void) {
  struct OtaTlsCmd *m = &otatls_guest_cmd;
  if (m->magic != OTATLS_MAGIC) {
    return;
  }
  if ((m->flags & OTATLS_GO) == 0) {
    return;
  }
  m->flags = (uint64_t)(m->flags & ~(OTATLS_GO));

  if (m->stage >= 10) {
    otatls_tick_13(m);
    return;
  }

  if (m->stage == 0) {
    m->hs_len = 0;
    m->seq_c = 0;
    m->seq_s = 0;
    m->tx_len = 0;
    m->plain_len = 0;
    build_client_hello(m);
    m->stage = 1;
    m->flags = OTATLS_HAVE_TX | OTATLS_WANT_RX;
    return;
  }
  if (m->stage == 1) {
    if (m->rx_len > 0 && m->rx[0] != 0x16 && m->rx[0] != 0x15) {
      /* Not a TLS handshake/alert record — plain TCP anti-vacuity. */
      fail(m);
      return;
    }
    int r = process_server_flight(m);
    if (r > 0) {
      m->flags = OTATLS_WANT_RX;
      if (m->rx_len > 0) {
        m->flags |= OTATLS_GO;
      }
      return;
    }
    if (r < 0) {
      return;
    }
    m->rx_len = 0;
    /* Defer CKE/Finished to the next tick so the RSA verify modexp
     * and the premaster encrypt do not nest on the same IRQ stack. */
    m->stage = 5;
    m->flags = OTATLS_GO;
    return;
  }
  if (m->stage == 5) {
    if (build_client_finish_flight(m) != 0) {
      return;
    }
    m->stage = 2;
    m->flags = OTATLS_HAVE_TX | OTATLS_WANT_RX;
    return;
  }
  if (m->stage == 2 || m->stage == 3) {
    int r = process_server_finish_and_app(m);
    if (r > 0) {
      m->flags = OTATLS_WANT_RX;
      if (m->rx_len > 0) {
        m->flags |= OTATLS_GO;
      }
      return;
    }
    if (r < 0) {
      return;
    }
    return;
  }
}



#if defined(__APPLE__)
#if defined(__APPLE__)
#include <stdio.h>
#include <stdlib.h>
uint8_t otatls_gcm_tag_calc[16];
uint8_t otatls_gcm_tag_recv[16];
#endif

int otatls_gcm_roundtrip(void) {
  uint8_t key[16] = {1, 0};
  uint8_t nonce[12] = {0};
  uint8_t pt[32] = "hello tls gcm test";
  uint8_t ct[64], out[64];
  size_t clen, olen;
  uint8_t aad[5] = {0x17, 0x03, 0x03, 0x00, 0x20};
  if (aes_gcm_encrypt(key, nonce, aad, 5, pt, 18, ct, &clen) != 0) return 1;
  if (aes_gcm_decrypt(key, nonce, aad, 5, ct, clen, out, &olen) != 0) return 2;
  if (olen != 18 || !mem_eq(out, pt, 18)) return 3;
  return 0;
}

int otatls_kdf_key_s(const uint8_t *hs, uint32_t hs_len, const uint8_t *shared,
                     uint8_t key_s[16]) {
  uint8_t zeros[32], early[32], empty_hash[32], derived[32], hs_secret[32], ssec[32];
  mem_set(zeros, 0, 32);
  sha256(zeros, 0, empty_hash);
  hkdf_extract(zeros, 32, zeros, 32, early);
  tls13_expand_label(early, "derived", empty_hash, 32, derived, 32);
  hkdf_extract(derived, 32, shared, 32, hs_secret);
  tls13_derive_secret(hs_secret, "s hs traffic", hs, hs_len, ssec);
  tls13_expand_label(ssec, "key", zeros, 0, key_s, 16);
  return 0;
}

int otatls_kdf_key_c(const uint8_t *hs, uint32_t hs_len, const uint8_t *shared,
                     uint8_t key_c[16]) {
  uint8_t zeros[32], early[32], empty_hash[32], derived[32], hs_secret[32], csec[32];
  mem_set(zeros, 0, 32);
  sha256(zeros, 0, empty_hash);
  hkdf_extract(zeros, 32, zeros, 32, early);
  tls13_expand_label(early, "derived", empty_hash, 32, derived, 32);
  hkdf_extract(derived, 32, shared, 32, hs_secret);
  tls13_derive_secret(hs_secret, "c hs traffic", hs, hs_len, csec);
  tls13_expand_label(csec, "key", zeros, 0, key_c, 16);
  return 0;
}

int otatls_kdf_check(const uint8_t *hs, uint32_t hs_len, const uint8_t *shared,
                     const uint8_t *expect_key_s) {
  uint8_t zeros[32], early[32], empty_hash[32], derived[32], hs_secret[32];
  uint8_t ssec[32], key_s[16];
  mem_set(zeros, 0, 32);
  sha256(zeros, 0, empty_hash);
  hkdf_extract(zeros, 32, zeros, 32, early);
  tls13_expand_label(early, "derived", empty_hash, 32, derived, 32);
  hkdf_extract(derived, 32, shared, 32, hs_secret);
  tls13_derive_secret(hs_secret, "s hs traffic", hs, hs_len, ssec);
  tls13_expand_label(ssec, "key", zeros, 0, key_s, 16);
  return mem_eq(key_s, expect_key_s, 16) ? 0 : 1;
}

extern uint8_t otatls_gcm_tag_calc[16];
extern uint8_t otatls_gcm_tag_recv[16];

int otatls_try_open_record(const uint8_t *key, const uint8_t *iv, const uint8_t *rec,
                           uint32_t rec_len, uint8_t *out, size_t *out_len) {
  struct OtaTlsCmd m;
  mem_set(&m, 0, sizeof(m));
  mem_cpy(m.gcm_key_s, key, 16);
  mem_cpy(m.gcm_iv_s, iv, 12);
  m.seq_s = 0;
  return tls13_aead_open(&m, 1, rec, rec_len, out, out_len);
}

#if defined(__APPLE__)
int otatls_try_open_record_c(const uint8_t *key, const uint8_t *iv,
                             const uint8_t *rec, uint32_t rec_len, uint8_t *out,
                             size_t *out_len) {
  struct OtaTlsCmd m;
  mem_set(&m, 0, sizeof(m));
  mem_cpy(m.gcm_key_c, key, 16);
  mem_cpy(m.gcm_iv_c, iv, 12);
  m.seq_c = 0;
  return tls13_aead_open(&m, 0, rec, rec_len, out, out_len);
}
#endif

int otatls_open_all_records(const uint8_t *rx, uint32_t rx_len,
                            const uint8_t *key, const uint8_t *iv,
                            int *fail_at) {
  struct OtaTlsCmd m;
  uint32_t p = 0;
  int idx = 0;
  mem_set(&m, 0, sizeof(m));
  mem_cpy(m.gcm_key_s, key, 16);
  mem_cpy(m.gcm_iv_s, iv, 12);
  m.seq_s = 0;
  while (p + 5 <= rx_len) {
    uint32_t n = be16(rx + p + 3);
    if (rx[p] == 0x17) {
      uint8_t plain[2048];
      size_t ol = 0;
      int r = tls13_aead_open(&m, 1, rx + p, 5 + n, plain, &ol);
      if (r < 0) {
        if (fail_at) *fail_at = idx;
        return -1;
      }
      idx++;
    }
    p += 5 + n;
  }
  if (fail_at) *fail_at = -1;
  return idx;
}

int otatls_dump_flight_plain(const uint8_t *rx, uint32_t rx_len,
                             const uint8_t *key, const uint8_t *iv,
                             uint8_t *dec, uint32_t *dec_len) {
  struct OtaTlsCmd m;
  uint32_t p = 0;
  uint32_t out_len = 0;
  mem_set(&m, 0, sizeof(m));
  mem_cpy(m.gcm_key_s, key, 16);
  mem_cpy(m.gcm_iv_s, iv, 12);
  m.seq_s = 0;
  while (p + 5 <= rx_len) {
    uint32_t n = be16(rx + p + 3);
    if (rx[p] == 0x17) {
      uint8_t plain[2048];
      size_t ol = 0;
      uint32_t inner_len;
      if (tls13_aead_open(&m, 1, rx + p, 5 + n, plain, &ol) < 0) return -1;
      if (ol < 5) return -2;
      if (plain[0] == 0x16) {
        inner_len = be16(plain + 3);
        if (5 + inner_len > ol || out_len + inner_len > *dec_len) return -3;
        mem_cpy(dec + out_len, plain + 5, inner_len);
        out_len += inner_len;
      } else if (plain[0] >= 2 && plain[0] <= 24) {
        inner_len = 4 + be24(plain + 1);
        if (inner_len > ol || inner_len < 4 || out_len + inner_len > *dec_len) return -3;
        mem_cpy(dec + out_len, plain, inner_len);
        out_len += inner_len;
      } else {
        return -2;
      }
    }
    p += 5 + n;
  }
  *dec_len = out_len;
  return 0;
}

int otatls_gcm_selftest(void) {
  uint8_t key[16] = {0};
  uint8_t nonce[12] = {0};
  uint8_t ct[16] = {0x58, 0xe2, 0xfc, 0xce, 0xfa, 0x7e, 0x30, 0x61,
                    0x36, 0x7f, 0x1d, 0x57, 0xa4, 0xe7, 0x45, 0x5a};
  uint8_t e0_want[16] = {0x58, 0xe2, 0xfc, 0xce, 0xfa, 0x7e, 0x30, 0x61,
                         0x36, 0x7f, 0x1d, 0x57, 0xa4, 0xe7, 0x45, 0x5a};
  uint8_t pt[16];
  uint8_t rk[176], j0[16], e0[16];
  size_t plen = 0;
  int r;
  aes_key_expand(key, rk);
  mem_cpy(j0, nonce, 12);
  j0[12] = 0;
  j0[13] = 0;
  j0[14] = 0;
  j0[15] = 1;
  aes_encrypt_block(rk, j0, e0);
  if (!mem_eq(e0, e0_want, 16)) {
    return 2;
  }
  r = aes_gcm_decrypt(key, nonce, 0, 0, ct, 16, pt, &plen);
  if (r != 0) {
    return 3;
  }
  return plen == 0 ? 0 : 1;
}

int otatls_x25519_selftest(void) {
  uint8_t scalar[32] = {0x77, 0x07, 0x6d, 0x0a, 0x73, 0x19, 0x64, 0x52,
                        0xc8, 0x10, 0xf3, 0x2b, 0x80, 0x90, 0x79, 0xe5,
                        0x62, 0x00, 0xa0, 0x56, 0x55, 0x79, 0x14, 0x33,
                        0x64, 0x27, 0xb8, 0x17, 0xae, 0x9a, 0x2e, 0x0a};
  uint8_t point[32] = {9};
  uint8_t out[32];
  uint8_t want[32] = {0x4a, 0x5d, 0x9d, 0x5b, 0xa8, 0x3c, 0xa5, 0xce,
                      0x95, 0x6e, 0x8c, 0xb0, 0x27, 0x55, 0x28, 0x0e,
                      0x10, 0x82, 0x94, 0xeb, 0x84, 0xb5, 0x9c, 0xfc,
                      0x66, 0xba, 0x0d, 0xca, 0xe3, 0xbe, 0x5c, 0x09};
  x25519_scalarmult(out, scalar, point);
  if (!mem_eq(out, want, 32)) {
    return 1;
  }
  return 0;
}

void otatls_x25519_shared(const uint8_t priv[32], const uint8_t peer[32],
                          uint8_t out[32]) {
  c25519_donna(out, priv, peer);
}

void otatls_aes_test(void) {
  uint8_t key[16] = {0};
  uint8_t pt[16] = {0};
  uint8_t ct[16];
  uint8_t out[16];
  uint8_t j0[16];
  uint8_t e0[16];
  uint8_t rk[176];
  uint8_t want[16] = {0x66,0xe9,0x4b,0xd4,0xef,0x8a,0x2c,0x3b,
                      0x88,0x4c,0xfa,0x59,0xca,0x34,0x2b,0x2e};
  aes_key_expand(key, rk);
  aes_encrypt_block(rk, pt, ct);
  aes_decrypt_block(rk, ct, out);
  mem_set(j0, 0, 16);
  j0[15] = 1;
  aes_encrypt_block(rk, j0, e0);
}
#endif

#if defined(__APPLE__)
int otatls_parse_rsa_test(const uint8_t *der, int der_len) {
  uint8_t mod[256];
  int mod_len = 0;
  uint32_t exp = 0;
  return parse_rsa_pubkey(der, der_len, mod, &mod_len, &exp);
}

int otatls_pss_verify_test(const uint8_t *der, int der_len, const uint8_t *sig,
                           int sig_len, const uint8_t *msg, int msg_len) {
  uint8_t mod[256];
  int mod_len = 0;
  uint32_t exp = 0;
  if (parse_rsa_pubkey(der, der_len, mod, &mod_len, &exp) != 0) {
    return -2;
  }
  return rsa_pss_sha256_verify(mod, mod_len, exp, sig, sig_len, msg, msg_len);
}
#endif
