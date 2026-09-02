/* TLS 1.3 (ADR-0169) — included from otatls.c only. */

static void put_be32(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)(v >> 24);
  p[1] = (uint8_t)(v >> 16);
  p[2] = (uint8_t)(v >> 8);
  p[3] = (uint8_t)v;
}

static void hkdf_extract(const uint8_t *salt, size_t salt_len, const uint8_t *ikm,
                         size_t ikm_len, uint8_t prk[32]) {
  uint8_t zsalt[32];
  if (salt_len == 0) {
    mem_set(zsalt, 0, 32);
    salt = zsalt;
    salt_len = 32;
  }
  hmac_sha256(salt, salt_len, ikm, ikm_len, prk);
}

static void hkdf_expand(const uint8_t prk[32], const uint8_t *info, size_t info_len,
                        uint8_t *out, size_t out_len) {
  uint8_t t[32];
  uint8_t block[288];
  size_t produced = 0;
  size_t tlen = 0;
  uint8_t ctr = 1;
  while (produced < out_len) {
    size_t pos = 0;
    if (tlen > 0) {
      mem_cpy(block, t, tlen);
      pos = tlen;
    }
    if (info_len > 0) {
      mem_cpy(block + pos, info, info_len);
      pos += info_len;
    }
    block[pos++] = ctr++;
    hmac_sha256(prk, 32, block, pos, t);
    tlen = 32;
    {
      size_t take = out_len - produced;
      if (take > 32) take = 32;
      mem_cpy(out + produced, t, take);
      produced += take;
    }
  }
}

static void tls13_expand_label(const uint8_t secret[32], const char *label,
                               const uint8_t *ctx, size_t ctx_len,
                               uint8_t *out, size_t out_len) {
  uint8_t info[256];
  size_t lab_len = 0;
  size_t pos = 0;
  while (label[lab_len]) lab_len++;
  info[pos++] = (uint8_t)(out_len >> 8);
  info[pos++] = (uint8_t)out_len;
  info[pos++] = (uint8_t)(6 + lab_len);
  mem_cpy(info + pos, "tls13 ", 6);
  pos += 6;
  mem_cpy(info + pos, label, lab_len);
  pos += lab_len;
  info[pos++] = (uint8_t)ctx_len;
  if (ctx_len > 0) {
    mem_cpy(info + pos, ctx, ctx_len);
    pos += ctx_len;
  }
  hkdf_expand(secret, info, pos, out, out_len);
}

static void tls13_derive_secret(const uint8_t secret[32], const char *label,
                                const uint8_t *transcript, size_t tlen,
                                uint8_t out[32]) {
  uint8_t th[32];
  sha256(transcript, tlen, th);
  tls13_expand_label(secret, label, th, 32, out, 32);
}

static void x25519_scalarmult(uint8_t out[32], const uint8_t scalar[32],
                              const uint8_t point[32]) {
  c25519_donna(out, scalar, point);
}

/* AES-GCM (128-bit key, 12-byte IV) */
static uint64_t be64r(const uint8_t *p) {
  uint64_t v = 0;
  int i;
  for (i = 0; i < 8; i++) {
    v = (v << 8) | p[i];
  }
  return v;
}

