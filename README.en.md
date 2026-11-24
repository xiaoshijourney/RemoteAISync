<div align="center">
  <img src="assets/branding/remoteaisync_icon.svg" width="96" alt="RemoteAISync icon">
  <h1>RemoteAISync</h1>
  <p><strong>Your AI coding agents, available from your phone and browser.</strong></p>
  <p>Keep agents and project files on your own host. Use the Android or Web client to review sessions, manage workspace files, and take over when needed.</p>
</div>

<p align="center">
  <a href="https://ras.xiaoshijourney.com/"><img src="https://img.shields.io/badge/Website-ras.xiaoshijourney.com-202124?style=for-the-badge&logo=googlechrome&logoColor=white" alt="Project website"></a>
  <a href="https://ras.xiaoshijourney.com/app/"><img src="https://img.shields.io/badge/Open-Web_App-5B625D?style=for-the-badge&logo=googlechrome&logoColor=white" alt="Open Web App"></a>
  <a href="https://github.com/xiaoshijourney/RemoteAISync"><img src="https://img.shields.io/badge/GitHub-Source-17181D?style=for-the-badge&logo=github&logoColor=white" alt="GitHub source"></a>
  <a href="https://github.com/xiaoshijourney/RemoteAISync/issues"><img src="https://img.shields.io/badge/Feedback-Issues-6B716D?style=for-the-badge&logo=github" alt="Report an issue"></a>
</p>

**简体中文：** [README.md](README.md) · **Documentation:** [docs/README.md](docs/README.md)

## Product Preview

| Windows host | Phone client |
| --- | --- |
| <img src="docs/assets/desktop-host-overview.png" alt="RemoteAISync Windows host UI" width="100%"> | <img src="docs/assets/phone/ras-home.png" alt="RemoteAISync Android session UI" width="280"> |

## One host, flexible connections

RemoteAISync consists of a client, an Agent host, and an optional self-hosted Relay. Agents run on your Windows or Linux host. Clients connect directly over a local network, through public WSS, or via a Relay you operate. The project does not provide model hosting or proxy model-provider accounts.

```mermaid
flowchart LR
  Client[Android / Web client] -->|LAN WS or public WSS| Host[RemoteAISync host]
  Host --> Agent[OpenCode / Codex / Claude Code]
  Client -->|Optional public WSS| Relay[Self-hosted Relay]
  Relay --> Host
  Host --> Files[Host workspace files]
```

### Supported Agents

<p>
  <img src="assets/agents/opencode.svg" width="28" alt="OpenCode logo"> <strong>OpenCode</strong>
  &nbsp;&nbsp;&nbsp;
  <img src="assets/agents/codex.svg" width="28" alt="Codex logo"> <strong>Codex</strong>
  &nbsp;&nbsp;&nbsp;
  <img src="assets/agents/claude.svg" width="28" alt="Claude Code logo"> <strong>Claude Code</strong>
</p>

Integration and available controls differ by Agent. For example, RemoteAISync cannot take over an active turn owned by the Codex desktop app. See the Agent notes in the [documentation index](docs/README.md).

## What you can do

- **Remote sessions:** Review and continue supported Agent sessions, create sessions, send messages, and inspect replies and tool activity. Available controls depend on the Agent and session type.
- **Workspace files:** Browse host directories, view and edit text files, upload attachments, download files, and delete selected files.
- **Trusted pairing:** Pair with a single-use invitation from the host. First-time connections require host approval; paired devices can be reviewed and revoked.
- **Flexible routes:** Connect directly over LAN, connect to a public host over WSS, or use a self-hosted Relay for both phone and host.
- **Host and Relay:** Manage the host through the Windows desktop UI, or run headless Host and Relay services on Ubuntu/Linux.

## Get started

| Goal | Guide |
| --- | --- |
| Try the client in a browser | [Open the RemoteAISync Web App](https://ras.xiaoshijourney.com/app/) |
| Start the client, host, and relay end to end | [Full startup guide](docs/全链路启动指南.md) |
| Choose direct or three-part deployment | [Two-part and three-part deployment guide](docs/两端与三端部署指南.md) |
| Deploy a Host or Relay on Ubuntu | [Ubuntu deployment manual (English)](deploy/ubuntu/README.md) |
| Find other project docs | [Documentation index](docs/README.md) |

## Security boundary

Use WSS for public connections; plain `ws://` is for trusted LAN or VPN networks only. **The current version does not provide end-to-end encryption (E2EE).** A TLS-terminating proxy and operators with access to a Relay host or proxy may be able to read application messages passing through them. Relay forwards connections; it does not run Agents. Pair only trusted devices and protect host, relay, and device credentials.

## Project links

- [Website](https://ras.xiaoshijourney.com/) · [Web App](https://ras.xiaoshijourney.com/app/) · [GitHub](https://github.com/xiaoshijourney/RemoteAISync)
- [Issues and suggestions](https://github.com/xiaoshijourney/RemoteAISync/issues)
- [MIT License](LICENSE)
