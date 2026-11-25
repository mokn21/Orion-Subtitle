// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Orion Subtitles builds chiaki-ng for local-network play only. PSN internet play
// (remote/holepunch.c) and its certificate recovery helpers (aia*.c) pull in
// curl, libevent, json-c and miniupnpc, so they are replaced by these stubs.
// The session code only reaches them when ChiakiConnectInfo.holepunch_session
// is non-NULL, which the app never sets.

#include <netinet/in.h>

#include <chiaki/common.h>
#include <chiaki/log.h>
#include <chiaki/remote/holepunch.h>

#include <string.h>

ChiakiErrorCode chiaki_aia_init(void) { return CHIAKI_ERR_SUCCESS; }
void chiaki_aia_fini(void) {}

CHIAKI_EXPORT ChiakiErrorCode chiaki_holepunch_list_devices(const char *token,
                                                            ChiakiHolepunchConsoleType type, ChiakiHolepunchDeviceInfo **devices,
                                                            size_t *count, ChiakiLog *log)
{
    (void)token;
    (void)type;
    (void)log;
    if (devices)
        *devices = NULL;
    if (count)
        *count = 0;
    return CHIAKI_ERR_UNKNOWN;
}

CHIAKI_EXPORT void chiaki_holepunch_free_device_list(ChiakiHolepunchDeviceInfo **devices) { (void)devices; }

CHIAKI_EXPORT ChiakiHolepunchRegistInfo chiaki_get_regist_info(ChiakiHolepunchSession session)
{
    (void)session;
    ChiakiHolepunchRegistInfo info;
    memset(&info, 0, sizeof(info));
    return info;
}

CHIAKI_EXPORT void chiaki_get_ps_selected_addr(ChiakiHolepunchSession session, char *ps_ip)
{
    (void)session;
    if (ps_ip)
        ps_ip[0] = '\0';
}

CHIAKI_EXPORT uint16_t chiaki_get_ps_ctrl_port(ChiakiHolepunchSession session)
{
    (void)session;
    return 0;
}

CHIAKI_EXPORT chiaki_socket_t *chiaki_get_holepunch_sock(ChiakiHolepunchSession session, ChiakiHolepunchPortType type)
{
    (void)session;
    (void)type;
    return NULL;
}

CHIAKI_EXPORT bool chiaki_holepunch_session_get_stun_allocation(ChiakiHolepunchSession session,
                                                                int32_t *allocation_increment, bool *random_allocation)
{
    (void)session;
    (void)allocation_increment;
    (void)random_allocation;
    return false;
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_holepunch_generate_client_device_uid(char *out, size_t *out_size)
{
    (void)out;
    (void)out_size;
    return CHIAKI_ERR_UNKNOWN;
}

CHIAKI_EXPORT ChiakiHolepunchSession chiaki_holepunch_session_init(const char *token, ChiakiLog *log)
{
    (void)token;
    CHIAKI_LOGE(log, "PSN remote play is not supported in this build");
    return NULL;
}

CHIAKI_EXPORT void chiaki_holepunch_session_force_port_guessing(ChiakiHolepunchSession session, bool enabled)
{
    (void)session;
    (void)enabled;
}
CHIAKI_EXPORT void chiaki_holepunch_session_set_ws_fqdn_override(ChiakiHolepunchSession session, const char *fqdn)
{
    (void)session;
    (void)fqdn;
}
CHIAKI_EXPORT void chiaki_holepunch_session_set_port_guessing_ports(ChiakiHolepunchSession session, int count)
{
    (void)session;
    (void)count;
}
CHIAKI_EXPORT void chiaki_holepunch_session_set_port_guessing_socks(ChiakiHolepunchSession session, int count)
{
    (void)session;
    (void)count;
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_holepunch_session_create(ChiakiHolepunchSession session)
{
    (void)session;
    return CHIAKI_ERR_UNKNOWN;
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_holepunch_session_start(ChiakiHolepunchSession session,
                                                             const uint8_t *console_uid, ChiakiHolepunchConsoleType console_type)
{
    (void)session;
    (void)console_uid;
    (void)console_type;
    return CHIAKI_ERR_UNKNOWN;
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_holepunch_upnp_discover(ChiakiHolepunchSession session)
{
    (void)session;
    return CHIAKI_ERR_UNKNOWN;
}
CHIAKI_EXPORT ChiakiErrorCode holepunch_session_create_offer(ChiakiHolepunchSession session)
{
    (void)session;
    return CHIAKI_ERR_UNKNOWN;
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_holepunch_session_punch_hole(ChiakiHolepunchSession session, ChiakiHolepunchPortType port_type)
{
    (void)session;
    (void)port_type;
    return CHIAKI_ERR_UNKNOWN;
}

CHIAKI_EXPORT void chiaki_holepunch_main_thread_cancel(ChiakiHolepunchSession session, bool stop_thread)
{
    (void)session;
    (void)stop_thread;
}
CHIAKI_EXPORT void chiaki_holepunch_session_fini(ChiakiHolepunchSession session) { (void)session; }
