# Host / Client Protocol

## 当前版本

当前实现兼容 v1，并在支持的新客户端上协商 v2。v2 不改变 Agent 命令名称，
只增加传输元数据：`channel`、`messageId`、`requestId`、`eventId`、
`sequence`、`timestamp`、`topologyRevision` 和 `sessionRevision`。旧客户端
仍然可以解析 `schemaVersion: 1` 的事件；新客户端同时接受 v1/v2，事件序号
仍按会话检查，拓扑序号按全局检查。

主机和中继运行时都可以直接使用原生 TLS：传入 `--tls-cert <pem>` 与
`--tls-key <pem>`（可选 `--tls-password`）后，同一监听端口提供 WSS/HTTPS。
在 systemd 部署中也可以使用 `REMOTEAI_TLS_CERT`、`REMOTEAI_TLS_KEY` 和
`REMOTEAI_TLS_PASSWORD` 环境变量，避免把证书参数写进服务单元。
普通公网部署仍推荐 Caddy/Nginx 在 443 终止 TLS，因为证书续期、WebSocket
反代和防火墙配置更简单。公网 `ws://` 路线不会被客户端接受；私有网段可以
继续使用可信的 `ws://`。

主机、客户端和中继的健康元数据通过 `topology` 快照同步。快照只包含节点和
链路状态，不包含 Agent 业务内容：角色、在线状态、协议、连接时间、心跳时间、
RTT、上下行字节、重连次数和健康级别。主机每 5 秒发送心跳，客户端回复
`topology.pong`；连续 15 秒没有心跳时，界面应显示链路异常并进入重连状态。

主机在 `ws://host:port/ws` 提供版本 1 的 JSON WebSocket 协议，默认端口为 `8910`。直连端点绑定 IPv4 网卡，只接受回环或私有局域网来源，并检查浏览器 Origin。手机首次配对使用主机 GUI 生成的 5 分钟、单次邀请；主机批准后生成设备专属凭据并保存在 `.remoteaisync/paired-devices.json`。后续重连使用设备 ID/token；撤销设备会删除凭据并关闭现有连接。开发参数 `--persist-token` 仅用于本机 GUI 管理接口，不是手机凭据。

公网服务器也可以直接作为 Agent 主机使用，不必经过中继。主机运行时使用 `--bind-address 127.0.0.1 --allow-public-host --public-host-url wss://host.example.com/ws`，由 Caddy、Nginx 或同类 TLS 反向代理在公网提供 WSS，再回源到主机的 loopback `8910`。`--allow-public-host` 只声明并校验公网 WSS 路线，不会把公网明文 WebSocket 变成可接受的安全入口；云防火墙不应开放 `8910`。浏览器客户端还应通过 `--allowed-origin https://client.example.com` 显式加入其页面来源，原生手机通常不发送浏览器 Origin。二维码可以同时携带局域网地址和 `direct.url` 公网主机地址，客户端按局域网 → 公网主机 WSS → 中继的顺序尝试。

主机模式和中继模式可以运行在同一台 Ubuntu 服务器上，但必须使用不同的 loopback 端口、配置/数据目录和域名。例如主机使用 `127.0.0.1:8910` 与 `host.example.com`，中继使用 `127.0.0.1:8920` 与 `relay.example.com`。同一域名不同端口不是默认方案，因为移动网络和企业防火墙更容易限制高位端口；推荐用标准 `443` 加路径反代。

同一入口可用 `--mode relay --port <port> --relay-token <admin-secret> --relay-host-token <legacy-host-secret>` 启动自托管中继。中继默认只监听 `127.0.0.1`，可用 `--bind-address` 指定监听地址，并用 `--data-dir` 指定状态目录；CLI 也可从 `REMOTEAI_RELAY_ADMIN_TOKEN` 和 `REMOTEAI_RELAY_HOST_SECRET` 读取管理密钥。中继本地管理接口通过 loopback 和 `x-remoteaisync-admin-token` 认证，提供 10 分钟有效的一次性注册码；编译后的入口支持 `--issue-registration-code` 和 `--revoke-registration-code <id>` 本机管理命令。主机以注册码 POST `/register-host`，换取独立 room、host token 和 room client token。房间凭据保存在数据目录下的 `.remoteaisync/relay-rooms.json`，主机凭据保存在主机项目的 `.remoteaisync/relay-host-credentials.json`。客户端只获得所在房间的客户端凭据。中继端点为 `/relay`，健康检查为 `/health`；主机和客户端先发送 `relay.hello`，再使用原有的 `client.hello` 设备配对握手。公网部署必须通过 TLS 反向代理提供 WSS；反代必须在公网侧拒绝 `/admin/*`，因为代理到中继的请求会显示为 loopback 来源。

