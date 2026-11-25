// Shim so lib/src/aia.h compiles without curl. The local-only iOS build never
// uses curl; aia.h only needs the CURL type name for prototypes.
#ifndef CK_CURL_SHIM_H
#define CK_CURL_SHIM_H
typedef void CURL;
#endif
