# 单窗口画面推流接口契约

本文定义后续单应用窗口推流的模块边界，不代表当前版本已经实现屏幕采集、WebRTC 或远程输入。

## 设计边界

- 只采集用户明确选择的一个应用窗口，不提供全屏桌面捕获作为默认路径。
- 主机本地必须显示采集中的窗口名称和停止入口；窗口关闭、权限撤销或主机锁屏时结束或暂停会话。
- 现有 RemoteAISync WebSocket 只传控制信令和状态，不传视频帧。
- WebRTC 承载实时视频，优先 P2P；ICE 无法建立直连时，可配置独立 TURN 服务转发媒体。
- RemoteAISync Relay 保持现有消息路由职责，不接收、检查或保存视频帧。公网信令使用 WSS；WebRTC 媒体链路使用 DTLS-SRTP。
- v1 只做单向画面查看。鼠标、键盘和远程控制是单独授权的后续能力，不因打开画面而默认启用。

## 模块接口

主机核心依赖平台无关的 `WindowCaptureProvider`，平台实现负责枚举窗口并创建采集会话：

```dart
abstract interface class WindowCaptureProvider {
  Future<List<CaptureSource>> listSources();

  Future<WindowCaptureSession> startCapture({
    required String sourceId,
    required CaptureProfile profile,
  });
}

abstract interface class WindowCaptureSession {
  CaptureSource get source;
  Stream<CaptureState> get states;
  Future<void> updateProfile(CaptureProfile profile);
  Future<void> stop();
}
```

`CaptureSource` 只暴露不敏感的展示信息（稳定期内的 source ID、窗口标题、进程名、预览尺寸）；不得把 HWND、PID 等平台句柄发给客户端。`CaptureProfile` 提供分辨率上限、帧率上限和画质档位。平台原生帧和编码资源由平台媒体适配器持有，不跨 Dart 通道逐帧复制 RGBA 图像。

`ScreenStreamCoordinator` 编排授权、采集生命周期和 WebRTC 会话；它依赖 `WindowCaptureProvider` 与 `ScreenMediaTransport`，不直接依赖 Win32、PipeWire 或 Flutter widget。

```dart
abstract interface class ScreenMediaTransport {
  Future<ScreenMediaSession> createSession({required String sessionId});
}

abstract interface class ScreenMediaSession {
  Stream<ScreenMediaState> get states;
  Future<ScreenSignal> createOffer(WindowCaptureSession capture);
  Future<void> acceptSignal(ScreenSignal signal);
  Future<void> close();
}
```

以上类型是接口契约草案；真正接入时在 `host/lib/src/screen/` 和客户端 transport 层落地，并以端到端测试固定生命周期行为。采集后端和 WebRTC 库不能依赖 UI 层。

## 信令消息

信令沿用现有 WebSocket envelope，新增独立的 `screen.*` 命令和事件。信令含 `requestId`、`streamId`、`sessionId` 与版本号；ICE candidate 采用 trickle ICE，候选队列有上限并在会话结束后清空。

```json
{
  "kind": "screen.stream.start",
  "payload": {
    "sessionId": "agent-session-id",
    "sourceId": "opaque-window-id",
    "profile": { "maxWidth": 1280, "maxHeight": 720, "maxFps": 15 }
  }
}
```

```json
{
  "kind": "screen.signal",
  "payload": {
    "streamId": "stream-id",
    "signalType": "offer | answer | ice-candidate | end-of-candidates",
    "description": "optional SDP",
    "candidate": "optional ICE candidate"
  }
}
```

主机先返回可用 source 列表；收到 `screen.stream.start` 后必须检查设备已配对、会话归属和本机授权，再打开指定 source。`screen.stream.stop`、设备撤销、Agent 会话关闭、采集窗口消失和传输断开都必须可幂等地结束资源。客户端收到的状态只报告 stream ID、所选窗口的显示标题、连接阶段、当前媒体路线、分辨率、帧率和 RTT，不报告桌面其他窗口。

## 平台后端

- Windows：优先实现原生 Windows Graphics Capture 窗口 source，并使用系统窗口选择和采集指示。Dart 主机运行时通过独立原生媒体适配器接入，避免每帧经过 Flutter UI isolate。
- Ubuntu：Wayland 下通过 XDG Desktop Portal ScreenCast 获取用户授权的 source 和 PipeWire 流；不得绕过 portal 静默捕获。X11 可另做显式授权的后端。无图形会话或 portal 不可用时，能力状态应显示不支持及原因。
- Android/Web：Flutter 客户端使用同一信令和 WebRTC receiver；浏览器还需满足 HTTPS 安全上下文要求。

## 分阶段验收

1. 能枚举/选择单个窗口，拒绝授权、窗口退出和主机锁屏均能正确结束。
2. 同一局域网建立 WebRTC P2P，验证延迟、帧率、重连与资源释放。
3. 通过 WSS 中继交换信令，WebRTC 媒体仍直连。
4. 在受限 NAT 下配置 TURN 并验证媒体 relay；TURN 凭据短时签发，不复用 RemoteAISync 房间 token。
5. 验证公网 relay 无法观察视频帧，只有 WSS 信令元数据和 TURN 必需的媒体转发。