主机分别接入三个本地适配器：OpenCode v2 本地服务 HTTP API、本机启动的 Codex `app-server` stdio JSON-RPC，以及 Claude Code CLI 与本地 JSONL 会话。适配器可独立运行。OpenCode 本地服务未运行时，主机会尝试执行 `opencode service start`，并每 10 秒重新发现；OpenCode Basic Auth 凭据仅留在主机内存中；Codex app-server 不对网络开放。Codex 远程会话固定使用 `workspace-write` 沙箱和 `on-request` 审批策略，审批由用户处理；这不等于拦截每一次命令或文件写入。

会话 ID 使用 Agent 前缀区分：Codex 为 `codex:<threadId>`，Claude Code 为 `claude:<sessionId>`；OpenCode 沿用原会话 ID。`host.ready` 和 `host.snapshot` 均返回 `agents` 状态列表，包含 Agent ID、名称、`availability`（`available`、`degraded`、`notInstalled`、`unavailable`、`unsupported` 或 `unknown`）、版本和人类可读说明。`notInstalled` 表示 Agent 可执行程序不存在，`unavailable` 表示程序存在但服务/API 当前不可用，`degraded` 表示适配器已启动但最近一次健康刷新未能访问 Agent 服务；恢复后会自动回到 `available`。缺失 Agent 不会阻止主机桥接启动。旧版 `openCodeVersion` 与 `codexVersion` 字段继续保留兼容。`host.snapshot` 还包含默认工作目录、全局会话范围开关、已完成配对的客户端数和会话列表；每条会话包含 `agentId`、工作目录、`remoteManaged` 和 `pendingCount`。`pendingCount` 统计本桥接进程收到的 Codex 请求和可选审批 hook 转来的请求；未启用 hook 的其他进程请求不计入。桥接新建的 Codex 会话会写入 `threadSource: "remoteaisync"`，重启后仍可区分其与其他客户端创建的会话。

本机桌面 GUI 通过回环接口 `GET /status` 读取 Agent 状态、待批准设备、已配对设备和 LAN 地址。该接口只接受本机回环请求。仅限回环来源的 `/dev-config` 用于本机 GUI 控制，不应向客户端分发其中的管理令牌。

## 命令与事件

客户端命令：

