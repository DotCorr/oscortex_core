/* OTA TLS 1.2 (ADR-0154) + CA chain (ADR-0168) + TLS 1.3 (ADR-0169).
 * Mailbox at kernel_data_start + OTATLS_BOX_OFF (.otatls_cmd).
 * stage 0..5 = TLS 1.2 AES128-SHA; stage >= 10 = TLS 1.3 AES-128-GCM.
 * trust = SHA-256(leaf) or SHA-256(CA). Not plat-tls / FSGS. */
#ifndef OTATLS_H
#define OTATLS_H

#include <stdint.h>

#define OTATLS_MAGIC 0x4F5441544C535631ULL /* OTATLSV1 */
#define OTATLS_BOX_OFF 32960ULL            /* 128 + sizeof(OsMediaGuestCmd) */

#define OTATLS_GO 1ULL
#define OTATLS_DONE 2ULL
#define OTATLS_BADCERT 4ULL
#define OTATLS_FAIL 8ULL
#define OTATLS_HAVE_TX 16ULL
#define OTATLS_WANT_RX 32ULL

#define OTATLS_TRUST_LEN 32
#define OTATLS_RX_MAX 4096
#define OTATLS_TX_MAX 1536
#define OTATLS_PLAIN_MAX 128
#define OTATLS_HS_MAX 4096

struct OtaTlsCmd {
  uint64_t magic;
  uint64_t flags;
  uint8_t trust[OTATLS_TRUST_LEN];
  uint32_t rx_len;
  uint32_t tx_len;
  uint32_t plain_len;
  uint32_t stage;
  uint8_t rx[OTATLS_RX_MAX];
  uint8_t tx[OTATLS_TX_MAX];
  uint8_t plain[OTATLS_PLAIN_MAX];
  /* Session state lives in .data with the mailbox — no C .bss. */
  uint8_t client_random[32];
  uint8_t server_random[32];
  uint8_t master[48];
  uint8_t key_block[128];
  uint8_t hs[OTATLS_HS_MAX];
  uint32_t hs_len;
  uint64_t seq_c;
  uint64_t seq_s;
  uint32_t rsa_n_len;
  uint8_t rsa_n[256];
  uint32_t rsa_e;
  uint8_t premaster[48];
  uint8_t iv_seed[12];
  uint8_t xs_priv[32]; /* X25519 scalar (TLS 1.3) */
  uint8_t gcm_key_c[16];
  uint8_t gcm_key_s[16];
  uint8_t gcm_iv_c[12];
  uint8_t gcm_iv_s[12];
};

void otatls_guest_tick(void);

#endif
