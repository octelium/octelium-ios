// Copyright Octelium Labs, LLC. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//	http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// liboctelium is the Octelium tunnel engine embedded by the Octelium client
// applications (i.e. the host). It implements the data plane of a Connection:
// the TUN packet I/O, the WireGuard and the QUICv0 transports to the Cluster
// Gateways, the reconnection of the transports and, whenever the host asks for
// it, the configuration of the OS network interface.
//
// The host owns the control plane. It authenticates to the Cluster, persists
// its state and credentials, maintains the Connect stream of the Cluster API
// and reduces its events into the current Connection state. liboctelium never
// talks to the Cluster API and it never persists anything.
//
// The host passes the complete desired Connection state to liboctelium via
// octelium_tunnel_set_config whenever it changes (e.g. upon receiving the
// initial state or an AddGateway event). liboctelium computes the difference
// from the currently applied state by itself.
//
// Ownership and threading:
//
// All the input pointers are only read during the call and they remain owned
// by the host. All the pointers passed to the callbacks are only valid during
// the callback. The functions can be called from arbitrary threads. The
// callbacks are invoked sequentially from a single liboctelium thread, except
// for protect_socket which is invoked from the thread that creates the socket.
// A request can be completed from within its callback or later from any thread.
// The host must never call octelium_tunnel_free from within a callback. No
// callback is invoked once octelium_tunnel_free returns.
//
// Strings are NUL-terminated UTF-8. A NULL string is equivalent to an empty
// string.

#ifndef OCTELIUM_H
#define OCTELIUM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// A host must consider a different major version as incompatible. The host
// passes the version it is built against to octelium_tunnel_new.
#define OCTELIUM_ABI_VERSION_MAJOR 1
#define OCTELIUM_ABI_VERSION_MINOR 0
#define OCTELIUM_ABI_VERSION ((OCTELIUM_ABI_VERSION_MAJOR << 16) | OCTELIUM_ABI_VERSION_MINOR)

enum {
	OCTELIUM_OK = 0,
	OCTELIUM_ERR_INVALID_ARGUMENT = 1,
	OCTELIUM_ERR_INVALID_STATE = 2,
	OCTELIUM_ERR_NOT_FOUND = 3,
	OCTELIUM_ERR_UNSUPPORTED = 4,
	OCTELIUM_ERR_UNAUTHENTICATED = 5,
	OCTELIUM_ERR_UNAVAILABLE = 6,
	OCTELIUM_ERR_PLATFORM = 7,
	OCTELIUM_ERR_TRANSPORT = 8,
	OCTELIUM_ERR_TIMEOUT = 9,
	OCTELIUM_ERR_INTERNAL = 10,
};

enum {
	// HOST means that the host configures the OS network interface (i.e.
	// VpnService on Android and NEPacketTunnelProvider on iOS) upon receiving
	// an OCTELIUM_REQUEST_APPLY_NETWORK_CONFIG request.
	OCTELIUM_PLATFORM_HOST = 0,
	// NATIVE means that liboctelium creates and configures the OS network
	// interface by itself including its addresses, routes and DNS. It is
	// currently only supported on Linux.
	OCTELIUM_PLATFORM_NATIVE = 1,
};

enum {
	OCTELIUM_LOG_LEVEL_UNSPECIFIED = 0,
	OCTELIUM_LOG_LEVEL_DEBUG = 1,
	OCTELIUM_LOG_LEVEL_INFO = 2,
	OCTELIUM_LOG_LEVEL_WARN = 3,
	OCTELIUM_LOG_LEVEL_ERROR = 4,
};

enum {
	OCTELIUM_TUNNEL_MODE_WIREGUARD = 0,
	OCTELIUM_TUNNEL_MODE_QUICV0 = 1,
};

// The values are identical to those of userv1.ConnectionState.L3Mode.
enum {
	OCTELIUM_L3_MODE_BOTH = 0,
	OCTELIUM_L3_MODE_V4 = 1,
	OCTELIUM_L3_MODE_V6 = 2,
};

