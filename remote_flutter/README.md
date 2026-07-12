# remote_flutter — LAN Media Wall 遥控端 (controller)

**播放列表编排**：在线设备状态中的 `active_playlist` 是独立于 `cache` 的有序节目单。编排栏可载入单台设备的节目单、上移/下移或删除项目，再单播应用回该设备；删除节目单项目不会删除盒子上的缓存文件。

LAN 媒体墙的 Flutter 遥控端。连接 broker、查看设备墙、下发播放控制。严格遵守
[`../protocol_spec.md`](../protocol_spec.md) v1 合同。

> **当前版本 `1.14.7+55`**(`pubspec.yaml`)。CI 从 pubspec 派生 `flutter build apk --build-name=<pubspec name> --build-number=<pubspec code>` 把版本号烧进 APK;播放端 `build.gradle.kts` 也从同一行派生,改 pubspec 即全端同步。发版流程见根 README。
>
> **v1.14.7**:根据 QZX_C1 真实现场包修复诊断误判：daemon 的 `ps` 捕获不再被 8 KiB 截断，BAT 保存完整 `ps` 后解析 PID；双击窗口即使中途命令失败也会保持打开。A/B 每轮清空独立日志窗口并校验实际启动 backend，daemon 非零结果不再触发第二次 fallback 重启，避免旧 Exo 日志冒充 MediaPlayer 对照。控制端功能无改动。
>
> **v1.14.6**:收紧 QZX 重启验收：必须由真实 daemon worker 单次执行且返回成功，force-stop 成功并观察到新 PID，随后同时满足 PROCESS_UP 与 ACTIVITY_RESUMED；daemon 缺失、worker 非零、旧 PID 未变化均失败。另包含 v1.14.5 的发布资产清单修正，确保一键真机 `qzx_field_check.bat/.sh` 与守护进程一起进入 Update Tools ZIP；同时包含 v1.14.4 的 root daemon `RESTART_APP` 改为确定性「验证-重试」状态机,区分 PROCESS_UP 与 ACTIVITY_RESUMED(仅进程回来但活动没到前台=部分失败,不算恢复),重启证据日志给出显式 `restart_verified`/`restart_failed` 终态;新增一键真机 `scripts/qzx_field_check.*`(重启双信号验证 + ExoPlayer/MediaPlayer A/B)。控制端功能无改动,版本随全端 pubspec 同步递增。
>
> **v1.14.2**:Android 被控端新增原生 `android.media.MediaPlayer` 视频内核,与 ExoPlayer 可 A/B 切换(`status.video_backend` 上报当前内核);控制端本身无功能改动,版本随全端 pubspec 同步递增。
>
> **v1.13.11 出站投递可观测**:`P2pCoordinator._sendTo` 成功写入活连接时记一条 `msgId` + payload 摘要(`playlist_id`/`items` 数/`start_index`/`prepare_id`/`group_id` 等对账锚点),`send()` 记扇出结果 `delivered/targets`。过去只在「未连接/无目标」失败分支记日志,推送成功但播放端黑屏时控制端日志一片空白,无法比对「控制端以为发了什么」vs「播放端 player.log 实际收到/播了什么」。日志汇入既有 `logLines`,设置页可一键复制。此改动仅加日志,不改协议与投递语义。
>
> **v1.13.9 P2P 拓扑根因修复**:历史设置若保存了服务端监听地址 `0.0.0.0` / `::`,控制端曾把它当作远端 Broker 并无限重连,即使 UDP 已发现盒子也不会进入 P2P。现在加载/保存时自动清除此类地址,发现后正常直连；Broker 未连接的命令返回失败,分组与设备配置操作显示明确错误而非静默丢弃。
>
> **v1.13.8 P2P 安全与可观测性修复**:组/设备目标匹配为空时不再回退广播全部直连设备,而是零投递并向 UI 显示失败;同步起播零目标直接终止。P2P 协调端新增 `update_status` 消费并接入 `WallState`;Broker wall 快照中的 `update_state/update_detail/update_version_code` 也由 `DeviceStatus` 解析并汇入同一 UI 状态缓存,两种拓扑的升级下载/安装结果都不再丢失。Windows `ready` 回显 `prepare_id/group_id`,使 P2P 三段握手能关联并下发 `play_at`。
>
> **v1.13.7**:播放端 HOME/桌面绑定根因修复——把 `category.HOME` 从 activity-alias 迁到真 Activity(`MainActivity`),遥控物理主页键在 QZX_C1/HiSTBAndroidV6(4.4)上真正回到媒体墙;删除设置页「设为桌面」开关。控制端本身无功能改动,版本随全端 pubspec 同步递增。
>
> **单台设备面板(v1.13)**:设备墙里单击一台盒子的详情弹窗,除改名/设组/音量/推送升级外,新增只针对**这一台 `deviceId`** 的:①**单台播放控制**——暂停/恢复/停止(`WallState.pause/resume/stop(deviceId:)`);②**单播推送内容**——上传+下发 playlist/prepare-play 只锁这一台;③**状态/版本一览**(`_DeviceStatusView`)——展示 `DeviceStatus` 的应用版本(`appVersion`)/在线相位/当前播放项/缓存态/组/音量;④**restart 按钮**(带二次确认)——下发 `restart` 命令**只重启播放 App**,协议 `Commands.restart` + `WallState.restart(deviceId:)`,被控端 `PlayerService` 走命令白名单 `hRestart` 分支并向 root daemon 派发 `RESTART_APP`;整机 `REBOOT` 是独立高风险命令。
>
> **远程诊断日志包 + 可复制调试快照(v1.13.5,端到端闭环).** 单台设备详情弹窗「下载日志」现在导出排障包而不是临时 player.log:播放端 `download_logs_result` 包含版本/网络/传输/播放态/cache/errors/helper/root/update 探针、helper uid/usage、player.log/rotated tail 与可读 logcat tail;控制端保存前再追加 controller_summary/controller_log,优先落到 Android `Download/LANMediaWall/logs` 或桌面 `~/Downloads/LANMediaWall/logs`。调试快照不再只 toast,改为可选择文本对话框并提供「复制全部」。broker 模式下 broker 必须转发请求和回包;P2P 模式下 `P2pCoordinator` 必须把两类回包喂回 `WallState` 的相同回调。缺任何一跳都会表现为按钮超时。
>
> **peer 身份归一 · 根治黑屏+双卡(v1.11.0,关键)**:扫码/手动添加的盒子无真实 `device_id`,`P2pCoordinator` 用拨号端点 `host:port` 当占位 key 建连;盒子 `welcome`/`status` 上报的**真实 device_id** 走另一命名空间 → `connectedIds` 与 `WallAggregator`/`GroupExpander` 对不上 → 组扇出恒空、握手目标集是占位 key、播放端 `ready` 带真实 id 匹配失败 → **`play_at` 永不下发 → 黑屏**;设备墙还会出「占位卡+真实卡」两张。修复:连接拿到真实 device_id 后把 `_links`/`_subs`/`_peers` **从占位 key 重绑定到真实 id**(打印 `身份归一: host:port → <id>`),`setPeers` 改按端点对账避免误断重拨,`WallState` 把占位卡折叠进真实卡(**同一盒子只剩一张卡**)。归一后组目标应正常命中;若仍为空,v1.13.8 起明确失败而不广播。回归见 `test/p2p_coordinator_test.dart`。
>
> **P2P 目标匹配合同(v1.13.8,关键)**:`GroupExpander` 仍容忍 group 前后空格和大小写,但无法匹配目标时必须返回零投递;`startSync` 与普通 `send(group:...)` 都禁止扩大到全部设备。控制层把零投递转为可见错误,诊断日志保留 `connected / 各设备 group_id / targets` 便于定位分组或身份漂移。
>
> **播放编排两个按钮(去歧义,v1.10.3)**:`①仅下发缓存 (不播)` = 只把媒体推到各盒子本地缓存、不播放;`②推送并播放` = 下发列表+预缓存+等全员就绪后统一起播(这就是"推送并播放")。「预缓存就绪 N/M」= M 台目标里有 N 台已把本次列表全部缓存校验完成;盒子未收到 prepare 时不会下载,故会一直停在 0/M。

