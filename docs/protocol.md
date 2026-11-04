# Host / Client Protocol Draft

This is a design contract for the next implementation milestone. The current Flutter prototype does not connect to it yet.

## Control channel

- Use a versioned JSON message envelope over WebSocket for LAN and relay-backed control connections.
- For a future peer-to-peer path, preserve the same envelope and command semantics over a reliable WebRTC DataChannel.
- Keep video on WebRTC media tracks. Transfer file contents as resumable chunks; send metadata and transfer state on the control channel.
- Pairing must establish authenticated encrypted transport before session data is sent.

## Event envelope

```json
{
  "schemaVersion": 1,
  "eventId": "evt-uuid",
  "deviceId": "device-id",
  "sessionId": "session-id",
  "seq": 42,
  "createdAt": "2026-11-04T06:00:00Z",
  "kind": "approval.requested",
  "payload": {}
}
```

The host assigns monotonically increasing `seq` values per session and persists events before publishing them. A reconnecting client sends its last acknowledged sequence and receives missing events or a current snapshot.

## Commands

Commands carry a unique `commandId`, `sessionId`, and the expected session revision. The host deduplicates command IDs and returns an explicit result. Approval commands reference one pending approval ID and expire; an approval is valid only if the host confirms it before the protected action executes.

Initial command kinds:

- `session.reply`
- `session.interrupt`
- `approval.resolve`
- `file.list`
- `file.read`
- `program.launch` (host allowlist only)

## Adapter capability declaration

Each Agent adapter reports support independently for observation, reply, interrupt, pre-execution approval, file changes, and session recovery. Read-only adapters must not expose approval controls as though they can block execution.