enum {
	// DEFAULT resolves the queries of the Cluster domains via the Cluster DNS
	// servers while all the other queries are resolved by the normal resolver
	// of the OS.
	OCTELIUM_DNS_MODE_DEFAULT = 0,
	// DISABLED never configures the DNS.
	OCTELIUM_DNS_MODE_DISABLED = 1,
	// FULL resolves all the queries via the Cluster DNS servers.
	OCTELIUM_DNS_MODE_FULL = 2,
};

enum {
	// IDLE means that no config has been set yet.
	OCTELIUM_STATE_IDLE = 0,
	// CONNECTING means that the tunnel is being established for the first
	// time.
	OCTELIUM_STATE_CONNECTING = 1,
	OCTELIUM_STATE_CONNECTED = 2,
	// RECONNECTING means that the tunnel is established but its transport is
	// currently unavailable (e.g. there is no underlying network or the
	// QUICv0 Gateways are being reconnected).
	OCTELIUM_STATE_RECONNECTING = 3,
	// FAILED means that the tunnel could not be established. The host can
	// retry via octelium_tunnel_set_config.
	OCTELIUM_STATE_FAILED = 4,
};

enum {
	OCTELIUM_EVENT_STATE = 1,
	OCTELIUM_EVENT_LOG = 2,
};

enum {
	OCTELIUM_REQUEST_APPLY_NETWORK_CONFIG = 1,
	OCTELIUM_REQUEST_GET_ACCESS_TOKEN = 2,
};

// octelium_dual_stack_network_t mirrors metav1.DualStackNetwork. Both fields
// are in the CIDR notation and each can be unset.
typedef struct {
	const char *v4;
	const char *v6;
} octelium_dual_stack_network_t;

// octelium_gateway_wireguard_t mirrors userv1.Gateway.WireGuard.
typedef struct {
	// PublicKey is the base64-encoded WireGuard public key of the Gateway.
	const char *public_key;
	int32_t port;
	int32_t keepalive_seconds;
} octelium_gateway_wireguard_t;

// octelium_gateway_quicv0_t mirrors userv1.Gateway.QUICV0.
typedef struct {
	int32_t port;
	int32_t keepalive_seconds;
} octelium_gateway_quicv0_t;

// octelium_gateway_t mirrors userv1.Gateway.
typedef struct {
	const char *id;
	const char *hostname;
	const char *const *addresses;
	size_t addresses_len;
	const char *const *cidrs;
	size_t cidrs_len;
	// WireGuard is NULL if the Gateway has no WireGuard information.
	const octelium_gateway_wireguard_t *wireguard;
	// QUICV0 is NULL if the Gateway has no QUICv0 information.
	const octelium_gateway_quicv0_t *quicv0;
} octelium_gateway_t;

// octelium_connection_state_t mirrors the subset of userv1.ConnectionState
// that is relevant to the tunnel. The host is supposed to copy the fields of
// the current ConnectionState as they are.
typedef struct {
	int32_t mtu;
	uint32_t l3_mode;
	// X25519Key is the WireGuard private key of the Connection. It is
	// required in the WIREGUARD tunnel mode.
	const uint8_t *x25519_key;
	size_t x25519_key_len;
	const octelium_dual_stack_network_t *addresses;
	size_t addresses_len;
	const octelium_gateway_t *gateways;
	size_t gateways_len;
	// DNSServers is the list of the servers of userv1.ConnectionState.dns.
	const char *const *dns_servers;
	size_t dns_servers_len;
	// CIDR is the Cluster CIDR that is routed via the tunnel.
	octelium_dual_stack_network_t cidr;
} octelium_connection_state_t;

// octelium_preferences_t is the set of the local preferences of the
// Connection.
typedef struct {
	uint32_t tunnel_mode;
	uint32_t dns_mode;
	// MTU overrides the MTU of the Connection state. Zero means unset.
	int32_t mtu;
	// KeepaliveSeconds is the persistent keepalive interval of the WireGuard
	// peers. Zero means the keepalive of the Gateway or else 30 seconds.
	int32_t keepalive_seconds;
} octelium_preferences_t;