> Dart 包名仍是 `remote_flutter`(改包名会波及所有 import),但装到手机上的**应用显示名是「媒体墙遥控」**:CI 在 `flutter create` 生成 `android/` 后向 `AndroidManifest.xml` 的 `<application>` 注入 `android:label`(见 `../.github/workflows/flutter-build.yml`),不动 pubspec name。

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
     （需 Android `CAMERA` 权限 + `minSdkVersion 21` + `compileSdk 35`——后者是
     mobile_scanner 传递依赖 CameraX 1.3.1 的 AAR metadata 要求 `>=34`；三者均由
     CI 生成 `android/` 后注入，见 `.github/workflows/flutter-build.yml`）；
  3. **手填 / 粘贴**：邀请页粘贴 `lmw://pair` 链接或手填协调端 host。
- **设备墙即时可见性（§14.5）**：发现 / 扫码 / 手填的设备**立即以占位卡出现**，
  显示接入态（已发现 / 连接中 / 已连接 / 失败+原因），用 `device_id` 去重，WS 回传的
  `DeviceStatus` 覆盖占位——不再"正在添加却看不到设备"、不再静默吞掉连接失败。
- **远程更新固件（§23，v1.10）**：设备墙动作条「远程更新固件」→ 选 APK →
  broker 模式上传到媒体库（可填 `media_upload_token`），P2P 模式启动控制端本机临时 HTTP 服务 → 选择全部 / 分组 / 单台目标 →
  填目标 `versionCode` → 下发 `update_app`。被控端四护栏二次校验（已鉴权+版本严格更新
  或 P2P 本地链路授权 + 版本严格更新 + sha256 + 同签名）。

