# 被控端(TV)体验重做 — 设计决策定稿 v2

> 面向"电视盒子被控端"的产品方向定稿。被控端是**电视盒,无触摸、无摄像头**,遥控器打字是酷刑。
> 一切围绕"零输入、开机自己上墙、一眼可核对"设计。此文件是给实现方(含 CC)的**设计合同**。

## 1. 配对方向反转(根因:扫码不该在被控端)
- **删除**被控端摄像头扫码:PairingScanActivity + CameraX + CAMERA 权限 + camera-*/zxing-camera 依赖全砍。
- 改为:**被控端屏幕显示自己的二维码/连接信息**(本机 IP、device_id、组名),**手机遥控端扫屏纳管**。手机有摄像头有触摸,天然是扫码的一方。
- 二维码语义:被控端出的是"纳管入场券",编码本机 IP + device_id + group(+ 可选 mode)。

## 2. 零配置首启(根因:强制手输 broker 堵死了自动发现)
- 首启**不再强制手输 broker**。传输层本就有"自动发现协调者→超时进 P2P 兜底"(见 DiscoveryDecision/selectAndStartTransport),此前被首启 UI 堵死,放开它。
- 首启页**大字显示**:本机 LAN IP(有线/WiFi 各自出口网卡)、device_id、发现状态(找到 broker / P2P 待连)、组名 → 一眼可核对、可验证。
- 手输 IP 仅作发现失败兜底,不是前置门槛。

## 3. 全中文界面(根因:仅英文资源)
- 新建 values-zh-rCN/strings.xml,首启/状态/按钮全中文;默认 locale 跟随系统。

## 4. 开机自启修复(根因:BootReceiver 调了高版本 API)
- BootReceiver 无脑调 startForegroundService = **API 26+ 才有**,低版本开机自启直接崩。
- 改为按 Build.VERSION.SDK_INT 分支:<26 走 startService,>=26 才 startForegroundService。

### 4.1 双模式自启（两条路互斥，默认只开模式1，永不同时生效）
**模式1 = BootReceiver 自启（默认，推荐）：**
- Manifest 声明 RECEIVE_BOOT_COMPLETED 权限 + BootReceiver 监听 android.intent.action.BOOT_COMPLETED。
- 开机 → 系统拉起盒子原桌面 → BootReceiver 后台拉起 PlayerService → Activity 弹前台全屏播放，与原桌面共存不冲突。
- 4.4 素系统 AOSP 原生支持，不拦自启、无 Doze，比现代品牌 ROM 更稳。

**模式2 = 注册为 Launcher/HOME（兵底，设置里开关，默认关）：**
- MainActivity 可选加 category HOME + DEFAULT 的 intent-filter，但默认注释掉或用 activity-alias 可切换，由首启页/设置的设为桌面开关启用。
- 启用后开机系统找默认桌面；若有两个桌面（原桌面+本App）系统弹选择桌面框，选始终锁定本App。这是二选一，不是两个自启打架。
- 仅当模式1 在某盒 ROM 失灵才手动开；适合死磕 kiosk。
- 关键：两模式互斥—默认只模式1，模式2 需手动开，绝不出现两个自启冲突。

### 4.2 装后首启说明（写进 README + 首启页中文提示）
- 安匓3.1+ stopped-state 规则：APK 装后处于 stopped，从未被手动打开过就收不到 BOOT_COMPLETED。流程必须：装 → 手动打开一次（完成首启配对）→ 之后开机才自启。首启页中文明确提示。
- APK 必须装内部存储，装 SD 卡收不到开机广播（adb install 默认内部，OK）。
- README 给 ADB 验证提示：`adb reboot` 后 `adb logcat | grep BootReceiver` 看到日志=自启成功。

## 5. 网络层(有线 + WiFi 双栈)
- 默认**纯 WS**(内网),WSS 仅可选,不因老设备 TLS 握不动而阻断。
- UDP 发现在有线/WiFi 双网卡下都要正确取到出口 IP 并显示。

## 6. minSdk / 目标设备(已锁定,2026-07 Jay 决策)
- **锁定 minSdk=19 (Android 4.4.2)**。采购渠道(1688 外贸盒)拒绝确认系统版本/插头,换设备不确定性太高,Jay 决定按现有 4.4 硬件做软件,不再纠结换盒。
- **用途单一**:纯内网 kiosk 组播播放,**只放 1080p H.264**(老芯片够解,H.265/4K 不在范围)。
- **Jay 卡在"安装装不上"的根因 = 现 minSdk=24**,APK 在 4.4 报 INSTALL_FAILED_OLDER_SDK。降到 19 重编即可安装。
- 技术栈降级链(必做):
  | 层 | 降级 |
  |---|---|
  | minSdk | 24 -> **19** |
  | 播放内核 | media3 1.4 -> **ExoPlayer 2.19.1**(2.x 末代,吃 API16+) |
  | 网络库 | okhttp 4.12 -> **3.12.x**(最后支持 <21) |
  | 加密存储 | EncryptedSharedPreferences -> **明文 SharedPreferences**(内网降安全) |
  | 扫码库 | CameraX/zxing-camera **整组删除** |
  | 语言级 | 开 **coreLibraryDesugaring**(用到 java.time/stream 才不崩) |
  | 开机自启 | §4 的 Build.VERSION 分支(<26 startService) |

### 6.1 API 19 特有暗坑(不处理就装不上/跑不起,必须逐条落地)
| 暗坑 | 后果 | 处理 |
|---|---|---|
| **APK 签名必须含 v1(JAR)签名** | v2-only 签名在 <7.0 装不上("应用未安装") | minSdk 19 时 AGP 默认带 v1;确认 signingConfig 未关 v1,CI 产物核对 |
| **启动图标只有 adaptive-icon** | 4.4 无 adaptive icon,图标空白 | 补传统 PNG mipmap(mdpi/hdpi/xhdpi)兜底 |
| **UDP 发现要 MulticastLock** | WiFi 下 4.4 过滤广播/组播,announce 收不到(有线不受影响) | PlayerService 取 WifiManager.createMulticastLock().acquire(),停止时 release |
| **networkSecurityConfig XML** | API24+ 才认,4.4 直接忽略 | 无害;4.4 默认允许明文,纯 WS/HTTP 正常 |
| **WSS/HTTPS 现代证书** | 4.4 老 TLS 握不动现代证书 | 内网走**纯 WS + HTTP**,绕开(见 §5) |
| **coreLibraryDesugaring 关闭时用 java.time/stream** | VerifyError/崩溃 | build.gradle 开脱糖 + 依赖 desugar_jdk_libs |
| **前台服务通知渠道 API** | NotificationChannel 是 26+ | 通知构建按 Build.VERSION 分支,4.4 用旧构造 |

## 7. 安全声明(内网降级)
- 内网场景:PSK 明文存储、默认 auth_mode=open(零配置直连)。公网会是漏洞,**仅限内网**——写进 README 与首启页提示,防误用到公网。

## 验收边界(给 CC)
- Android 端**不在容器内跑 gradle/flutter**;编译验证走 **GitHub Actions 云编译**(push tag/commit 触发 android-build.yml)。
- 容器内 Android 自检仅限源码级:import 解析、引用的 layout/strings/资源 id 存在、无明显类型错、Manifest 注册齐全。
- Flutter 遥控端改动同理,源码级自检 + 云 CI。
