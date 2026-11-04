# Host / Client Protocol Draft

This is a design contract for the next implementation milestone. The current Flutter prototype does not connect to it yet.

## Control channel

- Use a versioned JSON message envelope over WebSocket for LAN and relay-backed control connections.
- For a future peer-to-peer path, preserve the same envelope and command semantics over a reliable WebRTC DataChannel.
- Keep video on WebRTC media tracks. Transfer all file types as resumable chunks; send metadata and transfer state on the control channel.
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
- `attachment.offer`
- `attachment.cancel`

## Attachments

The client must not restrict attachments by extension. Image and PDF previews are a client capability; other files remain attachable without an in-app preview. File names, extensions, and MIME types are untrusted hints and must not determine whether the host executes a file.

An attachment offer includes a unique `transferId`, the session ID, original display name, byte length, and an optional MIME hint. The host sanitizes the name and stores the content in a per-session incoming-attachments directory. The client streams bounded binary chunks with `transferId`, byte offset, and chunk length; the host acknowledges the highest contiguous offset so interrupted transfers can resume. The host verifies a final SHA-256 digest before marking the attachment available to an Agent adapter.

The host enforces configurable per-file and per-session storage quotas based on available disk space. The client does not impose an arbitrary fixed size cap or load a whole file into memory. Attachments are data only: receiving one never launches or executes it. Any later program launch or tool action remains subject to a separate allowlist and approval flow.

## Adapter capability declaration

Each Agent adapter reports support independently for observation, reply, interrupt, pre-execution approval, file changes, and session recovery. Read-only adapters must not expose approval controls as though they can block execution.
