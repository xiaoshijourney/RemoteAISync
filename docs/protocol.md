# Host / Client Protocol

## Implemented local milestone

The Windows host exposes `ws://127.0.0.1:8787/ws`. It accepts WebSocket origins on loopback hosts and requires the one-time pairing token in the first `client.hello` command. The host is loopback-only, so this endpoint is for a browser running on the same computer; it is not a LAN or phone endpoint. Remote pairing will require authenticated encryption before the host binds to any network interface.

The host starts a separate OpenCode v2 API process for the selected project directory. That process uses a random local port and random Basic Auth password, both scoped to that process, and binds only to `127.0.0.1`. The bridge reads sessions and messages through this API; it does not inspect other OpenCode directories or scrape process output.

Supported commands:

- `client.hello`: validate the current pairing token.
- `session.select`: read a session's latest 100 messages.
- `session.refresh`: refresh the session list and selected session.
- `session.reply`: submit text to the selected OpenCode session.

The host lists the newest 50 sessions for the configured directory. Message history is capped at the latest 100 messages and displayed oldest-to-newest. OpenCode events trigger refreshes; a three-second refresh also runs as a fallback. Commands receive `command.result` or `command.error` events.

Events use the version 1 JSON envelope:

```json
{
  "schemaVersion": 1,
  "eventId": "evt-id",
  "deviceId": "remoteaisync-host",
  "sessionId": "session-id",
  "seq": 42,
  "createdAt": "2026-11-04T06:00:00Z",
  "kind": "session.snapshot",
  "payload": {}
}
```

The current bridge assigns in-memory sequence numbers. It does not persist events, deduplicate commands, or replay missed events after reconnect. `expectedRevision` is reserved in the command envelope but is not enforced yet.

## Deferred protocol work

- Durable session snapshots, command deduplication, event replay, and reconnect recovery.
- Device pairing for other computers and phones, authenticated encrypted transport, LAN discovery, IPv6, and optional self-hosted relay.
- Resumable file transfer for arbitrary file types. Preview support for images and PDFs remains a client capability; receiving a file will never execute it.
- Capability declarations for each Agent adapter, including whether it can observe, reply, interrupt, or block a tool before execution.
- WebRTC for one application window only. Full desktop capture is out of scope.

The current OpenCode adapter sends only text to `/api/session/{sessionID}/prompt`. Approval interception, file transfer, filesystem access, program launch, and window control are not enabled by this protocol version.
