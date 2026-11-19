# RemoteAISync

**Remote control for local AI coding agents over LAN or self-hosted WSS relays.**

RemoteAISync (RAS) lets you continue selected local coding-agent sessions from a browser or Android device. The agent keeps running on your own Windows or Linux computer. A single Dart host runtime can run either the Agent host or a self-hosted relay; the Flutter client connects directly over a trusted LAN or through a relay.

The project is self-hosted. It does not provide a cloud service or proxy model-provider accounts.

## At a glance

```text
Browser / Android
       │
       ├── LAN: ws:// or wss:// ─────────────── Agent host
       │
       └── WSS ── TLS reverse proxy ── Relay ── Agent host
                                      (outbound host tunnel)
```

- **Client:** Flutter Web and Android APK.
- **Windows:** Flutter desktop host console and bundled Dart host/relay runtime.
- **Ubuntu:** headless Dart executable, suitable for host mode or relay mode and managed with systemd.
- **Agents:** OpenCode, Codex, and Claude Code adapters run on the host machine.
- **Networking:** direct WebSocket connections for trusted networks; WSS for public networks. The host can connect outbound to a relay, so it does not need an inbound home-router port forward.

## Features

- Browse and continue supported OpenCode, Codex, and Claude Code sessions from one client.
- Create sessions, send messages, inspect tool activity, and use supported stop, approval, question, and model controls according to each agent's capabilities.
- Browse the host workspace, set a session's working directory, create folders, preview supported files, and upload attachments.
- Pair a device using a short-lived, single-use invitation. The host operator approves first-time devices; saved device credentials support later reconnects and can be revoked by the host.
- Keep LAN and relay routes in one connection profile. The client prefers a configured LAN route and can fall back to the configured relay route.
- Run host or relay mode from the same runtime. A relay creates room-scoped credentials and forwards connections between a host and its clients.
- Use the desktop host console to inspect agent availability, connected clients, pairing requests, and relay status.

## Agent support and limits

| Agent | Integration | Important limits |
| --- | --- | --- |
| OpenCode | Local OpenCode Server API and events | The OpenCode service must be available on the host. |
| Codex | Official app-server JSON-RPC | RemoteAISync-created sessions support live controls. Existing Codex desktop sessions are read and receive queued submissions; RemoteAISync cannot take over a desktop-owned active turn or its already-pending native question. |
| Claude Code | Local CLI and saved JSONL transcripts | RemoteAISync-created CLI sessions can be continued and stopped. Claude's native Remote Control and native approval handoff are not integrated. |

Controls are shown according to the integration and session type. A visible capability should not be interpreted as a guarantee that the corresponding native desktop application can be controlled from another process.

## Requirements

### For users

- Windows 10/11 or a supported Ubuntu Linux release.
- At least one supported coding agent installed and authenticated on the host machine.
- A browser or Android device for the client.
- For public WSS: a domain pointing to the server and a TLS certificate. Caddy is the documented reverse proxy; a publicly trusted certificate avoids installing a custom CA on phones.

### For development

- Flutter SDK compatible with the repository's Dart SDK constraint (`^3.12.2`).
- Git.
- Android SDK and an Android toolchain to build APKs.
- Visual Studio C++ desktop workload to build the Windows Flutter GUI.
- A Linux build environment for compiling the Linux executable for its target architecture.

Agent CLIs are only needed on the machine running host mode. The relay does not need coding agents installed.

## Quick start: Windows development

Run commands from the repository root in PowerShell.

1. Install Flutter dependencies:

   ```powershell
   flutter pub get
   ```

2. Start the Windows host console:

   ```powershell
   flutter run -d windows -t lib/main_desktop.dart
   ```

3. In the console, select **Host mode**, check that an agent is available, and start the host. Open the connection information and create a phone pairing invitation. Approve the device on the host the first time it connects.

4. In a second terminal, start the Web client on the LAN:

   ```powershell
   flutter run -d web-server --web-hostname 0.0.0.0 --web-port 8911
   ```

   Open `http://127.0.0.1:8911` on the same computer. From a phone on the same Wi-Fi, open `http://<host-LAN-IPv4>:8911`. The Web server port and the Agent host port are separate; the default host WebSocket port is `8910`.

5. In the client, scan the host's pairing QR code or enter connection details manually. Select an agent and then create a session or continue an available session.

The repository also contains `start_host.bat`, `stop_host.bat`, `start_client.bat`, and `stop_client.bat` for Windows development. The desktop console manages the Agent host process; do not start a second host on port `8910` at the same time.

## Build the Android client

```powershell
flutter pub get
flutter build apk --release
```

The APK is written to `build/app/outputs/flutter-apk/app-release.apk`. Install it on a USB-connected Android device with:

```powershell
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

For a local debug build, use `flutter build apk --debug`.

## Build and run the Windows host console

Install Flutter and the Visual Studio C++ desktop workload, then run:

```powershell
flutter pub get
flutter run -d windows -t lib/main_desktop.dart
```

To create a portable Windows release directory with the Dart host runtime, use:

```powershell
./tooling/build_windows_release.ps1
```

The output is under `build/windows/x64/runner/Release/`. The current script creates a portable directory, not an installer.

## Deploy on Ubuntu

The same host entry point is compiled as a Linux executable and accepts host or relay mode. Deployment examples, environment templates, Caddy/Nginx configuration, and systemd units are in [`deploy/ubuntu`](deploy/ubuntu/README.md).

Build on Linux for the server's architecture:

```bash
dart pub get
dart compile exe host/bin/remotaisync_host.dart -o build/remotaisync
```

The relay service can be installed with `deploy/ubuntu/remotaisync-relay.service`; the host service template is `deploy/ubuntu/remotaisync-host.service`. The server itself does not need the Dart SDK after the executable has been built and installed.

For public access, point a domain to the Ubuntu server, terminate TLS at Caddy or Nginx, and proxy only the documented host/relay WebSocket and health paths to loopback. Keep the Dart listeners and administrative endpoints private. The deployment guide has the full setup and commands.

## Network modes

### Direct host

The client connects directly to the Agent host. Use `ws://` only on a trusted LAN or VPN. For a public Ubuntu host, expose a `wss://` URL through a TLS reverse proxy and keep the host process bound to loopback behind that proxy. A public host can run the agents itself; no separate relay is required for that topology.

### Self-hosted relay

Run the same host executable with `--mode relay`. The relay operator keeps the relay administration secret on the relay machine and issues a short-lived, single-use host registration code. The host registers and receives room-scoped credentials. The phone pairs with the host, not with the relay administrator. For Internet use, clients and hosts connect with WSS through a TLS reverse proxy; use plain WS only in a trusted private network.

## Security model

- First-time pairing requires approval on the host. Invitations expire and can be used once; paired devices can be revoked.
- Relay administration credentials, one-time host registration codes, room credentials, and device credentials have distinct roles. Do not share relay administration credentials with clients.
- Use WSS on public networks. TLS protects each connection to the TLS endpoint.
- **This release does not implement end-to-end encryption.** A relay operator can read application data that passes through the relay. Self-host the relay and protect its server, credentials, backups, and logs accordingly.
- Do not expose relay administration endpoints or the host's local management interface to the public Internet. Follow the loopback and reverse-proxy boundaries in the deployment guide.
- Do not commit pairing tokens, relay credentials, private keys, `.env` files, local databases, debug logs, or screenshots containing connection secrets.

Report security issues privately to the repository maintainer rather than opening a public issue with exploit details.

## Current limitations

- Screen capture/streaming and WebRTC/TURN transport are not implemented. The planned screen-streaming boundary is described in [`docs/screen-streaming.md`](docs/screen-streaming.md).
- Relay WSS provides transport encryption to the TLS endpoint, not end-to-end encryption between phone and host.
- Codex desktop-owned sessions have narrower control than RemoteAISync-owned Codex sessions; see the Agent support table above.
- Claude Code's native Remote Control and native approval/question handoff are not integrated.
- Some agent-specific features vary by agent version, operating system, session owner, and authentication state.
- The project is under active development. Review the security model and test in a trusted environment before using it with sensitive workspaces.

## Development and verification

From the repository root:

```powershell
flutter analyze --no-pub
flutter test --no-pub
flutter build web
```

The test suite includes domain, adapter, relay, pairing, and Flutter widget tests. A Codex integration test is opt-in because it requires a locally installed and authenticated Codex CLI.

## Project layout

| Path | Purpose |
| --- | --- |
| `lib/main.dart` | Flutter Web/Android client entry point |
| `lib/main_desktop.dart` | Windows host console entry point |
| `lib/src/domain/` | Shared session, message, pairing, and transport models |
| `lib/src/application/` | Client state and host connection logic |
| `lib/src/presentation/` | Client UI and shared components |
| `lib/src/desktop/` | Windows host/relay console and service manager |
| `host/lib/src/` | Agent adapters, bridge, relay, pairing, and file transfer |
| `host/bin/remotaisync_host.dart` | Host/relay runtime entry point |
| `deploy/ubuntu/` | Ubuntu systemd, reverse proxy, and environment templates |
| `docs/protocol.md` | WebSocket protocol and current behavior |
| `docs/screen-streaming.md` | Planned screen-streaming interface and boundaries |

## Contributing

Issues and pull requests are welcome. Before submitting a change, run the relevant Flutter tests and analyzer. For protocol, pairing, or transport changes, include tests for compatibility, authorization boundaries, and reconnect behavior. Do not include real credentials or private user data in issues, fixtures, logs, or screenshots.

## License

RemoteAISync is distributed under the MIT License. See [`LICENSE`](LICENSE).
