# RemoteAISync

RemoteAISync is a Flutter client and a local Windows host for viewing and replying to OpenCode sessions. The current milestone supports a browser on the same computer as the host.

## Current milestone

- Starts a private OpenCode v2 API process for the selected project directory.
- Lists the newest 50 sessions in that directory and reads the latest 100 messages in the selected session.
- Displays assistant text and tool calls, and sends text replies to the selected session.
- Uses an ephemeral pairing token for the browser-to-host WebSocket handshake.
- Binds both the host WebSocket and its managed OpenCode API process to `127.0.0.1`.

The bridge was verified against OpenCode v2.0.6. It does not expose the host to other devices yet. File transfer, host file browsing, approvals, app launching, window streaming, LAN access, IPv6, and relays are not implemented. The files view and approval flow remain clearly marked demo data. Attachments can be selected and previewed in the browser, but are not sent to OpenCode.

RemoteAISync does not add a cloud service. OpenCode itself continues to use the model provider configured on the computer.

## Run locally

Install dependencies once:

```powershell
flutter pub get
```

In one PowerShell window, start the host for this project:

```powershell
dart run host/bin/remotaisync_host.dart --project "$PWD" --port 8787
```

Copy the one-time pairing token printed by the host. In a second window, start Flutter Web:

```powershell
flutter run -d web-server --web-hostname 127.0.0.1 --web-port 8765
```

`--project` must point to the workspace used by the OpenCode sessions you want to view. Open the local URL printed by Flutter, choose **连接**, keep the host address at `127.0.0.1`, enter port `8787` and the pairing token, then connect. If either port is occupied, select another port and use the same host port in the browser form. Stop the host with Ctrl+C.

## Checks

```powershell
dart format lib host test
flutter analyze
flutter test
flutter build web
```

## Project layout

- `host/`: local OpenCode process manager and WebSocket bridge.
- `lib/src/domain`: shared session, message, approval, and file models.
- `lib/src/application`: demo state and WebSocket host client.
- `lib/src/presentation`: app shell and Flutter screens.
- `docs/protocol.md`: implemented local protocol and deferred capabilities.
