// Extra mbedtls 3.6 options for Orion Subtitles, applied to mbedtls and chiaki alike via
// MBEDTLS_USER_CONFIG_FILE (see CMakeLists.txt) so both see the same structs.

// chiaki's ecdh.c uses the classic mbedtls_ecdh_context layout (grp, d, Q, Qp, z
// as direct fields). mbedtls 3 only keeps that layout when restartable ECP is
// enabled (see MBEDTLS_ECDH_LEGACY_CONTEXT in mbedtls/ecdh.h).
#define MBEDTLS_ECP_RESTARTABLE
