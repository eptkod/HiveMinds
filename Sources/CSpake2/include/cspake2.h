// BoringSSL's SPAKE2 (curve25519), the same one Android uses for 6-digit wireless ADB pairing.
// The code is already linked into the binary through swift-nio-ssl's vendored BoringSSL (prefix CNIOBoringSSL_);
// these declarations let Swift call it.
#include <stddef.h>
#include <stdint.h>
typedef struct spake2_ctx_st SPAKE2_CTX;
enum spake2_role_t { spake2_role_alice, spake2_role_bob };
SPAKE2_CTX *CNIOBoringSSL_SPAKE2_CTX_new(enum spake2_role_t my_role, const uint8_t *my_name, size_t my_name_len,
                                         const uint8_t *their_name, size_t their_name_len);
void CNIOBoringSSL_SPAKE2_CTX_free(SPAKE2_CTX *ctx);
int CNIOBoringSSL_SPAKE2_generate_msg(SPAKE2_CTX *ctx, uint8_t *out, size_t *out_len, size_t max_out_len,
                                      const uint8_t *password, size_t password_len);
int CNIOBoringSSL_SPAKE2_process_msg(SPAKE2_CTX *ctx, uint8_t *out_key, size_t *out_key_len, size_t max_out_key_len,
                                     const uint8_t *their_msg, size_t their_msg_len);