- `client.hello`：校验已配对设备凭据，或提交有效的一次性邀请进入待批准状态；主机批准后发出 `host.ready`。
- `pairing.pending`：告知客户端当前等待主机批准。
- `session.create`：支持 Codex、OpenCode 和 Claude Code，会话使用传入的 `directory`，未传时使用当前工作目录；Codex 可选 `ephemeral: true` 供临时探测。
- `session.controls`：读取当前 Codex 或 OpenCode 会话的模型目录、可用思考强度和当前设置；Codex 还返回工作区 Skill 名称。
- `session.settings.update`：仅对本桥接控制的会话调用 `thread/settings/update`；若正在运行，再调用 `turn/settings/update`。
- Skill 名称由 `skills/list` 提供；以 `$SkillName` 开头的已知 Skill 会在文本之外附带 Codex `skill` 输入项（名称和本机路径）。
- `session.interrupt`：Codex 对本桥接控制的会话调用 `turn/interrupt`；OpenCode 调用会话中止接口；Claude Code 仅能停止由本桥接启动的 CLI 请求。
- `session.action`：仅对本桥接控制的会话开放 `compact`（`thread/compact/start`）和 `review`（同会话 `review/start`，目标为未提交改动）。不提供任意斜杠命令透传。
- `session.select`：选择会话并读取最近 100 条消息、待处理表单及审批。
- `session.refresh`：强制重新扫描会话列表并刷新选中会话。
- `attachment.begin`、`attachment.chunk`、`attachment.finish`、`attachment.cancel`：将任意文件按块上传到主机；完成后返回 `attachmentId`。外部 Codex 会话也可上传，后续消息会引用电脑上的文件路径。
- `session.reply`：向选中会话发送文字及可选 `attachmentIds`。外部 Codex 会话使用本机 app-server 的 `thread/queue/add` 加入原会话队列，成功时 `command.result` 携带 `delivery: queued` 和 `queuedSubmissionId`；不会自动恢复已停止的会话。附件路径附在文字中，PNG/JPEG/WebP 还作为 `localImage` 输入。桥接控制的 Codex 会话首次使用 `thread/resume`，空闲时用 `turn/start`，当前轮次运行时用 `turn/steer`。OpenCode 使用其会话 API。Claude Code 通过本机 CLI 的 `--session-id` 或 `--resume` 发送，并从本地 JSONL 同步结果。
- `session.queue.delete`：仅对当前选中的外部 Codex 会话提交 `sessionId`、`queuedSubmissionId`，调用本机 app-server 的 `thread/queue/delete` 撤回尚未被桌面端消费的队列项；已消费或已撤回时返回错误并重新刷新会话。
- `session.snapshot.queuedMessages`：所选外部 Codex 会话尚未消费的队列项，包含 `id`、`text`、`imageCount`；队列项被消费后由后续会话快照移除。按 `nextCursor` 分页读取；若读取失败，快照保留上次成功读取的队列，并附 `queueWarning` 明确提示状态可能过期。
- `session.form.reply`：向待处理提问提交答案。
- `session.permission.reply`：提交 `once` 或 `reject`。Codex 命令/文件审批的拒绝映射为 `cancel`；额外权限请求的拒绝会提交空授权并调用 `turn/interrupt`。可选桌面版 hook 审批分别映射为 `allow` 和 `deny`，只影响当前工具请求。
- `workspace.list`：列出主机指定目录；Windows 可用 `path: "@roots"` 列出可用磁盘。目录项包含名称、完整路径、类型、大小及修改时间。
- `workspace.read`：读取指定主机文件。文本文件预览上限 1 MiB；常见图片和 PDF 预览上限 15 MiB。图片/PDF 以 Base64 返回，其余文本以 UTF-8 返回。
- `workspace.write`：保存不超过 1 MiB 的文本修改。
- `workspace.mkdir`：在指定目录创建一级文件夹。
- `workspace.select`：设置当前工作目录与会话范围 `directory` 或 `all`。默认按该目录加载会话；全局范围跨目录读取近期会话，新建会话仍使用当前工作目录。

主机事件：`host.ready`、`host.snapshot`、`session.snapshot`、`command.result`、`command.error`、`host.warning`。消息均使用版本 1 JSON envelope。客户端会按会话序号丢弃旧事件；检测到序号缺口时自动重新请求当前会话快照。序号只保存在内存中，仍不提供离线事件重放和命令去重。`command.error` 同时返回 `code`，当前包括 `attachment_error`、`agent_unavailable`、`invalid_state`、`transport_error` 和 `internal_error`。

## Codex 交互边界

Codex 桌面版与桥接分别拥有独立 app-server 进程。桥接可以读取同一工作区中已保存的桌面会话，但无法接管桌面版进程已经挂起的 `item/tool/requestUserInput` 或审批请求。跨进程探针确认，桥接入队的消息可被另一进程的活动轮次消费；同一探针中桥接读取会话设置成功，但 `thread/settings/update` 返回 `thread not found`。这不是桌面 GUI 已展示队列或可跨进程改模型的证明。可选项目级 `PermissionRequest` hook 可将**新触发**的审批转给桥接，网页允许或拒绝；无网页连接、超时或桥接不可用时，hook 不作决定，Codex 继续桌面端审批。外部会话的文字选择题通过保守的格式识别生成网页选项，提交结果只进入原会话队列，不作为原生提问协议响应。外部桌面会话通过 `thread/turns/list` 加载历史，再通过 `thread/items/list` 定时补齐最新轮次已落地的条目；本桥接创建的轮次还会根据 app-server 的消息、命令输出和推理摘要增量更新，失败轮次的错误也会显示在对话中。网页中的待处理提醒为站内提示，不是浏览器或系统推送。