static void gcm_mult(uint8_t x[16], const uint8_t y[16]) {
  uint64_t a_hi, a_lo, b_hi, b_lo, c_hi = 0, c_lo = 0;
  int i;
  a_hi = be64r(x);
  a_lo = be64r(x + 8);
  b_hi = be64r(y);
  b_lo = be64r(y + 8);
  for (i = 0; i < 128; i++) {
    int bit;
    if (i < 64) {
      bit = (int)((a_hi >> (63 - i)) & 1ULL);
    } else {
      bit = (int)((a_lo >> (127 - i)) & 1ULL);
    }
    if (bit) {
      c_hi ^= b_hi;
      c_lo ^= b_lo;
    }
    {
      int lsb = (int)(b_lo & 1ULL);
      b_lo = (b_hi << 63) | (b_lo >> 1);
      b_hi >>= 1;
      if (lsb) {
        b_hi ^= 0xe100000000000000ULL;
      }
    }
  }
  put_be64(x, c_hi);
  put_be64(x + 8, c_lo);
}
static void gcm_ghash(uint8_t h[16],const uint8_t *aad,size_t aad_len,
                      const uint8_t *ct,size_t ct_len,uint8_t out[16]) {
  uint8_t buf[16]; size_t i; mem_set(out,0,16);
  for(i=0;i+16<=aad_len;i+=16) { int j; for(j=0;j<16;j++) out[j]^=aad[i+j]; gcm_mult(out,h); }
  if(aad_len%16) {
    mem_set(buf,0,16); mem_cpy(buf,aad+i,aad_len-i);
    { int j; for(j=0;j<16;j++) out[j]^=buf[j]; } gcm_mult(out,h);
  }
  for(i=0;i+16<=ct_len;i+=16) { int j; for(j=0;j<16;j++) out[j]^=ct[i+j]; gcm_mult(out,h); }
  if(ct_len%16) {
    mem_set(buf,0,16); mem_cpy(buf,ct+i,ct_len-i);
    { int j; for(j=0;j<16;j++) out[j]^=buf[j]; } gcm_mult(out,h);
  }
  { uint8_t lenb[16]; mem_set(lenb,0,16);
    put_be64(lenb,(uint64_t)aad_len*8ULL); put_be64(lenb+8,(uint64_t)ct_len*8ULL);
    { int j; for(j=0;j<16;j++) out[j]^=lenb[j]; } gcm_mult(out,h);
  }
}
static void gcm_inc32(uint8_t v[16]) {
  uint32_t x = ((uint32_t)v[12] << 24) | ((uint32_t)v[13] << 16) |
               ((uint32_t)v[14] << 8) | (uint32_t)v[15];
  x++;
  v[12] = (uint8_t)(x >> 24);
  v[13] = (uint8_t)(x >> 16);
  v[14] = (uint8_t)(x >> 8);
  v[15] = (uint8_t)x;
}
#if defined(__APPLE__)
extern uint8_t otatls_gcm_tag_calc[16];
extern uint8_t otatls_gcm_tag_recv[16];
#endif
static int aes_gcm_decrypt(const uint8_t key[16], const uint8_t nonce[12],
                           const uint8_t *aad, size_t aad_len,
                           const uint8_t *in, size_t in_len,
                           uint8_t *out, size_t *out_len) {
  uint8_t rk[176], h[16], j0[16], ctr[16], tag[16], tag_calc[16], plain[2048], ks[16];
  uint32_t i, j; size_t clen; int k;
  if (in_len < 16 || in_len > 2048) return -1;
  clen = in_len - 16;
  mem_cpy(tag, in + clen, 16);
  aes_key_expand(key, rk);
  mem_set(h, 0, 16);
  aes_encrypt_block(rk, h, h);
  mem_cpy(j0, nonce, 12);
  j0[12] = 0; j0[13] = 0; j0[14] = 0; j0[15] = 1;
  mem_cpy(ctr, j0, 16);
  for (i = 0; i < clen; i += 16) {
    gcm_inc32(ctr);
    aes_encrypt_block(rk, ctr, ks);
    for (j = 0; j < 16 && i + j < clen; j++) plain[i + j] = (uint8_t)(in[i + j] ^ ks[j]);
  }
  mem_set(tag_calc, 0, 16);
  gcm_ghash(h, aad, aad_len, in, clen, tag_calc);
  mem_cpy(ctr, j0, 16);
  aes_encrypt_block(rk, ctr, ctr);
  for (k = 0; k < 16; k++) tag_calc[k] ^= ctr[k];
  if (!mem_eq(tag_calc, tag, 16)) {
#if defined(__APPLE__)
    mem_cpy(otatls_gcm_tag_calc, tag_calc, 16);
    mem_cpy(otatls_gcm_tag_recv, tag, 16);
#endif
    return -1;
  }
  mem_cpy(out, plain, clen);
  *out_len = clen;
  return 0;
}
static int aes_gcm_encrypt(const uint8_t key[16], const uint8_t nonce[12],
                           const uint8_t *aad, size_t aad_len,
                           const uint8_t *in, size_t in_len,
                           uint8_t *out, size_t *out_len) {
  uint8_t rk[176], h[16], j0[16], ctr[16], tag_calc[16], ks[16];
  uint32_t i, j; int k;
  if (in_len > 1400) return -1;
  aes_key_expand(key, rk);
  mem_set(h, 0, 16);
  aes_encrypt_block(rk, h, h);
  mem_cpy(j0, nonce, 12);
  j0[12] = 0; j0[13] = 0; j0[14] = 0; j0[15] = 1;
  mem_cpy(ctr, j0, 16);
  for (i = 0; i < in_len; i += 16) {
    gcm_inc32(ctr);
    aes_encrypt_block(rk, ctr, ks);
    for (j = 0; j < 16 && i + j < in_len; j++) out[i + j] = (uint8_t)(in[i + j] ^ ks[j]);
  }
  mem_set(tag_calc, 0, 16);
  gcm_ghash(h, aad, aad_len, out, in_len, tag_calc);
  mem_cpy(ctr, j0, 16);
  aes_encrypt_block(rk, ctr, ctr);
  for (k = 0; k < 16; k++) out[in_len + k] = (uint8_t)(ctr[k] ^ tag_calc[k]);
  *out_len = in_len + 16;
  return 0;
}

