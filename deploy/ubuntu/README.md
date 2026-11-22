# Ubuntu Relay and Host Deployment

The same RemoteAISync executable can run as either a loopback-only relay or a
public Agent host. Caddy owns the public TLS endpoints and forwards only the
required WebSocket and health paths to the local Dart process.

## Requirements

- Ubuntu 22.04 or newer.
- DNS `A` records for the public names you use. This deployment's relay
  endpoint is `remoteaisync.xiaoshijourney.com`. Add `AAAA` records only when
  IPv6 is configured end to end.
- Inbound TCP 80 and 443 for Caddy. Keep TCP 8910 and 8920 private to
  loopback; do not open either port in the cloud firewall.
- Dart SDK on the build machine. The server itself does not need Dart when using the compiled executable.

## Build the Linux executable

Build on Linux for the server architecture (normally x64):

```bash
dart pub get
dart compile exe host/bin/remotaisync_host.dart -o build/remotaisync
```

Copy `build/remotaisync` to `/opt/remotaisync/remotaisync` on the Ubuntu server. A Linux executable must be built on Linux for the target architecture; do not copy a Windows executable.

## Install the relay service

```bash
sudo useradd --system --home /var/lib/remotaisync-relay --shell /usr/sbin/nologin remotaisync
sudo install -d -o root -g root -m 0755 /opt/remotaisync
sudo install -d -o remotaisync -g remotaisync -m 0750 /var/lib/remotaisync-relay
sudo install -d -o root -g remotaisync -m 0750 /etc/remotaisync-relay
sudo install -m 0755 build/remotaisync /opt/remotaisync/remotaisync
sudo install -m 0640 -o root -g remotaisync relay.env /etc/remotaisync-relay/relay.env
sudo install -m 0644 deploy/ubuntu/remotaisync-relay.service /etc/systemd/system/remotaisync-relay.service
sudo systemctl daemon-reload
sudo systemctl enable --now remotaisync-relay
sudo systemctl status remotaisync-relay
```

Create `/etc/remotaisync-relay/relay.env` from `relay.env.example` and replace both secrets with independent random values of at least 32 characters before starting the service. Keep a protected backup of this file and `/var/lib/remotaisync-relay/.remoteaisync/relay-rooms.json`; room credentials are needed after service restarts.

## Configure Caddy and DNS

Install Caddy using its official Ubuntu package instructions, then install this project's Caddyfile as `/etc/caddy/Caddyfile`. Confirm the domain is already resolving to the server and that inbound ports 80 and 443 are reachable, then run:

```bash
sudo systemctl reload caddy
curl --fail https://remoteaisync.xiaoshijourney.com/health
```

Caddy obtains and renews a publicly trusted TLS certificate. The Windows
host and mobile client use `wss://remoteaisync.xiaoshijourney.com`; they do not need a
separately installed CA certificate. Caddy denies `/admin/*` at the public
edge. The relay's admin endpoint is for local commands only.

## Run this Ubuntu server as an Agent host

Use this when the Ubuntu/VPS itself has Codex, OpenCode or Claude Code
installed. The phone connects directly to the host over WSS; a relay is not
required for this route.

Create a dedicated service account and project directory, then install the
host unit and its environment file:

```bash
sudo useradd --system --home /var/lib/remotaisync-host --shell /usr/sbin/nologin remotaisync-host
sudo install -d -o remotaisync-host -g remotaisync-host -m 0750 /var/lib/remotaisync-host/project
sudo install -d -o root -g remotaisync-host -m 0750 /etc/remotaisync-host
sudo install -m 0640 -o root -g remotaisync-host deploy/ubuntu/host.env.example /etc/remotaisync-host/host.env
sudo install -m 0644 deploy/ubuntu/remotaisync-host.service /etc/systemd/system/remotaisync-host.service
```

Edit `/etc/remotaisync-host/host.env`:

```text
REMOTEAI_HOST_PROJECT=/var/lib/remotaisync-host/project
REMOTEAI_HOST_PORT=8910
REMOTEAI_HOST_PUBLIC_URL=wss://host.<your-domain>/ws
REMOTEAI_HOST_ALLOWED_ORIGIN=https://ras.xiaoshijourney.com
REMOTEAI_HOST_PAIRING_TOKEN=replace-with-a-random-secret-at-least-32-characters
REMOTEAI_HOST_OPENCODE=opencode
REMOTEAI_HOST_CODEX=codex
REMOTEAI_HOST_CLAUDE=claude
```