Codex 适配不只有队列。RemoteAISync 创建的 Codex thread 归桥接 app-server 控制，使用官方 thread/start、thread/resume、turn/start、turn/steer、turn/interrupt、审批及用户输入请求，可以执行和实时接收响应。对于已有桌面 thread，桥接 app-server 是另一个独立进程：可读会话并通过官方 thread/queue/add 提交待处理输入，不能据此推断桌面客户端拥有的活动 turn、模型设置或等待中的请求已转交给桥接。Codex CLI 当前版本可用 app-server generate-json-schema --experimental 生成该接口版本的 schema；排队方法和 turn 控制方法都存在于 schema，但是否在桌面 UI 显示/消费需要单独实测。

## Agent 接入方式

- OpenCode：本机 OpenCode Server 的 HTTP API 与 /api/event SSE 流。官方 OpenCode SDK 提供等价的类型化客户端；当前 Dart 主机使用同一 Server API 合约，不通过日志解析来发送或运行任务。
- Codex：官方 Codex app-server JSON-RPC over stdio。RemoteAISync 创建的会话由该 app-server 直接运行；外部桌面会话读取 rollout/app-server 数据、排队发送。桌面版已有请求的跨进程认领没有被当前接口路径证明。
- Claude Code：当前通过官方 CLI 的 print/stream-json 模式启动与恢复任务，并读取官方本地 JSONL transcript；两者不会接管一个正在另一个 CLI/Desktop 窗口运行的会话。Anthropic 官方 Remote Control 文档支持从 CLI/Desktop/VS Code 显式开启并在 Claude 官方网页/移动端继续本机运行的会话，但公开文档没有提供第三方控制 API；不能把未公开的 Remote Control 协议当成可依赖的集成接口。

文件审批请求本身通常只有 `itemId` 和理由，可选 `grantRoot`。桥接优先用 `item/fileChange/patchUpdated` 与文件变更项展示对应路径、补丁及写入目录；若没有单项补丁，则显示 `turn/diff/updated` 提供的整轮累计差异，并标明可能包含其他修改。两种差异都未收到时，提示用户在电脑端核对后再审批。

Codex 会话发现使用 `thread/list` 游标，当前工作区最多读取最近 200 条；Windows 路径写法不一致且精确过滤无结果时，回退扫描全局最近 500 条并按规范化路径筛选。自动刷新短时缓存列表，手动 `session.refresh` 绕过缓存。更早的历史会话仍需后续分页 UI。

## 安全边界

- 直连主机仅允许回环和私有 IPv4 客户端连接。首次配对邀请短时有效且单次使用；设备 token 按设备持久化，撤销时强制关闭该设备的连接。中继管理密钥不离开中继管理端，注册码单次使用并签发房间级凭据。
- 中继目前是应用层 WebSocket 转发，服务器端可接触转发的协议明文。公网部署必须使用 WSS/TLS 反向代理并限制访问；不可把明文 `ws://` 直接暴露给互联网。中继不承载 WebRTC 媒体或 TURN 流量。
- 可选 Codex hook 通过回环地址向 `/codex-hook/approval` 发请求，使用独立于手机配对令牌的随机 token。运行时配置保存在当前用户的本地应用数据目录，不放在 Agent 工作区；请求仅在已配对网页客户端在线且项目会话匹配时转发，最多等待 5 分钟。
- WebSocket 控制消息不超过 1 MiB，且必须为 JSON 文本。
- 主机只执行已定义的会话和工作区命令，不运行客户端发送的任意程序或命令。工作区命令需先完成配对，目录权限受主机操作系统账户约束。
- 每个上传块最多 512 KiB；单文件无固定 20 MiB 限制。每个连接最多同时进行 4 个上传，每条消息最多引用 20 个已完成附件。
- 上传仅限已配对且选中会话的客户端，附件 ID 绑定到该连接和会话；文件名净化后写入当前工作区的 `.remoteaisync/inbox/`。主机不会自动执行上传的文件。完成的文件保留在该目录，由用户自行清理。

## 后续协议

- 附件断点续传、上传进度 UI、历史附件预览和更丰富的 Agent 原生文件输入。
- Claude Code 原生提问与审批的远程处理、CLI 收发实机验证；Codex 桌面版反问、已挂起请求的接管及审批 hook 实机兼容性验证。
- 程序唤起；单程序窗口 WebRTC，不做全屏桌面投屏。接口和信令边界见 [`screen-streaming.md`](screen-streaming.md)。
- IPv6 直连及断线事件重放。
