# RemoteAISync Brand Specification

## Source Assets

- Product mark: `assets/branding/remoteaisync_icon.svg` (official project icon; copied to `site/assets/remoteaisync_icon.svg` for the standalone site).
- Real desktop UI: `docs/assets/desktop-host-overview.png` (Windows Host dashboard captured from the current app; copied to `site/assets/desktop-host-overview.png`).
- Real Android UI: `docs/assets/phone/ras-home.png` (device screenshot in disconnected state; copied to `site/assets/ras-home.png`).
- Product capabilities and deployment facts: `README.md`, `README.en.md`, `docs/全链路启动指南.md`, and `deploy/ubuntu/README.md`.

## Visual Tokens

- Ink: `#17181D`, matching the app icon background.
- Paper: `#F7F8FA`, matching the icon foreground and product surfaces.
- Neutral scale: white, cool light gray, graphite, and ink. Avoid introducing a second dominant hue.
- Status accent: low-saturation sage green, derived from online indicators in the real desktop UI; reserve it for connected/healthy states.
- Display type: Manrope for Latin headlines; Noto Sans SC for Chinese; a system CJK fallback; a monospace stack for commands and endpoints.
- Spacing: 8px base; section rhythm uses 24/40/64px increments.
- Corners: 12px controls and 20px large media surfaces, consistent with the app's rounded panels.
- Motion: restrained opacity and transform transitions, route-line movement, and content crossfades. Honor `prefers-reduced-motion`.

## Voice

- Direct, technically clear, and self-hosting first.
- Explain the LAN, direct WSS, and relay choices without claiming end-to-end encryption.
- Do not invent adoption figures, performance claims, testimonials, or capabilities that are not implemented.
