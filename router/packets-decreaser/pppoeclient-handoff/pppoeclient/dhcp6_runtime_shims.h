/* SPDX-License-Identifier: Apache-2.0
 * Digi FDio 26.06-release dhcp headers lack Hi-Jiajun DHCPv6 runtime
 * snapshot types used by pppoeclient detail/API. Define them locally so
 * the plugin builds against stock Digi vpp-dev. At runtime the code still
 * resolves symbols via vlib_get_plugin_symbol and no-ops when Digi's
 * dhcp_plugin.so does not export the getters.
 *
 * Struct layouts match Hi-Jiajun/vpp feat/pr-pppoeclient.
 */
#ifndef included_pppoeclient_dhcp6_runtime_shims_h
#define included_pppoeclient_dhcp6_runtime_shims_h

#include <vnet/ip/ip6_packet.h>

#ifndef DHCP6_MAX_LEARNED_DNS_SERVERS
#define DHCP6_MAX_LEARNED_DNS_SERVERS 2
#endif

#ifndef DHCP6_IA_NA_CLIENT_RUNTIME_T_DEFINED
#define DHCP6_IA_NA_CLIENT_RUNTIME_T_DEFINED
typedef struct
{
  u8 enabled;
  u8 rebinding;
  u32 server_index;
  u32 T1;
  u32 T2;
  u32 address_count;
  u32 t1_remaining;
  u32 t2_remaining;
  u8 first_address_present;
  ip6_address_t first_address;
  u32 first_address_preferred_lt;
  u32 first_address_valid_lt;
  u8 dns_server_count;
  ip6_address_t dns_servers[DHCP6_MAX_LEARNED_DNS_SERVERS];
} dhcp6_ia_na_client_runtime_t;
#endif

#ifndef DHCP6_PD_CLIENT_RUNTIME_T_DEFINED
#define DHCP6_PD_CLIENT_RUNTIME_T_DEFINED
typedef struct
{
  u8 enabled;
  u8 rebinding;
  u32 server_index;
  u32 T1;
  u32 T2;
  u32 prefix_count;
  u32 t1_remaining;
  u32 t2_remaining;
  char prefix_group[65];
} dhcp6_pd_client_runtime_t;

typedef struct
{
  u8 present;
  ip6_address_t prefix;
  u8 prefix_length;
  u32 preferred_lt;
  u32 valid_lt;
  u32 valid_remaining;
} dhcp6_pd_active_prefix_runtime_t;

typedef struct
{
  u8 present;
  u32 consumer_count;
  u32 sw_if_index;
  ip6_address_t address;
  u8 prefix_length;
} dhcp6_pd_consumer_runtime_t;
#endif

#endif /* included_pppoeclient_dhcp6_runtime_shims_h */