/* RSA-PSS-SHA256 verify (TLS 1.3 CertificateVerify) */
static void mgf1_sha256(const uint8_t *seed, size_t seed_len, uint8_t *out, size_t out_len) {
  uint8_t cnt[4], buf[32+4], h[32];
  size_t produced = 0;
  uint32_t c = 0;
  while (produced < out_len) {
    put_be32(cnt, c++);
    mem_cpy(buf, seed, seed_len);
    mem_cpy(buf + seed_len, cnt, 4);
    sha256(buf, seed_len + 4, h);
    { size_t take = out_len - produced; if (take > 32) take = 32;
      mem_cpy(out + produced, h, take); produced += take; }
  }
}
static int rsa_pss_sha256_verify(const uint8_t *mod, int mod_len, uint32_t exp,
                                 const uint8_t *sig, int sig_len,
                                 const uint8_t *msg, int msg_len) {
  uint8_t em[256], sigbuf[256], mhash[32], db[256], dbmask[256], hprime[32];
  uint64_t sb[32], nb[32], cb[32];
  int nlimbs, em_len, i, db_len, salt_len;
  const uint8_t *h, *salt;
  if (mod_len < 64 || mod_len > 256 || sig_len < 1 || sig_len > mod_len) return -1;
  nlimbs = (mod_len * 8 + 63) / 64;
  mem_set(sigbuf, 0, (size_t)mod_len);
  mem_cpy(sigbuf + (mod_len - sig_len), sig, (size_t)sig_len);
  lim_from_be(sb, nlimbs, sigbuf, mod_len);
  lim_from_be(nb, nlimbs, mod, mod_len);
  lim_modexp(cb, sb, exp, nb, nlimbs);
  lim_to_be(cb, nlimbs, em, mod_len);
  em_len = mod_len;
  if (em[em_len - 1] != 0xbc) return -1;
  sha256(msg, (size_t)msg_len, mhash);
  db_len = em_len - 32 - 1;
  salt_len = 32;
  if (db_len < salt_len + 2) return -1;
  h = em + db_len;
  mgf1_sha256(h, 32, dbmask, (size_t)db_len);
  for (i = 0; i < db_len; i++) db[i] = (uint8_t)(em[i] ^ dbmask[i]);
  db[0] &= 0x7f;
  for (i = 0; i < db_len - salt_len - 1; i++) if (db[i] != 0) return -1;
  if (db[db_len - salt_len - 1] != 0x01) return -1;
  salt = db + db_len - salt_len;
  { uint8_t mprime[8 + 32 + 32];
    mem_set(mprime, 0, 8);
    mem_cpy(mprime + 8, mhash, 32);
    mem_cpy(mprime + 40, salt, 32);
    sha256(mprime, 72, hprime);
    if (!mem_eq(hprime, h, 32)) return -1;
  }
  return 0;
}

static void tls13_make_nonce(const uint8_t iv[12], uint64_t seq, uint8_t nonce[12]) {
  int i;
  mem_cpy(nonce, iv, 12);
  for (i = 0; i < 8; i++) nonce[11 - i] ^= (uint8_t)(seq >> (8 * i));
}