The `REMOTEAI_HOST_ALLOWED_ORIGIN` value is only needed by browser clients;
native Android/iOS clients usually do not send a browser Origin header. Keep
the pairing token private. The host process listens on `127.0.0.1:8910`, so
the public URL is reachable only through Caddy. `--persist-token` enables the
loopback-only management endpoints needed to create and approve pairing
invites; it does not expose the token to the phone.

Install the executable and start the host:

```bash
sudo install -m 0755 build/remotaisync /opt/remotaisync/remotaisync
sudo systemctl daemon-reload
sudo systemctl enable --now remotaisync-host
sudo systemctl status remotaisync-host
sudo journalctl -u remotaisync-host -f
```

Create a five-minute, one-time invite from the server itself:

```bash
set -a
. /etc/remotaisync-host/host.env
set +a
curl --fail -X POST http://127.0.0.1:${REMOTEAI_HOST_PORT}/pairing/invite \
  -H "x-remoteaisync-token: ${REMOTEAI_HOST_PAIRING_TOKEN}"
```

For a headless host, enter the returned `invite` in the client connection
page, use `wss://host.<your-domain>/ws` as the public host URL, leave the
LAN host field empty, and connect. A GUI host generates the same information
as a QR code automatically. The first connection remains pending until the
host operator approves it through the local management endpoint or GUI:

```bash
curl --fail http://127.0.0.1:${REMOTEAI_HOST_PORT}/status
curl --fail -X POST "http://127.0.0.1:${REMOTEAI_HOST_PORT}/pairing/approve?id=<pending-device-id>" \
  -H "x-remoteaisync-token: ${REMOTEAI_HOST_PAIRING_TOKEN}"
```

The host GUI/client pairing QR can contain both local routes and
`wss://host.<your-domain>/ws`. A phone on the public internet will use
the WSS route directly; a phone on the same LAN can still use the LAN route
first. The host and relay units can run on the same machine because they use
separate loopback ports, data directories and DNS names.

## Configure Caddy for both roles

Copy `deploy/ubuntu/Caddyfile` to `/etc/caddy/Caddyfile` and replace the
hostnames with domains you control. The deployed Caddy configuration exposes:

```text
remoteaisync.xiaoshijourney.com/{relay,register-host,health} -> 127.0.0.1:8920
ras.xiaoshijourney.com/app/*                               -> Flutter Web client
ras.xiaoshijourney.com/manage/*                            -> Flutter release console
ras.xiaoshijourney.com/api/*                               -> 127.0.0.1:8930
ras.xiaoshijourney.com/                                    -> /var/www/ras.xiaoshijourney.com
xiaoshijourney.com and www.xiaoshijourney.com               -> /var/www/xiaoshijourney.com
default HTTP paths /jiya, /hs, /home                        -> their existing static roots
```

Then validate and reload Caddy:

```bash
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
sudo systemctl reload caddy
curl --fail https://remoteaisync.xiaoshijourney.com/health
```

To expose an Agent host directly over WSS, point a DNS record such as
`host.<your-domain>` to this server and add this block to `/etc/caddy/Caddyfile`:

```caddyfile
host.<your-domain> {
	@host_api path /ws /health
	handle @host_api {
		reverse_proxy 127.0.0.1:8910
	}
	handle {
		respond "not found" 404
	}
}
```

This keeps pairing administration endpoints private while allowing the
WebSocket and health endpoints required by remote clients. Set the same WSS
URL in the host environment file and its pairing profile. Validate and reload
Caddy after changing the file.

Do not expose `/admin/*`, `8910`, or `8920` to the internet. WSS protects the
endpoint-to-Caddy transport. The relay can still read application messages in
this release because end-to-end encryption is not implemented.

### Legacy Nginx configuration

`nginx-remotaisync.conf` is retained only as a rollback/reference template.
This server now uses Caddy for its public sites and TLS certificates. Do not
enable Nginx alongside Caddy on ports 80 or 443.

For an existing Nginx installation, validate the Nginx configuration before
reloading it:

```bash
sudo nginx -t
sudo systemctl reload nginx
```

The Nginx template forwards `/relay`, `/register-host`, and `/health` only;
the relay process remains bound to `127.0.0.1:8920`.

## Issue or revoke a host registration code

