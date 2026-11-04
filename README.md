# RemoteAISync

Flutter client for remotely viewing and continuing AI Agent sessions hosted on a Windows PC.

## Current status

This first milestone is a browser-runnable UI prototype backed by local demo data. It does not connect to a Windows host, execute approvals, read host files, or launch programs. Every demo-only action is labelled in the interface.

Implemented in the prototype:

- Session timeline, reply composer, option selection, and local approval state transitions.
- Sample workspace file list and source preview.
- Host address and port format validation.
- Responsive Flutter Web and Android project targets.

## Run locally

```powershell
flutter pub get
flutter run -d edge
```

If Edge is not detected by Flutter, start a web server and open the printed local URL in a browser:

```powershell
flutter run -d web-server --web-hostname 127.0.0.1 --web-port 8765
```

## Checks

```powershell
dart format lib test
flutter analyze
flutter test
flutter build web
```

## Project layout

- `lib/src/domain`: session, message, approval, and file models.
- `lib/src/application`: demo state controller; future host-backed controller will implement the same UI-facing actions.
- `lib/src/presentation`: app shell, theme, and screens.
- `docs/protocol.md`: proposed host/client event contract.

## Planned implementation order

1. Validate this UI prototype in a local browser.
2. Implement the Windows user-session host and a versioned WebSocket event protocol.
3. Replace demo state with a host repository, initially targeting managed OpenCode sessions on a LAN.
4. Add durable event recovery, device pairing, and host-backed approvals.
5. Add file transfer, single-window WebRTC, remote network paths, and additional Agent adapters.

The browser and Android client share Flutter/Dart code. Android remains a supported target; the first visual validation uses Flutter Web for a faster local feedback loop.
