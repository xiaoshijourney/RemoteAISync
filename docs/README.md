# RemoteAISync 文档导航

这里按使用场景整理项目文档。首页只保留产品概览和入口，部署命令、协议细节与实验性设计放在对应专题中。

## 先选一个入口

| 你想做什么 | 推荐文档 |
| --- | --- |
| 直接体验浏览器客户端 | [RemoteAISync Web App](https://ras.xiaoshijourney.com/app/) |
| 从零启动手机/浏览器、Windows 主机和 Ubuntu 中继 | [全链路启动指南](全链路启动指南.md) |
| 判断应该直连还是使用三端中继 | [两端与三端部署指南](两端与三端部署指南.md) |
| 在 Ubuntu/VPS 部署 Host 或 Relay | [Ubuntu Relay and Host Deployment](../deploy/ubuntu/README.md) |

## 开发与协议

| 文档 | 内容 |
| --- | --- |
| [Host / Client Protocol](protocol.md) | WebSocket、Host/Client/Relay 角色、配对、消息和 Agent 接入边界 |
| [单窗口画面推流接口契约](screen-streaming.md) | 尚未实现的单窗口 WebRTC 推流设计边界和接口草案 |
| [RemoteAISync Brand Specification](../brand-spec.md) | Logo、颜色、字体、间距和产品文案基准 |
| [官网构建说明](../site/README.md) | Vite 官网的本地开发、生产构建与静态部署 |

## 当前支持的 Agent

| Agent | 当前接入方式 | 关键边界 |
| --- | --- | --- |
| OpenCode | 本机 OpenCode Server API 与事件流 | 主机上的 OpenCode 服务必须可用 |
| Codex | 官方 app-server JSON-RPC | 可控制 RemoteAISync 创建的会话；不能接管桌面端正在运行的轮次或原生待处理请求 |
| Claude Code | 本地 CLI 与 JSONL 会话记录 | RemoteAISync 启动的任务可继续和停止；原生 Remote Control 与审批交接尚未集成 |

## 文档约定

- 公网连接使用 `wss://`；普通 `ws://` 仅用于可信局域网或 VPN。
- 文档中的 `host.example.com`、`relay.example.com` 等域名是示例，部署时替换为自己控制的域名。
- 不要提交真实密码、私钥、二维码、令牌、`.env` 文件或含凭据的截图。
- 当前版本没有端到端加密（E2EE）；TLS 终止代理和能够访问 Relay 主机/代理的人可能读取经过转发的应用消息。