## 目录结构

```
lib/
  main.dart                 # 入口 + Provider 注入 + 底部导航(设备墙/控制/设置)
  protocol/
    envelope.dart           # 信封 + HMAC 签名/校验 + canonicalJson + uuid4(已与 broker 对齐)
    messages.dart           # 各消息类型 Dart 模型 + Commands payload 构造器
  net/
    broker_client.dart      # WS 长连接、重连、hello/welcome、入站分发、thumb_meta+二进制帧配对
    discovery.dart          # UDP 8772 discover/announce:启动即周期广播(修自动发现)+ 子网定向广播 + 清单持久化
    media_upload.dart       # 本地媒体上传(§20 A+B):sha256 流式摘要、broker 媒体库 PUT、控制端临时 HTTP 服务
  state/
    wall_state.dart         # ChangeNotifier:设备墙状态/连接态/缩略图/出站命令/上传编排/预缓存栅栏/远程更新(§23)
  p2p/
    p2p_coordinator.dart    # 无 broker 时遥控端兼任协调端:多 WS 直连、逐台接入态上报、栅栏长超时
  ui/                       # 横屏平板为主场景(docs/controller-ux-redesign.md §4)
    responsive_shell.dart   # 外壳:≥900dp 双栏并置(设备墙|编排),窄屏底部导航降级 + 顶部状态条
    device_wall_pane.dart   # 设备墙栏:设备卡(缩略图/相位/缓存态)+ 分组管理(新建/改/删)+ 配置盒子(§19)+ 远程更新固件(§23)
    orchestration_pane.dart # 编排栏:选组/编列表(本地上传+URL)/预缓存栅栏进度/一键同步起播/传输/音量/出声台
    invite_screen.dart      # 邀请/添加设备:扫码(mobile_scanner)/粘贴/手填三层入口(以对话框弹出)
    settings_screen.dart    # 设置 + 诊断日志(以对话框弹出)
test/
  envelope_test.dart        # HMAC 签名往返 + canonicalJson 与 §3 一致性
  messages_test.dart        # 消息序列化/反序列化往返
  p2p_group_test.dart       # GroupExpander 扇出;含 v1.10.5 回归:group_id 漂移
                            # (空格/大小写/空 gid)容忍,防"推图算出 0 台"复发
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