On the Ubuntu server, read the admin secret from the protected env file without putting it in shell history, then invoke the local admin endpoint:

```bash
set -a
. /etc/remotaisync-relay/relay.env
set +a
/opt/remotaisync/remotaisync --mode relay --port "$REMOTEAI_RELAY_PORT" --issue-registration-code
```

The command prints JSON containing the one-time code, ID, and expiry. Enter the code and `wss://remoteaisync.xiaoshijourney.com` in the Windows host GUI. The relay issues a room and separate room credentials; the phone receives only the room client credential in the host's pairing QR.

To revoke a code before it is used:

```bash
set -a
. /etc/remotaisync-relay/relay.env
set +a
/opt/remotaisync/remotaisync --mode relay --port 8920 --revoke-registration-code CODE_ID
```

## Operations

```bash
sudo systemctl is-active caddy remotaisync-relay
sudo systemctl is-enabled caddy remotaisync-relay
sudo systemctl restart remotaisync-relay
sudo journalctl -u remotaisync-relay -f
curl --fail https://remoteaisync.xiaoshijourney.com/health
```

The health endpoint reports live room, host, and client counts. The relay forwards RemoteAISync messages and can read their contents; WSS encrypts traffic between each endpoint and Caddy, but this release does not provide end-to-end encryption. Do not expose `/admin/*` or the loopback listener through another proxy or firewall rule.

## Release management and update catalog

The product site serves the public Web client at `https://ras.xiaoshijourney.com/app/`
and the password-protected release console at `https://ras.xiaoshijourney.com/manage/`.
Both are static Flutter Web builds. The update API listens only on `127.0.0.1:8930`;
Caddy proxies `/api/*` to it and does not expose the artifact storage directory.

Build the client, release portal and Linux update service on a machine with Flutter
and Dart installed:

```bash
deploy/ubuntu/build_web_portals.sh
deploy/ubuntu/build_updates.sh
```

Copy `dist/web/app` and `dist/web/manage` into `/var/www/ras.xiaoshijourney.com/app`
and `/var/www/ras.xiaoshijourney.com/manage`. Install the compiled updater binary
as `/opt/remotaisync/remotaisync-updates`, then install and enable the unit:

```bash
sudo install -d -o root -g root -m 0755 /var/www/ras.xiaoshijourney.com/{app,manage}
sudo install -d -o root -g root -m 0755 /opt/remotaisync
sudo install -d -o remotaisync -g remotaisync -m 0750 /var/lib/remotaisync-updates
sudo install -m 0755 dist/linux/remotaisync-updates /opt/remotaisync/remotaisync-updates
sudo install -m 0644 deploy/ubuntu/remotaisync-updates.service /etc/systemd/system/remotaisync-updates.service
sudo systemctl daemon-reload
sudo systemctl enable --now remotaisync-updates
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
sudo systemctl reload caddy
```

Initialize the single administrator password interactively. Use at least 12
characters and store it in your password manager:

```bash
sudo -u remotaisync /opt/remotaisync/remotaisync-updates --init-admin --data-dir /var/lib/remotaisync-updates
```

Log in at `/manage/`, select product and platform, upload the finished artifact,
verify its SHA-256, version, build and notes, then explicitly publish it. Publishing
makes it available from `/api/v1/updates/{product}/{target}/latest`; withdrawing it
removes it from the public update feed. Publishing a prior withdrawn release rolls
back the feed. Uploads are limited to 2 GiB per artifact. Back up
`/var/lib/remotaisync-updates` securely; it contains the password hash, release
metadata and installable files.

Android updates open the APK download only after user confirmation. Android package
updates require the same signing key as the installed app; this repository currently
uses a debug key, so the first release signing key must be fixed before distributing
an APK that should update in place. Windows and Ubuntu binaries are downloaded for
manual installation/replacement; this version does not silently replace running
programs. The Ubuntu host/relay runtime checks the catalog at startup and logs a
notice when a newer role-specific build is published.

Native WSS is also available when a deployment cannot use Caddy. Set
`REMOTEAI_TLS_CERT` and `REMOTEAI_TLS_KEY` in the relevant environment file
to a PEM certificate chain and private key, then bind the runtime to the
public interface and port. The client uses the same `wss://` URL. A public
CA certificate is recommended; self-signed certificates require a custom
trust configuration on every native client and are not a normal mobile path.
