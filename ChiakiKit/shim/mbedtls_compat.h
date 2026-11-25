// Lets chiaki-ng's mbedtls code (written against mbedtls 2.x) build with
// mbedtls 3.6 LTS without patching the vendored sources. Force-included into
// the chiaki target only (see CMakeLists.txt).
#pragma once

// chiaki's ecdh.c reads mbedtls_ecdh_context fields (grp, d, Q, Qp, z) directly.
// mbedtls 3 marks them private; this is mbedtls's supported opt-out.
#define MBEDTLS_ALLOW_PRIVATE_ACCESS

#include <mbedtls/gcm.h>

// mbedtls 3 moved the additional data out of mbedtls_gcm_starts into
// mbedtls_gcm_update_ad. chiaki calls the old 6-argument form.
#define mbedtls_gcm_starts(ctx, mode, iv, iv_len, add, add_len) \
    (mbedtls_gcm_starts((ctx), (mode), (iv), (iv_len)) || mbedtls_gcm_update_ad((ctx), (add), (add_len)))
