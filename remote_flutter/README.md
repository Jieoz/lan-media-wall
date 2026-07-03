# remote_flutter — LAN Media Wall 遥控端 (controller)

LAN 媒体墙的 Flutter 遥控端。连接 broker、查看设备墙、下发播放控制。严格遵守
[`../protocol_spec.md`](../protocol_spec.md) v1 合同。

## 功能

- **设备墙**：每台设备一格，显示在线灯、当前文件名、播放进度（`位置/时长` mm:ss）、
  音量/静音/出声台标记、当前帧缩略图（§5.2 / §6.4）。
- **控制面板**：选分组；编辑 playlist（单文件 / 多文件轮播，图片设 `duration_ms`）；
  `cache_prefetch` 预缓存；一键同步播放（下发 `playlist` + `prepare`，由 broker 收齐
  `ready` 后广播 `play_at`，§9.1–9.2）；`pause/resume/stop/next/prev`；
  `set_volume`/`set_mute`（整组）；`set_audio_master`（多选出声台）；`assign_group`（改分组）。
- **设置**：broker 地址 / 端口 / WSS 开关、PSK、`controller_id`，均持久化到
  `shared_preferences`。
- **网络**：WS(S) 长连接 + 指数退避重连（1s→30s，§1）；HMAC-SHA256 信封签名/验签（§3）；
  UDP `8772` 设备发现（`discover` 广播 + `announce` 接收，带签名校验，§7）。
- **入组三层入口（§15，均汇流到 `addDeviceFromPairUri` 同一路径）**：
  1. **自动发现**：UDP `announce` 到的设备直接进设备墙；
  2. **扫码**：`mobile_scanner` 真·摄像头扫被控端出示的 `lmw://pair?...` 二维码
     （需 Android `CAMERA` 权限 + `minSdkVersion 21`，由 CI 生成 `android/` 后注入，
     见 `.github/workflows/flutter-build.yml`）；
  3. **手填 / 粘贴**：邀请页粘贴 `lmw://pair` 链接或手填协调端 host。
- **设备墙即时可见性（§14.5）**：发现 / 扫码 / 手填的设备**立即以占位卡出现**，
  显示接入态（已发现 / 连接中 / 已连接 / 失败+原因），用 `device_id` 去重，WS 回传的
  `DeviceStatus` 覆盖占位——不再"正在添加却看不到设备"、不再静默吞掉连接失败。

## 目录结构

```
lib/
  main.dart                 # 入口 + Provider 注入 + 底部导航(设备墙/控制/设置)
  protocol/
    envelope.dart           # 信封 + HMAC 签名/校验 + canonicalJson + uuid4(已与 broker 对齐)
    messages.dart           # 各消息类型 Dart 模型 + Commands payload 构造器
  net/
    broker_client.dart      # WS 长连接、重连、hello/welcome、入站分发、thumb_meta+二进制帧配对
    discovery.dart          # UDP 8772 discover/announce + 设备清单持久化
  state/
    wall_state.dart         # ChangeNotifier:设备墙状态/连接态/缩略图/出站命令
  p2p/
    p2p_coordinator.dart    # 无 broker 时遥控端兼任协调端:多 WS 直连、逐台接入态上报
  ui/
    wall_screen.dart        # 设备墙(合并发现/已连的统一视图 + 占位卡 + 接入态)
    invite_screen.dart      # 邀请/添加设备:扫码(mobile_scanner)/粘贴/手填三层入口
    control_panel.dart      # 控制面板
    settings_screen.dart    # 设置 + 诊断日志
test/
  envelope_test.dart        # HMAC 签名往返 + canonicalJson 与 §3 一致性
  messages_test.dart        # 消息序列化/反序列化往返
```

## 安装与运行

需要 Flutter SDK（`>=3.10.0`，Dart `>=3.0.0`）。

```bash
cd remote_flutter
flutter pub get          # 拉依赖
flutter analyze          # 静态检查
flutter test             # 跑单元测试
flutter run              # 在已连接的设备/模拟器上运行
```

> 本目录是纯 Dart/Flutter 包，尚未生成各平台壳工程（`android/`、`ios/` 等）。
> 首次在真机/模拟器运行前，先执行 `flutter create .` 生成平台目录，再 `flutter run`。
> `flutter pub get` / `flutter analyze` / `flutter test` 不需要平台目录即可运行。

## 首次使用

1. 打开 app → 「设置」页，填入 broker 地址（如 `192.168.1.10`）、端口（WS 默认 `8770`）、
   与全系统一致的 **PSK**，保存并重连。
2. 回到「设备墙」，等待 broker 推送 `welcome`/`wall` 快照后即可看到各设备。
3. 「控制」页选分组，编辑 playlist 并下发或一键同步播放。

## 与协议的对接要点

- 所有出站命令经 `EnvelopeCodec.build` 签名；所有入站文本帧经 `verify`（签名→时效→去重）
  后才分发。`canonicalJson` 与 broker 的 `json.dumps(sort_keys=True,
  separators=(",",":"), ensure_ascii=False)` 逐字节对齐（见 `envelope.dart` 注释与
  `test/envelope_test.dart`）。
- 路由 `to`：单机命令 → `player:<device_id>`，整组命令 → `group:<group_id>`，
  其余 → `broker`，由 broker 负责最终扇出（§2/§9）。
- 缩略图：`thumb_meta`（JSON）之后紧跟一个二进制帧；`BrokerClient` 按到达顺序配对（§6.4）。