static int tls13_aead_open(struct OtaTlsCmd *m, int from_server,
                           const uint8_t *rec, uint32_t rec_len,
                           uint8_t *out, size_t *out_len) {
  const uint8_t *key = from_server ? m->gcm_key_s : m->gcm_key_c;
  const uint8_t *iv = from_server ? m->gcm_iv_s : m->gcm_iv_c;
  uint64_t *seqp = from_server ? &m->seq_s : &m->seq_c;
  uint8_t nonce[12];
  uint32_t ct_len;
  if (rec_len < 5 + 16) return 1;
  ct_len = be16(rec + 3);
  if (5 + ct_len > rec_len || ct_len < 16) return 1;
  tls13_make_nonce(iv, *seqp, nonce);
  if (aes_gcm_decrypt(key, nonce, rec, 5, rec + 5, ct_len, out, out_len) != 0)
    return -1;
  (*seqp)++;
  return 0;
}

static int tls13_aead_seal(struct OtaTlsCmd *m, int from_client,
                           uint8_t typ, const uint8_t *plain, size_t plen,
                           uint8_t *rec, size_t *rec_len) {
  const uint8_t *key = from_client ? m->gcm_key_c : m->gcm_key_s;
  const uint8_t *iv = from_client ? m->gcm_iv_c : m->gcm_iv_s;
  uint64_t *seqp = from_client ? &m->seq_c : &m->seq_s;
  uint8_t inner[256], enc[256], nonce[12];
  size_t elen, ilen;
  if (plen + 17 > 240) return -1;
  mem_cpy(inner, plain, plen);
  ilen = plen;
  inner[ilen++] = typ;
  while (ilen % 16 != 0) {
    inner[ilen++] = 0;
  }
  tls13_make_nonce(iv, *seqp, nonce);
  rec[0] = 0x17;
  rec[1] = 0x03;
  rec[2] = 0x03;
  put_be16(rec + 3, (uint32_t)(ilen + 16));
  if (aes_gcm_encrypt(key, nonce, rec, 5, inner, ilen, enc, &elen) != 0) return -1;
  mem_cpy(rec + 5, enc, elen);
  *rec_len = 5 + elen;
  (*seqp)++;
  return 0;
}

static int tls13_inner_content(const uint8_t *plain, size_t plen, uint8_t want,
                               const uint8_t **content, size_t *content_len) {
  size_t end = plen;
  while (end > 0 && plain[end - 1] == 0) {
    end--;
  }
  if (end == 0 || plain[end - 1] != want) {
    return -1;
  }
  *content = plain;
  *content_len = end - 1;
  return 0;
}

static void tls13_derive_hs_keys(struct OtaTlsCmd *m, const uint8_t *shared, size_t slen) {
  uint8_t zeros[32], early[32], empty_hash[32], derived[32], hs_secret[32];
  uint8_t csec[32], ssec[32];
  mem_set(zeros, 0, 32);
  sha256(zeros, 0, empty_hash);
  hkdf_extract(zeros, 32, zeros, 32, early);
  tls13_expand_label(early, "derived", empty_hash, 32, derived, 32);
  hkdf_extract(derived, 32, shared, slen, hs_secret);
  tls13_derive_secret(hs_secret, "c hs traffic", m->hs, m->hs_len, csec);
  tls13_derive_secret(hs_secret, "s hs traffic", m->hs, m->hs_len, ssec);
  mem_cpy(m->key_block, csec, 32);
  mem_cpy(m->key_block + 32, ssec, 32);
  tls13_expand_label(csec, "key", empty_hash, 0, m->gcm_key_c, 16);
  tls13_expand_label(csec, "iv", empty_hash, 0, m->gcm_iv_c, 12);
  tls13_expand_label(ssec, "key", empty_hash, 0, m->gcm_key_s, 16);
  tls13_expand_label(ssec, "iv", empty_hash, 0, m->gcm_iv_s, 12);
  mem_cpy(m->master, hs_secret, 32);
  m->seq_c = 0;
  m->seq_s = 0;
}