// octelium_config_t is the complete desired configuration of the tunnel.
typedef struct {
	// Domain is the Cluster domain.
	const char *domain;
	const octelium_connection_state_t *state;
	const octelium_preferences_t *preferences;
} octelium_config_t;

// octelium_network_state_t is the state of the underlying network as
// observed by the host (i.e. ConnectivityManager on Android and NWPathMonitor
// on iOS). liboctelium suspends its transport while no network is available
// and it rebinds its transport whenever the underlying network changes. The
// host can also report the network as unavailable while the device sleeps.
typedef struct {
	uint8_t is_available;
	// ID is an opaque identifier of the current underlying network (e.g. the
	// network handle on Android). A different ID means that the underlying
	// network has changed (e.g. from Wi-Fi to cellular).
	const char *id;
} octelium_network_state_t;

typedef struct {
	// Address is the textual representation of the IP address.
	const char *address;
	uint32_t prefix_len;
} octelium_prefix_t;

typedef struct {
	const char *const *servers;
	size_t servers_len;
	const char *const *search_domains;
	size_t search_domains_len;
	// MatchDomains is the list of the domains whose queries are resolved by
	// the servers while the queries of the other domains are resolved by the
	// normal resolver of the host (i.e. NEDNSSettings.matchDomains on iOS).
	// The hosts that cannot resolve per domain (i.e. Android) are supposed to
	// use the servers for all the queries since the Cluster DNS forwards the
	// queries that do not belong to the Cluster.
	const char *const *match_domains;
	size_t match_domains_len;
	// MatchAllDomains means that the servers resolve all the queries.
	uint8_t match_all_domains;
} octelium_dns_config_t;

// octelium_network_config_t is the complete desired configuration of the OS
// network interface. The host applies it as a whole (i.e. via
// VpnService.Builder on Android and NEPacketTunnelNetworkSettings on iOS).
typedef struct {
	// Generation monotonically increases with every request of the tunnel.
	uint64_t generation;
	const octelium_prefix_t *addresses;
	size_t addresses_len;
	// Routes is the list of the destination prefixes that are routed via the
	// tunnel. A default route is never included.
	const octelium_prefix_t *routes;
	size_t routes_len;
	// DNS is NULL whenever the tunnel must not configure the DNS.
	const octelium_dns_config_t *dns;
	uint32_t mtu;
} octelium_network_config_t;

// octelium_request_t is an asynchronous request from liboctelium to the host.
// The host completes every request exactly once via
// octelium_tunnel_complete_request. liboctelium abandons a request that is
// not completed within 30 seconds.
typedef struct {
	uint32_t type;
	// NetworkConfig is set for OCTELIUM_REQUEST_APPLY_NETWORK_CONFIG. The
	// host is supposed to exclude the transport sockets of liboctelium from
	// the tunnel (e.g. via VpnService.Builder.addDisallowedApplication or via
	// protect_socket on Android).
	const octelium_network_config_t *network_config;
} octelium_request_t;

typedef struct {
	// Result is OCTELIUM_OK or the error code of a failed request. The host
	// completes an OCTELIUM_REQUEST_GET_ACCESS_TOKEN request with
	// OCTELIUM_ERR_UNAUTHENTICATED whenever it has to authenticate again.
	int32_t result;
	// Message is an optional error message.
	const char *message;
	// TunFD is the file descriptor of the established tunnel interface of an
	// OCTELIUM_REQUEST_APPLY_NETWORK_CONFIG request. The host retains its
	// ownership and liboctelium duplicates it before
	// octelium_tunnel_complete_request returns. It is required on Android. On
	// iOS, it can be -1 in which case liboctelium finds the utun file
	// descriptor of the packet tunnel provider by itself.
	int32_t tun_fd;
	// AccessToken is the current short-lived Cluster access token of an
	// OCTELIUM_REQUEST_GET_ACCESS_TOKEN request. The refresh token must never
	// be passed.
	const char *access_token;
} octelium_response_t;

