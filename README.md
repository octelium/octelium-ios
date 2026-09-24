# Octelium for iOS

The Octelium iOS application. It is a native Swift/SwiftUI application with a Network Extension
packet tunnel provider that embeds `liboctelium`, the Octelium client library implemented in Go in
the [Octelium repository](https://github.com/octelium/octelium/tree/main/client/liboctelium), and
drives it through the `octelium.api.client.mobile.v1` API over its C ABI.

## Architecture

```text
Presentation                SwiftUI (Octelium.app)
                            No credentials, no C handles
        │
        ├── gRPC Swift 2 ──► Octelium Cluster API (octelium-api.<domain>:443)
        │   Network.framework ListService, ListNamespace, GetStatus
        │   + TLS          x-octelium-auth from GetAPICredential
        │
        │ LocalClient (mobilev1 protobuf)
        ▼
liboctelium (app role)      liboctelium.a (Go, static XCFramework)
                            authentication, credentials, domain settings
        │
        │ encrypted state in the App Group, state key in the Keychain
        │
liboctelium (tunnel role)   OcteliumTunnel.appex (NEPacketTunnelProvider)
                            Connections, WireGuard/QUIC, reconnects
        │ PlatformRequest.ApplyTunnelConfiguration
        ▼
NEPacketTunnelProvider      NEPacketTunnelNetworkSettings, split routes, split DNS,
                            NWPathMonitor, Connect On Demand
```

The rule that the whole application follows is:

> Connection state belongs to liboctelium. Cluster state belongs to the Cluster API.
> Presentation belongs to SwiftUI. The iOS platform belongs to the host.

* The application and its packet tunnel provider are separate processes. Each one runs its own
  liboctelium instance over the same encrypted state. The application authenticates, signs out,
  removes domains and stores the domain settings while the provider owns the Connection. The
  application merges the status of both instances. The provider pushes a Darwin notification
  whenever its status changes and the application pulls the snapshot via
  `NETunnelProviderSession.sendProviderMessage`. Nothing is polled.
* The UI never sees refresh tokens. The Cluster API calls use the short-lived access token of
  `GetAPICredential`, cached in memory until 30 seconds before its expiry and renewed once upon
  `UNAUTHENTICATED`, exactly like the desktop and the Android applications.
* The liboctelium state is encrypted with a random 32-byte key stored in the Keychain with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and shared with the provider via the App Group
  access group. The provider never creates the key. The device identity is a random installation
  UUID stored the same way. No hardware identifier is used.
* Every `ApplyTunnelConfiguration` is validated before being applied as a whole via
  `setTunnelNetworkSettings`. Default routes are refused, routes are canonicalized, only the IP
  families that Octelium assigns are configured, `enforceRoutes` is enabled and the Cluster DNS
  servers are routed through the tunnel. The provider omits the TUN file descriptor and liboctelium
  finds the `utun` file descriptor of the provider by itself.
* iOS resolves the DNS queries per domain. The split DNS of a Connection uses
  `NEDNSSettings.matchDomains` so that only the Cluster domains are resolved by the Cluster DNS
  while the full DNS mode resolves every domain by the Cluster DNS.
* The underlying network is tracked in the provider via `NWPathMonitor` and reported to
  liboctelium via `SetNetworkState`.
* The browser authentication uses `ASWebAuthenticationSession`. The Portal redirects to
  `com.octelium.client:/callback/success` which is validated and passed to `CompleteAuthentication`.
* Auto connect is implemented with VPN Connect On Demand. At most one Cluster is the On Demand
  target of the single Octelium VPN configuration. Disconnecting manually turns On Demand off until
  the next Connection.

## Repository layout

```text
OcteliumKit/                the platform-independent Swift package (builds and tests on Linux too)
OcteliumKit/Protos          the vendored Octelium protobuf APIs (scripts/sync-proto.sh)
OcteliumKit/.../OcteliumProto   the generated SwiftProtobuf messages
OcteliumKit/.../OcteliumCore    LocalClient, status and log stores, domain helpers, tunnel configuration
                            validation, PlatformRequest handler, state key, IPC with the provider
OcteliumKit/.../OcteliumAPI     the generated gRPC Swift 2 client, the Cluster API client and the Services model
OcteliumKit/.../LibOctelium     the Swift wrapper of the liboctelium C ABI
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
* Go, as required by the `go.work` of the Octelium repository, in order to build liboctelium
* A checkout of the Octelium repository that includes `client/liboctelium`
* `protoc` in order to regenerate the protobuf sources

## Building liboctelium

```bash
OCTELIUM_SOURCE_DIR=/path/to/octelium ./scripts/build-liboctelium.sh
```

The script builds `liboctelium.a` with `GOOS=ios` for `iphoneos/arm64`, `iphonesimulator/arm64` and
`iphonesimulator/x86_64`, packages them into `liboctelium/liboctelium.xcframework`, records the
Octelium commit and verifies that every library exports the C ABI. liboctelium is always built in
the production mode, which enforces the TLS verification of the Cluster even when the Octelium
revision is not a tagged release. `SLICES` restricts the built slices and `OCTELIUM_LIB_DIR` changes
the output directory.

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

`make test` runs the tests of `OcteliumKit`, including the Cluster API client and the Services
model against an in-process gRPC server. They run on macOS and on Linux.

The liboctelium integration tests run the Swift wrapper of the C ABI against the real liboctelium
built for the host:

```bash
OCTELIUM_SOURCE_DIR=/path/to/octelium make test-host
```

## Updating the protobuf APIs

`OcteliumKit/Protos` is vendored out of the Octelium protobuf APIs repository together with the
commit it was taken from and the generated Swift sources are committed. Synchronize them whenever
the mobile API changes:

```bash
OCTELIUM_PB_DIR=/path/to/the/protobuf/apis ./scripts/sync-proto.sh
```

The protoc plugins are built out of the versions pinned by `OcteliumKit/Package.resolved`.

## Workflows

`ci.yaml` runs the `OcteliumKit` tests and verifies that the generated sources are up to date for
every push and pull request. It also builds liboctelium out of the current Octelium `main` branch
for the host in order to run the integration tests and for iOS in order to run the iOS unit tests
and build the application.

The manually triggered `build.yaml` workflow builds the application at any commit. It resolves the
current Octelium `main` commit (or any other branch, tag or commit given as `octelium_ref`), builds
liboctelium out of it, bundles it and uploads an unsigned device IPA and archive, a simulator
application along with the Octelium commit in `OCTELIUM_COMMIT`.

`release.yaml` runs for semantic `v*.*.*` tags. It verifies that `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION` of `Config/Octelium.xcconfig` match the tag, builds liboctelium out of the
latest published Octelium release, archives and exports the signed IPA, generates checksums and
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
`Octelium/Resources/Licenses`.
