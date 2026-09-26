# Octelium for iOS

The Octelium iOS application. It is a native Swift/SwiftUI application that implements the Octelium
client, i.e. the authentication to the Cluster, the encrypted local state and the Connect stream of
the Cluster API, along with a Network Extension packet tunnel provider that embeds
[liboctelium](https://github.com/octelium/liboctelium), the Octelium tunnel engine implemented in
Rust, through its C ABI.

## Architecture

```text
Presentation                SwiftUI (Octelium.app)
                            No credentials, no C handles
        │
        ├── gRPC Swift 2 ──► Octelium Cluster API (octelium-api.<domain>:443)
        │   Network.framework ListService, ListNamespace, GetStatus
        │   + TLS          x-octelium-auth from GetAPICredential
        │
        │ LocalClient (octelium.api.client.daemon.v1 state model)
        ▼
Octelium client (app)       OcteliumClient (Swift, OcteliumKit)
                            domains, Operations, authentication, credentials, settings
        │
        │ encrypted state in the App Group, state key in the Keychain
        │
Octelium client (tunnel)    OcteliumTunnel.appex (NEPacketTunnelProvider)
                            Connect stream, API reconnects, background token renewal
        │
        ├── gRPC Swift 2 ──► Octelium Cluster API
        │                   auth.v1: tokens, refresh, logout, Device registration
        │                   user.v1: Connect, Disconnect, GetStatus
        │
        │ Tunnel (complete desired Connection state)
        ▼
liboctelium                 liboctelium.a (Rust, static XCFramework)
                            TUN packet I/O, WireGuard, QUICv0, Gateway reconnects
        │ OCTELIUM_REQUEST_APPLY_NETWORK_CONFIG
        ▼
NEPacketTunnelProvider      NEPacketTunnelNetworkSettings, split routes, split DNS,
                            NWPathMonitor, Connect On Demand
```

The rule that the whole application follows is:

> The control plane belongs to Swift. The data plane belongs to liboctelium. Cluster state belongs
> to the Cluster API. Presentation belongs to SwiftUI. The iOS platform belongs to the host.

* The Swift client implements the semantics of the Octelium daemon: the domains, their
  authentication and Connection states, the lifecycle Operations, the settings and the errors are
  reported through the `octelium.api.client.daemon.v1` state model, exactly like the desktop and
  the Android applications.
* The application and its packet tunnel provider are separate processes. Each one runs its own
  Octelium client over the same encrypted state. The application authenticates, signs out, removes
  domains and stores the domain settings while the provider owns the Connection and the tunnel.
  Every read and write of the state is serialized across both processes with a file lock and every
  status request reconciles the domains with the state written by the other process. The
  application merges the status of both clients. The provider pushes a Darwin notification
  whenever its status changes and the application pulls the snapshot via
  `NETunnelProviderSession.sendProviderMessage`. Nothing is polled.
* The browser authentication uses `ASWebAuthenticationSession`. The login request carries a PKCE
  code challenge and the Portal redirects to `com.octelium.client:/callback/success`. The callback
  is validated against the challenge before its authentication Token is redeemed together with the
  code verifier. The Device is registered to the Cluster after the authentication.
* The access token of a domain is renewed with its refresh token whenever it is needed and, while
  the domain is connected and the network is available, in the background ahead of its expiry
  (10 minutes before it, or halfway through the lifetime of the tokens that are valid for an hour
  or longer). A refresh token that was already renewed by the other process is picked up from the
  state. A domain whose refresh token is rejected becomes signed out and its Connection requires
  authentication again. The UI never sees refresh tokens. The Cluster API calls of the UI use the
  short-lived access token of `GetAPICredential`, cached in memory until 30 seconds before its
  expiry and renewed once upon `UNAUTHENTICATED`, exactly like the desktop and the Android
  applications.
* The credentials and the settings of the domains are persisted in the encrypted state format of
  the Octelium clients (`octelium.db`), encrypted with AES-256-GCM using a random 32-byte key stored
  in the Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and shared with the
  provider via the App Group access group. The provider never creates the key. The state is
  excluded from backups since it cannot be decrypted without its device-bound key. The device
  identity is a random installation UUID stored the same way. No hardware identifier is used.
* A Connection maintains the Connect stream of the Cluster API. The Swift client reduces the
  initial state and every `AddGateway`, `UpdateGateway`, `DeleteGateway` and `UpdateDNS` event into
  the current Connection state and passes it as a whole to liboctelium which computes the
  difference by itself. The stream is reconnected with an exponential backoff while the tunnel of
  the Connection keeps running. liboctelium asks for the short-lived access token whenever it
  (re)connects to a QUICv0 Gateway. liboctelium never talks to the Cluster API, never persists
  anything and never sees a refresh token.
* Every network configuration requested by liboctelium is validated before being applied as a whole
  via `setTunnelNetworkSettings`. Default routes are refused, routes are canonicalized, only the IP
  families that Octelium assigns are configured, `enforceRoutes` is enabled and the Cluster DNS
  servers are routed through the tunnel. The provider omits the TUN file descriptor and liboctelium
  finds the `utun` file descriptor of the provider by itself.
* iOS resolves the DNS queries per domain. The split DNS of a Connection uses
  `NEDNSSettings.matchDomains` so that only the Cluster domains are resolved by the Cluster DNS
  while the full DNS mode resolves every domain by the Cluster DNS.
* The underlying network is tracked in both processes via `NWPathMonitor` and reported to both
  Octelium clients. The provider passes it to liboctelium and to the reconnection backoff of the
  Connect stream, and it reports the current network before it starts the Connection.
* Auto connect is implemented with VPN Connect On Demand. At most one Cluster is the On Demand
  target of the single Octelium VPN configuration. Disconnecting manually turns On Demand off until
  the next Connection. Signing out of, removing or turning auto connect off for the On Demand target
  moves On Demand to the next authenticated Cluster with auto connect enabled.
* Signing out, removing a domain and resetting the local state stop the VPN first and fail if it
  does not stop. Resetting also removes the VPN configuration.

## Repository layout

```text
OcteliumKit/                the platform-independent Swift package (builds and tests on Linux too)
OcteliumKit/Protos          the vendored Octelium protobuf APIs (scripts/sync-proto.sh)
OcteliumKit/.../OcteliumProto   the generated SwiftProtobuf messages
OcteliumKit/.../OcteliumCore    the local client interface, the encrypted state, the session tokens,
                            the browser authentication, the Connection state reduction, status and
                            log stores, domain helpers, tunnel configuration validation, state key,
                            IPC with the provider
OcteliumKit/.../OcteliumAPI     the generated gRPC Swift 2 clients, the Octelium client (domains,
                            Operations, authentication, Connect stream), the Cluster API client of
                            the UI and the Services model
OcteliumKit/.../LibOctelium     the Swift wrapper of the liboctelium C ABI and its vendored C header
Octelium/                   the iOS application (SwiftUI, VPN configuration, authentication)
OcteliumTunnel/             the packet tunnel provider
Shared/                     the code compiled into both the application and the provider
OcteliumTests/              the iOS unit tests
HostTests/                  the liboctelium integration tests against the real library built for the host
scripts/                    liboctelium, protobuf, project and release helpers
project.yml                 the XcodeGen specification of Octelium.xcodeproj
liboctelium/                the prebuilt liboctelium XCFramework (not committed)
```

## Requirements

* Xcode 26 or later (iOS 18 deployment target)
* [XcodeGen](https://github.com/yonaskolb/XcodeGen)
* Rust, as required by `rust-version` of liboctelium, with the `aarch64-apple-ios`,
  `aarch64-apple-ios-sim` and `x86_64-apple-ios` targets
* A checkout of the [liboctelium repository](https://github.com/octelium/liboctelium)
* `protoc` in order to regenerate the protobuf sources

## Building liboctelium

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
LIBOCTELIUM_SOURCE_DIR=/path/to/liboctelium ./scripts/build-liboctelium.sh
```

The script builds `liboctelium.a` for `aarch64-apple-ios`, `aarch64-apple-ios-sim` and
`x86_64-apple-ios`, packages them into `liboctelium/liboctelium.xcframework`, records the
liboctelium commit and verifies that every library exports the C ABI. `TARGETS` restricts the built
targets and `OCTELIUM_LIB_DIR` changes the output directory.

The Swift wrapper is compiled against `OcteliumKit/Sources/COctelium/octelium.h`, a copy of the C
header of liboctelium. The scripts refuse to build a liboctelium revision whose header differs from
it. Whenever the C ABI changes, copy `include/octelium.h` of liboctelium and update the Swift
wrapper accordingly.

## Building the application

```bash
make project
open Octelium.xcodeproj
```

`make project` generates `Octelium.xcodeproj` out of `project.yml` and pins the Swift packages to
`OcteliumKit/Package.resolved`. The bundle identifier, the App Group, the development team and the
provisioning profiles are set in `Config/Octelium.xcconfig` and can be overridden in the ignored
`Config/Local.xcconfig`:

```text
OCTELIUM_DEVELOPMENT_TEAM = ABCDE12345
OCTELIUM_BUNDLE_ID = com.example.octelium
```

Both the application and the packet tunnel provider require the Network Extensions
(`packet-tunnel-provider`) and the App Groups capabilities.

## Testing

```bash
make test
make test-ios
```

`make test` runs the tests of `OcteliumKit`. They run on macOS and on Linux. The Octelium client
tests run the authentication, the Connect stream and the Operations against an in-process fake
Cluster API and a fake tunnel, including two clients sharing the same state like the application
and its provider. The encrypted state is tested against a state written by the Octelium Go clients.

The liboctelium integration tests run the Swift wrapper of the C ABI against the real liboctelium
built for the host:

```bash
LIBOCTELIUM_SOURCE_DIR=/path/to/liboctelium make test-host
```

## Updating the protobuf APIs

`OcteliumKit/Protos` is vendored out of the Octelium protobuf APIs repository together with the
commit it was taken from and the generated Swift sources are committed. Synchronize them whenever
the Cluster, the daemon or the client state APIs change:

```bash
OCTELIUM_PB_DIR=/path/to/the/protobuf/apis ./scripts/sync-proto.sh
```

The protoc plugins are built out of the versions pinned by `OcteliumKit/Package.resolved` and the
well-known types are taken out of the pinned `swift-protobuf` checkout.

## Workflows

`ci.yaml` runs the `OcteliumKit` tests and verifies that the generated sources are up to date for
every push and pull request. It also builds liboctelium out of the current liboctelium `main`
branch for the host in order to run the integration tests and for iOS in order to run the iOS unit
tests and build the application.

The manually triggered `build.yaml` workflow builds the application at any commit. It resolves the
current liboctelium `main` commit (or any other branch, tag or commit given as `liboctelium_ref`),
builds liboctelium out of it, bundles it and uploads an unsigned device IPA and archive, a simulator
application along with the liboctelium commit in `LIBOCTELIUM_COMMIT`.

`release.yaml` runs for semantic `v*.*.*` tags. It verifies that `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION` of `Config/Octelium.xcconfig` match the tag, builds liboctelium out of the
latest published liboctelium release, archives and exports the signed IPA, generates checksums and
provenance and publishes a GitHub release. iOS cannot install unsigned applications, hence the
release fails unless the `IOS_CERTIFICATE_BASE64`, `IOS_CERTIFICATE_PASSWORD`, `IOS_APP_PROFILE_BASE64`,
`IOS_TUNNEL_PROFILE_BASE64` and `IOS_TEAM_ID` secrets are set. The `IOS_EXPORT_METHOD` variable
selects the export method and defaults to `app-store-connect`.

## Releasing

```bash
make release VERSION=0.2.0
make release-patch
```

The release helper bumps `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, commits the change and
creates the tag. Pushing the tag triggers `release.yaml`.

## License

Apache License 2.0. See [LICENSE](LICENSE).

The bundled Ubuntu font is licensed under the Ubuntu Font Licence 1.0. See
`Octelium/Resources/Licenses`. liboctelium embeds [GotaTun](https://github.com/mullvad/gotatun),
which is licensed under MPL-2.0.