typedef struct {
	uint32_t type;
	// State is the current state of the tunnel of an OCTELIUM_EVENT_STATE.
	uint32_t state;
	// Error is the code of the last error of an OCTELIUM_EVENT_STATE or
	// OCTELIUM_OK.
	int32_t error;
	// LogLevel is the level of an OCTELIUM_EVENT_LOG.
	uint32_t log_level;
	// CreatedAt is the Unix time of the event in milliseconds.
	int64_t created_at;
	// Message is the message of an OCTELIUM_EVENT_LOG or the error message of
	// an OCTELIUM_EVENT_STATE. It can be NULL.
	const char *message;
} octelium_event_t;

typedef struct {
	uint32_t state;
	uint32_t gateways;
	uint32_t connected_gateways;
	// TX is the traffic read from the tunnel interface and sent to the
	// Gateways while RX is the traffic received from the Gateways and written
	// to the tunnel interface.
	uint64_t tx_packets;
	uint64_t tx_bytes;
	uint64_t rx_packets;
	uint64_t rx_bytes;
	uint64_t dropped_packets;
} octelium_stats_t;

typedef void (*octelium_event_fn)(void *ctx, const octelium_event_t *event);

typedef void (*octelium_request_fn)(void *ctx, uint64_t request_id,
	const octelium_request_t *request);

// octelium_protect_socket_fn excludes a transport socket from the tunnel
// before it is used (i.e. VpnService.protect on Android). It returns zero on
// success.
typedef int32_t (*octelium_protect_socket_fn)(void *ctx, int32_t fd);

typedef struct {
	void *ctx;
	// OnEvent is required.
	octelium_event_fn on_event;
	// OnRequest is required.
	octelium_request_fn on_request;
	// ProtectSocket is optional.
	octelium_protect_socket_fn protect_socket;
	uint32_t platform;
	uint32_t log_level;
	// DeviceName is the name of the tunnel interface in the NATIVE platform
	// mode. It defaults to "octelium".
	const char *device_name;
} octelium_tunnel_opts_t;

// octelium_abi_version returns OCTELIUM_ABI_VERSION of liboctelium itself.
uint32_t octelium_abi_version(void);

// octelium_version returns the semantic version of liboctelium. The string is
// statically allocated.
const char *octelium_version(void);

// octelium_last_error returns the message of the last error returned to the
// calling thread. It is valid until the next call of a liboctelium function
// from the same thread and it is never NULL.
const char *octelium_last_error(void);

// octelium_tunnel_new creates a tunnel. The tunnel does not do anything until
// its config is set via octelium_tunnel_set_config.
int32_t octelium_tunnel_new(uint32_t abi_version, const octelium_tunnel_opts_t *opts,
	uint64_t *tunnel);

// octelium_tunnel_set_config sets the complete desired configuration of the
// tunnel. The config is validated synchronously while it is applied
// asynchronously. The progress is reported via OCTELIUM_EVENT_STATE.
int32_t octelium_tunnel_set_config(uint64_t tunnel, const octelium_config_t *config);

int32_t octelium_tunnel_set_network_state(uint64_t tunnel,
	const octelium_network_state_t *state);

int32_t octelium_tunnel_complete_request(uint64_t tunnel, uint64_t request_id,
	const octelium_response_t *response);

int32_t octelium_tunnel_get_stats(uint64_t tunnel, octelium_stats_t *stats);

// octelium_tunnel_free stops the tunnel and releases all its resources. It
// abandons all the pending requests. In the NATIVE platform mode, it also
// removes the tunnel interface and reverts the DNS configuration.
void octelium_tunnel_free(uint64_t tunnel);

#ifdef __cplusplus
}
#endif

#endif