static void tls13_derive_app_keys(struct OtaTlsCmd *m) {
  uint8_t empty_hash[32], derived[32], master[32], csec[32], ssec[32];
  uint8_t zeros[32];
  mem_set(zeros, 0, 32);
  sha256(zeros, 0, empty_hash);
  tls13_expand_label(m->master, "derived", empty_hash, 32, derived, 32);
  hkdf_extract(derived, 32, zeros, 32, master);
  tls13_derive_secret(master, "c ap traffic", m->hs, m->hs_len, csec);
  tls13_derive_secret(master, "s ap traffic", m->hs, m->hs_len, ssec);
  tls13_expand_label(csec, "key", zeros, 0, m->gcm_key_c, 16);
  tls13_expand_label(csec, "iv", zeros, 0, m->gcm_iv_c, 12);
  tls13_expand_label(ssec, "key", zeros, 0, m->gcm_key_s, 16);
  tls13_expand_label(ssec, "iv", zeros, 0, m->gcm_iv_s, 12);
  mem_cpy(m->master, master, 32);
  m->seq_c = 0;
  m->seq_s = 0;
}

static int tls13_verify_finished(struct OtaTlsCmd *m, int from_server,
                                 const uint8_t *verify, size_t vlen) {
  const uint8_t *traffic = from_server ? m->key_block + 32 : m->key_block;
  uint8_t fkey[32], th[32], expect[32], empty[32];
  mem_set(empty, 0, 32);
  tls13_expand_label(traffic, "finished", empty, 0, fkey, 32);
  sha256(m->hs, m->hs_len, th);
  hmac_sha256(fkey, 32, th, 32, expect);
  if (vlen != 32 || !mem_eq(verify, expect, 32)) return -1;
  return 0;
}

static int build_client_hello_13(struct OtaTlsCmd *m) {
  static const uint8_t basepoint[32] = {9};
  uint8_t *t = m->tx;
  uint8_t pub[32];
  uint32_t body, ext_len, off = 11;
  fill_rand(m->client_random, 32);
  fill_rand(m->xs_priv, 32);
  m->xs_priv[0] &= 248;
  m->xs_priv[31] = (uint8_t)((m->xs_priv[31] & 127) | 64);
  x25519_scalarmult(pub, m->xs_priv, basepoint);
  t[0] = 0x16; t[1] = 0x03; t[2] = 0x01;
  t[5] = 0x01;
  t[9] = 0x03; t[10] = 0x03;
  mem_cpy(t + off, m->client_random, 32); off += 32;
  t[off++] = 0; /* session id */
  put_be16(t + off, 2); off += 2;
  put_be16(t + off, 0x1301); off += 2; /* TLS_AES_128_GCM_SHA256 only */
  t[off++] = 1; t[off++] = 0;
  /* extensions total placeholder */
  { uint32_t ext_start = off; off += 2;
    /* supported_versions */
    put_be16(t + off, 0x002b); off += 2; put_be16(t + off, 3); off += 2;
    t[off++] = 2; put_be16(t + off, 0x0304); off += 2;
    /* supported_groups (required by TLS 1.3 peers) */
    put_be16(t + off, 0x000a); off += 2; put_be16(t + off, 4); off += 2;
    put_be16(t + off, 2); off += 2;
    put_be16(t + off, 0x001d); off += 2;
    /* signature_algorithms */
    put_be16(t + off, 0x000d); off += 2; put_be16(t + off, 4); off += 2;
    put_be16(t + off, 2); off += 2; put_be16(t + off, 0x0804); off += 2;
    /* key_share */
    put_be16(t + off, 0x0033); off += 2; put_be16(t + off, 38); off += 2;
    put_be16(t + off, 36); off += 2;
    put_be16(t + off, 0x001d); off += 2; put_be16(t + off, 32); off += 2;
    mem_cpy(t + off, pub, 32); off += 32;
    ext_len = off - ext_start - 2;
    put_be16(t + ext_start, ext_len);
  }
  body = off - 9;
  put_be24(t + 6, body);
  put_be16(t + 3, body + 4);
  m->tx_len = off;
  hs_append(m, t + 5, body + 4);
  /* Save ClientHello transcript length for idempotent server-flight reparses. */
  put_be32(m->iv_seed + 8, m->hs_len);
  m->iv_seed[0] = 0;
  return 0;
}

static int tls13_parse_ext(const uint8_t *p, uint32_t n, uint16_t want,
                           const uint8_t **val, uint32_t *vlen) {
  uint32_t i = 0;
  while (i + 4 <= n) {
    uint16_t typ = (uint16_t)be16(p + i);
    uint16_t len = (uint16_t)be16(p + i + 2);
    if (i + 4 + len > n) return -1;
    if (typ == want) {
      *val = p + i + 4;
      *vlen = len;
      return 0;
    }
    i += 4 + len;
  }
  return -1;
}

static uint32_t be32_u(const uint8_t *p) {
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static int process_server_flight_13(struct OtaTlsCmd *m) {
  const uint8_t *p = m->rx;
  const uint8_t *end = m->rx + m->rx_len;
  uint8_t dec[3072];
  uint32_t dec_len = 0;
  int keys = 0;
  int stop = 0;
  const uint8_t *app_at = 0;
  uint32_t ch_len = be32_u(m->iv_seed + 8);

  /* Idempotent reparse: restore transcript to ClientHello; leave rx alone
   * until EE+Cert+CV+Finished is complete. */
  if (ch_len > 0 && ch_len <= (uint32_t)sizeof(m->hs)) {
    m->hs_len = ch_len;
  }
  m->iv_seed[0] = 0;
  m->seq_s = 0;

  while (p + 5 <= end && !stop) {
    uint8_t typ = p[0];
    uint32_t n = be16(p + 3);
    if (p + 5 + n > end) {
      return 1;
    }
    if (typ == 0x16 && !keys) {
      const uint8_t *hs = p + 5;
      uint32_t hsn = n;
      uint8_t srv_pub[32];
      uint8_t shared[32];
      if (hsn < 4 || hs[0] != 2) {
        fail(m);
        return -1;
      }
      {
        uint32_t sh_len = be24(hs + 1);
        const uint8_t *sh = hs + 4;
        uint32_t sid_len, off;
        const uint8_t *ext;
        uint32_t elen;
        if (4 + sh_len > hsn) {
          return 1;
        }
        if (m->hs_len + 4 + sh_len > (uint32_t)sizeof(m->hs)) {
          fail(m);
          return -1;
        }
        hs_append(m, hs, 4 + sh_len);
        mem_cpy(m->server_random, sh + 2, 32);
        sid_len = sh[34];
        off = 40 + sid_len;
        if (off + 2 > sh_len) {
          fail(m);
          return -1;
        }
        if (tls13_parse_ext(sh + off, sh_len - off, 0x0033, &ext, &elen) != 0) {
          fail(m);
          return -1;
        }
        if (elen < 36 || be16(ext + 2) != 32) {
          fail(m);
          return -1;
        }
        mem_cpy(srv_pub, ext + 4, 32);
        x25519_scalarmult(shared, m->xs_priv, srv_pub);
        tls13_derive_hs_keys(m, shared, 32);
        m->iv_seed[0] = 1;
        keys = 1;
        m->seq_s = 0;
      }
    } else if (typ == 0x17 && keys) {
      uint8_t plain[2048];
      size_t ol = 0;
      if (tls13_aead_open(m, 1, p, 5 + n, plain, &ol) < 0) {
        if (dec_len > 0) {
          app_at = p;
          stop = 1;
          break;
        }
        fail(m);
        return -1;
      }
      if (ol < 1) {
        fail(m);
        return -1;
      }
      {
        size_t ct_len = ol;
        while (ct_len > 0 && plain[ct_len - 1] == 0) {
          ct_len--;
        }
        if (ct_len < 1) {
          fail(m);
          return -1;
        }
        if (plain[ct_len - 1] == 0x17) {
          if (dec_len > 0) {
            app_at = p;
            stop = 1;
            break;
          }
          fail(m);
          return -1;
        }
        if (plain[ct_len - 1] == 0x16 || (plain[0] >= 2 && plain[0] <= 24)) {
          size_t body = (plain[ct_len - 1] == 0x16) ? (ct_len - 1) : ct_len;
          if (plain[ct_len - 1] != 0x16) {
            uint32_t inner_len = 4 + be24(plain + 1);
            if (inner_len > ol || inner_len < 4) {
              fail(m);
              return -1;
            }
            body = inner_len;
          }
          if (dec_len + body > sizeof(dec)) {
            fail(m);
            return -1;
          }
          mem_cpy(dec + dec_len, plain, body);
          dec_len += (uint32_t)body;
        } else if (dec_len > 0) {
          app_at = p;
          stop = 1;
          break;
        } else {
          fail(m);
          return -1;
        }
      }
    } else if (typ == 0x14) {
      /* middlebox CCS */
    } else if (typ == 0x15) {
      fail(m);
      return -1;
    } else if (!keys) {
      return 1;
    } else if (typ != 0x17) {
      fail(m);
      return -1;
    }
    if (!stop) {
      p += 5 + n;
    }
  }
  if (!keys || dec_len < 20) {
    return 1;
  }
  {
    const uint8_t *q = dec;
    const uint8_t *qend = dec + dec_len;
    const uint8_t *cert = 0, *cverify = 0, *fin = 0;
    uint32_t cert_len = 0, cv_len = 0, fin_len = 0;
    while (q + 4 <= qend) {
      uint8_t htyp = q[0];
      uint32_t hn = be24(q + 1);
      if (q + 4 + hn > qend) {
        break;
      }
      if (htyp == 8) {
        hs_append(m, q, 4 + hn);
      } else if (htyp == 11) {
        cert = q + 4;
        cert_len = hn;
        hs_append(m, q, 4 + hn);
      } else if (htyp == 15) {
        cverify = q + 4;
        cv_len = hn;
      } else if (htyp == 20) {
        fin = q + 4;
        fin_len = hn;
      }
      q += 4 + hn;
    }
    if (!cert || !cverify || !fin || fin_len < 32) {
      return 1;
    }
    {
      uint32_t list_len;
      uint32_t ctx_len;
      const uint8_t *list;
      if (cert_len < 4) {
        fail(m);
        return -1;
      }
      ctx_len = cert[0];
      if (1 + ctx_len + 3 > cert_len) {
        fail(m);
        return -1;
      }
      list = cert + 1 + ctx_len;
      list_len = be24(list);
      if (1 + ctx_len + 3 + list_len > cert_len) {
        fail(m);
        return -1;
      }
      if (trust_cert_list(m, list + 3, list_len, 1) != 0) {
        return -1;
      }
    }
    if (cv_len < 4 || be16(cverify) != 0x0804) {
      badcert(m);
      return -1;
    }
    {
      uint32_t sig_len = be16(cverify + 2);
      const uint8_t *sig = cverify + 4;
      uint8_t cvmsg[130];
      int i;
      for (i = 0; i < 64; i++) {
        cvmsg[i] = 0x20;
      }
      mem_cpy(cvmsg + 64, "TLS 1.3, server CertificateVerify", 33);
      cvmsg[64 + 33] = 0;
      sha256(m->hs, m->hs_len, cvmsg + 64 + 33 + 1);
      if (rsa_pss_sha256_verify(m->rsa_n, (int)m->rsa_n_len, m->rsa_e, sig,
                                (int)sig_len, cvmsg, 130) != 0) {
        badcert(m);
        return -1;
      }
    }
    hs_append(m, cverify - 4, cv_len + 4);
    if (tls13_verify_finished(m, 1, fin, fin_len) != 0) {
      fail(m);
      return -1;
    }
    hs_append(m, fin - 4, fin_len + 4);
  }
  if (app_at && app_at < end) {
    uint32_t keep = (uint32_t)(end - app_at);
    mem_cpy(m->rx, app_at, keep);
    m->rx_len = keep;
  } else if (p < end) {
    uint32_t keep = (uint32_t)(end - p);
    mem_cpy(m->rx, p, keep);
    m->rx_len = keep;
  } else {
    m->rx_len = 0;
  }
  return 0;
}

static int build_client_finish_13(struct OtaTlsCmd *m) {
  uint8_t fin_plain[64];
  uint8_t rec[256];
  size_t rlen;
  uint8_t fkey[32], th[32], verify[32], empty[32];
  mem_set(empty, 0, 32);
  fin_plain[0] = 0x14;
  put_be24(fin_plain + 1, 32);
  tls13_expand_label(m->key_block, "finished", empty, 0, fkey, 32);
  sha256(m->hs, m->hs_len, th);
  hmac_sha256(fkey, 32, th, 32, verify);
  mem_cpy(fin_plain + 4, verify, 32);
  if (tls13_aead_seal(m, 1, 0x16, fin_plain, 36, rec, &rlen) != 0) {
    fail(m);
    return -1;
  }
  mem_cpy(m->tx, rec, rlen);
  m->tx_len = (uint32_t)rlen;
  tls13_derive_app_keys(m);
  /* RFC 8446: sequence numbers reset when traffic keys change. */
  m->seq_c = 0;
  m->seq_s = 0;
  hs_append(m, fin_plain, 36);
  return 0;
}

static int process_app_13(struct OtaTlsCmd *m) {
  const uint8_t *p = m->rx;
  const uint8_t *end = m->rx + m->rx_len;
  while (p + 5 <= end) {
    uint8_t typ = p[0];
    uint32_t n = be16(p + 3);
    if (p + 5 + n > end) {
      uint32_t keep = (uint32_t)(end - p);
      if (p != m->rx) { mem_cpy(m->rx, p, keep); m->rx_len = keep; }
      return 1;
    }
    if (typ == 0x17) {
      uint8_t plain[OTATLS_PLAIN_MAX + 32];
      size_t plen = 0;
      const uint8_t *content = 0;
      size_t content_len = 0;
      int r = tls13_aead_open(m, 1, p, 5 + n, plain, &plen);
      if (r < 0) {
        p += 5 + n;
        continue;
      }
      if (r == 1) return 1;
      if (plen < 2) {
        p += 5 + n;
        continue;
      }
      if (tls13_inner_content(plain, plen, 0x17, &content, &content_len) != 0) {
        p += 5 + n;
        continue;
      }
      if (content_len < 4 || content[0] != 'O' || content[1] != 'T' ||
          content[2] != 'A' || content[3] != '1') {
        p += 5 + n;
        continue;
      }
      if (content_len > OTATLS_PLAIN_MAX) { fail(m); return -1; }
      mem_cpy(m->plain, content, content_len);
      m->plain_len = (uint32_t)content_len;
      m->rx_len = 0;
      m->flags = OTATLS_DONE;
      m->stage = 14;
      return 0;
    }
    p += 5 + n;
  }
  {
    uint32_t keep = (uint32_t)(end - p);
    if (keep > 0 && p != m->rx) {
      mem_cpy(m->rx, p, keep);
      m->rx_len = keep;
    } else if (keep == 0) {
      m->rx_len = 0;
    }
  }
  return 1;
}


static void otatls_tick_13(struct OtaTlsCmd *m) {
  if (m->stage == 10) {
    m->hs_len = 0;
    m->seq_c = 0;
    m->seq_s = 0;
    m->tx_len = 0;
    m->plain_len = 0;
    build_client_hello_13(m);
    m->stage = 11;
    m->flags = OTATLS_HAVE_TX | OTATLS_WANT_RX;
    return;
  }
  if (m->stage == 11) {
    if (m->rx_len > 0 && m->rx[0] != 0x16 && m->rx[0] != 0x17 && m->rx[0] != 0x15) {
      fail(m);
      return;
    }
    {
      int r = process_server_flight_13(m);
      if (r > 0) {
        m->flags = OTATLS_WANT_RX;
        if (m->rx_len > 0) {
          m->flags |= OTATLS_GO;
        }
        return;
      }
      if (r < 0) return;
    }
    m->stage = 15;
    m->flags = OTATLS_GO;
    return;
  }
  if (m->stage == 15) {
    if (build_client_finish_13(m) != 0) return;
    m->stage = 12;
    m->flags = OTATLS_HAVE_TX | OTATLS_WANT_RX;
    if (m->rx_len > 0) {
      m->flags |= OTATLS_GO;
    }
    return;
  }
  if (m->stage == 12) {
    int r = process_app_13(m);
    if (r > 0) {
      m->flags = OTATLS_WANT_RX;
      if (m->rx_len > 0) {
        m->flags |= OTATLS_GO;
      }
      return;
    }
    if (r < 0) return;
    return;
  }
}

#if defined(__APPLE__)
int otatls_finished_verify_test(const uint8_t traffic[32], const uint8_t *hs,
                                uint32_t hs_len, const uint8_t *verify,
                                uint32_t vlen) {
  struct OtaTlsCmd m;
  mem_set(&m, 0, sizeof(m));
  mem_cpy(m.key_block + 32, traffic, 32);
  return tls13_verify_finished(&m, 1, verify, vlen);
}

void otatls_shared_derive(const uint8_t priv[32], const uint8_t pub[32],
                          uint8_t out[32]) {
  x25519_scalarmult(out, priv, pub);
}
#endif
