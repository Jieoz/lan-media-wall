# Changelog

All notable changes to this project are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/); versions are git tags that trigger CI cloud-builds and Release artifact attachment.

## [v1.12.0] — 2026-07-07

### Added
- **P2P 缩略图**: 把 `thumb_meta`(JSON 文本帧)+ 紧跟二进制 JPEG 帧的两帧配对逻辑抽成共享纯 Dart `ThumbPairing` 状态机(`remote_flutter/lib/protocol/thumb_pairing.dart`),broker 直连与 p2p 直连两路复用同一实现(无分叉)。此前 p2p 路径把 `thumb_meta` 丢进 `default` 分支直接丢弃,是「P2P 看不到设备墙缩略图」的根因。`ws_link` 新增 `binaryStream`(广播流拆 text/binary),`wall_state` 接 `onThumb`。
- **P2P 断线主动重连**: p2p 协调端断线后按指数退避(1s→30s)主动重拨同一端点,连上清退避;重连前检查端点是否已有活连接(去重防双连接),对端从发现列表移除后不再重连。补 `fakeAsync` 单测覆盖「drop→退避→重拨、不双连接」与「已移除端点不重连」。
- **重启后自动恢复播放(Android player)**: `Downloader` 启动时按 last_task playlist 从磁盘按内容寻址文件名(`$sha256.$ext`)重建 ready 索引,`readyPath` 重启后命中本地已缓存文件而非回退到已失效的临时媒体 url。纯读、幂等,不额外写盘。
- **升级入口可发现性(遥控端)**: 顶部远程更新按钮从纯图标 `IconButton` 改为带「更新固件」文字标签的 `OutlinedButton.icon`;单设备详情弹窗新增「推送升级」入口,走同一 `update_app` 流程但 target 预锁定该台(`_remoteUpdateDialog` 加可选 `lockDevice`),协议与下发逻辑不变,仅改可达性。

### Fixed (红线)
- **假容量闪存写安全**: 扩容/假容量盒子 `df` 上报的巨大剩余空间不可信。`CacheEviction.effectiveQuota` 重构为 `min(configuredMax, 保守绝对上限 2GiB)`,空间百分比只能往下收紧、绝不把配额抬到硬上限之上;`Downloader.probeWritable()` 下载前做真实可写探针(小文件写+fsync+读回+删,每 prefetch 批次一次,低频);`Downloader.reclaimOrphans` + `MediaStore.pruneAndListReferenced` 投新内容前主动回收不再被最近 N 条 playlist 引用的孤儿媒体,保护当前 playlist/`.part`/last_task 引用文件不误删。防止持续写穿真实闪存颗粒把盒子写坏变砖。补 `CacheEvictionTest` 假容量钳制/百分比只下调/孤儿保护单测。

### CI
- **修复控制端 release 签名注入**: 生成的 `android/app/build.gradle` 用 `signingConfig = signingConfigs.debug`(带 `=`)的新式写法,但 flutter-build 的签名注入正则只匹配旧的无 `=` 空格写法,导致 release keystore 从未接线、APK 一直被 debug 签名,卡在「Verify APK signing identity」门禁。正则改为容忍可选 `= `,替换文本也用 `=` 形式,固定签名恢复生效(跨版本覆盖升级依赖它)。

## [v1.11.2] — 2026-07-07

### Fixed
- **控制端完全搜不出播放端的 UDP 发现断点**: Android 播放端 `Discovery` responder 构造时已经拿到了实际 `authMode/keyMode`(P2P/零配置为 `open/global`),但处理 `discover` 时调用 `Envelope.verify(...)` 没有把这两个参数传进去,导致实际走默认 `REQUIRED` 验签。控制端零配置发现包是空签名 open discover,因此被播放端静默丢弃,表现为控制端周期广播但设备列表为空。
  - 修复: `Discovery.handle()` 按当前 `authMode/keyMode` 验 discover,open 模式正确接受空签名;同时补 `DROP discovery inbound`、`RX discover`、`TX announce` 与 UDP bind 日志,以后 logcat 能直接看出发现包到没到、为何丢、有没有回 announce。
- **Player APK 文件名版本与包内 versionName 漂移**: `v1.11.1` tag 的 Release 文件名是 `LANMediaWall-v1.11.1-Player-Android.apk`,但 Android player 的 `build.gradle.kts` 仍硬编码 `versionName="1.11.0"` / `versionCode=28`,所以盒子无论怎么覆盖安装,`dumpsys package` 都只会显示 `1.11.0`。
  - 修复: Android player 版本号改为从 `remote_flutter/pubspec.yaml` 的 `version: X.Y.Z+N` 派生,controller/player/tag 使用同一真相源;中文设置页补上 `版本:vX.Y.Z (build N)` 显示。

## [v1.11.1] — 2026-07-07

### Fixed
- **P2P「②推送并播放」ACK 正常但不起播的栅栏透传缺口**: 控制端 UI 已按 §21 调用预缓存栅栏,但 P2P 本地编排路径只把 `readyTimeoutMsOverride=120s` 传给协调器,实际发给被控端的 `prepare` 没有携带 `prefetch:true` / `barrier_timeout_ms`。Android 端因此走普通 prepare 分支:首项未缓存时会立刻 `ready:false`,协调端继续等到超时且无就绪目标,最终不下发 `play_at`；日志表面只有 `playlist/cache_prefetch/prepare/resume` ACK,看起来像“功能异常”。
  - 修复: `Commands.prepare` 支持 `prefetch` 与 `barrier_timeout_ms`; `WallState.prepareWithBarrier` 在 P2P 下通过 `P2pCoordinator.startSync(... prefetchBarrier:true ...)` 透传到被控端。Android 端收到后进入已有后台缓存等待逻辑,缓存完成再回 `ready:true`,随后协调端下发 `play_at`。
  - 诊断增强: 控制端现在记录 `ready:false`、ready 命中数量、未匹配 ready 的 `prepare_id` 与最终 `play_at` 下发日志。以后同类问题不再只剩 ACK 盲区。
  - 回归: 新增协议层 `Commands.prepare(prefetch)` 测试与 P2P 栅栏测试，覆盖“携带栅栏参数”和“ready=false 不应点火”。

## [v1.11.0] — 2026-07-06

### Fixed (CRITICAL — 两个根因,真机 logcat + 控制端诊断逐字确认)

- **推送后黑屏 + 设备墙同一盒子双卡的真根因:peer 身份命名空间从不归一(根治)**。
  扫码/手动添加盒子时控制端没有真实 `device_id`,`P2pCoordinator` 用拨号端点 `host:port`
  (如 `10.10.8.160:8770`)当占位 key 建连接;而盒子 `welcome`/`status` 上报的**真实
  device_id**(如 `and-b87bfc8e49`)走另一命名空间。后果链:`connectedIds` 返回占位 key、
  `WallAggregator`/`GroupExpander` 用真实 id → 组扇出求交集恒为空(只能靠 v1.10.5 兜底硬发
  prepare);握手会话目标集是占位 key,播放端 `ready` 带真实 id → `targets.contains()` 为
  false → **`play_at` 永不下发 → 黑屏**;设备墙同时出现「占位卡(恒连)」+「真实卡(随
  status 时断)」两张。
  - 修复(归一,不在兜底上雕花):连接一旦从帧里拿到真实 device_id(`status`/`ready` 的
    `payload.device_id`,或 `welcome` 的 `from=player:<id>`),就把 `_links`/`_subs`/`_peers`
    的键从占位 key **重绑定**到真实 id(`_maybeRebind`/`_rebind`),打印 `身份归一: 占位 key
    "host:port" → 真实 device_id "<id>"`。归一后 `connectedIds` 与聚合/扇出同命名空间:组扇出
    正常命中(不再靠兜底)、握手目标集用真实 id → `ready` 匹配成功 → **`play_at` 正常下发,
    不再黑屏**。
  - 边界:重绑定去重(真实 id 已有连接则关旧留新)、`setPeers` 改为**按端点(host:port)对账**
    以免把已归一的活连接误断重拨、所有 link 回调用 `_keyForLink` 反查当前 key(不闭包捕获占位
    key)避免孤儿连接。控制端 `WallState` 登记占位→真实别名,`wallDevices` 据此把占位卡折叠
    进真实卡:**同一盒子只剩一张卡**。
  - **v1.10.5「group 匹配为空 → 回退全部已连接」兜底保留**(多组场景 / 归一前窗口期保险),
    归一后正常路径优先命中,不再是唯一能推图的路径。

- **每版必须卸载重装、远程 `update_app` 必失败的真根因:release 签名指纹每版都变(根治)**。
  player 的 `release` buildType 此前用 `signingConfigs.getByName("debug")`,CI 每次用 AGP 临时
  生成的 debug.keystore 签名 → **每版证书指纹不同** → 覆盖安装 `INSTALL_FAILED_UPDATE_
  INCOMPATIBLE` → 只能卸载重装,§23 远程 `update_app` 也必然失败。
  - 修复:player 从 GitHub Actions Secret 解码**固定 keystore** 签名(参照遥控端
    `flutter-build.yml` 的成熟流水线)。`build.gradle.kts` 新增 `release` signingConfig,凭据从
    CI 写出的 `key.properties`(指向 `$RUNNER_TEMP` 的 keystore)读取,release buildType 用它
    替换 debug;保留 v1+v2 签名(minSdk 19 必须 v1)与 R8/minify 不动。`android-build.yml`
    在 build 前 `if` 判断 secret 存在 → `base64 -d` 写 keystore + `key.properties` →
    `assembleRelease`,并回显 signer 证书 SHA256 供真机核对。
  - **无 secret 优雅降级**:fork PR / 本地无 secret 时回退 debug 签名出可安装 APK,构建不失败。
  - **安全**:公开仓,keystore/密码明文绝不入库——只用 `${{ secrets.X }}` 与 `$RUNNER_TEMP`;
    `key.properties`、`*.keystore`、`*.jks` 均 `.gitignore` 排除。固定证书 SHA256 指纹
    `69:EC:70:E5:92:AE:D4:6C:4E:B1:41:2F:E7:66:8F:41:51:46:81:10:1A:CD:0D:D9:DB:B0:98:D1:E2:6D:6D:54`
    (30 年有效)。**装 v1.11.0 后从 v1.10.x 覆盖安装无需卸载,远程 update_app 可覆盖升级。**

## [v1.10.7] — 2026-07-06

### Fixed
- **P2P 直连也能远程更新 APK**: 控制端「远程更新固件」不再限制 broker 模式。broker 下仍上传到 broker 媒体库;P2P/无 broker 下复用控制端本机临时 HTTP 服务生成 APK 下载 URL+sha256,再通过 P2P `update_app` 下发。播放端授权规则同步调整:broker 帧仍需 HMAC 鉴权,P2P 直连控制链路可作为本地操作者授权,但版本严格递增、sha256 校验、同签名平台校验和 root `/data/app` 安装流程不变。
- **P2P 普通下发不再被 group 目标扇空吞掉**: 继 `prepare/startSync` 后,普通 `playlist`、`cache_prefetch`、`set_volume` 等 `send(group:...)` 也加上同样的已连接兜底。真机日志里 `startSync ... targets=[] → 回退到 1 台` 后播放端虽能收到 `prepare`,但前置 `playlist/cache_prefetch` 仍显示 `无目标` 并被丢弃,导致播放端没有媒体清单/下载任务。现在 group 匹配为空但确有直连设备时直接回退到全部已连接,并打印 connected/devices 诊断值。
- **远程自更新 broker 主链路接通**: broker 现在转发 `update_app` 到某台/某组/全部目标,并把被控端 `update_status` 合并进设备墙状态(`update_state/update_detail/update_version_code`),避免控制端下发后被中枢静默丢弃。
- **媒体上传 token 与远程更新兼容**: broker 开启 `media_upload_token` 后,控制端设置页可填写同一 token,本地媒体/APK 上传会带 `Authorization: Bearer ...`;下载仍对被控端开放。
- **远程更新目标补齐单台选择**: 控制端「远程更新固件」支持全部/分组/单台三种目标,并在无可选目标时明确提示。

## [v1.10.5] — 2026-07-05

### Fixed (CRITICAL — 一张图都推不出去的真根因)
- **扫码直连盒子后「推送并播放」零反应**: 真机确认盒子在设备列表里、WS 连上、status/thumb_meta 持续上报,但盒子日志**从无 `RX prepare`**,控制端诊断显示 **`p2p prepare → 0 台`**。根因:`P2pCoordinator.startSync` 用 `GroupExpander.expand('group:<gid>')` 算推送目标,`d.groupId == gid` 严格相等匹配,group_id 任何细微漂移(前后空格/大小写)都会让目标集为空 → 一条 prepare 都不发。
  - 修复①:`GroupExpander` group 比较 `trim().toLowerCase()`,空 gid 视为通配。
  - 修复②(兜底,决定性):`startSync` 若按 group 算出的 targets 为空、但确有已连接被控端,则直接把**全部已直连设备**作为目标——扫码直连一台盒子绝不该因 group 匹配细节而"推图完全没反应"。
  - 修复③:`startSync` 打印决定性诊断 `gid / connected / 各设备 group_id / targets`,下次一眼定位。
- **控制端诊断日志无法复制**: 设置页「诊断日志」新增「复制全部」按钮(一键复制到剪贴板 + SnackBar 回执),单行改 `SelectableText` 可长按选中复制。

## [v1.10.4] — 2026-07-05

### Fixed (CRITICAL — 真机验证驱动)
- **上上下下键崩溃退出软件的真根因**: v1.10.3 的 `openSettings()` 调用 `stopLockTask()`(API 21+),4.4 盒子上 dalvik 解析该方法即抛 `NoSuchMethodError`——**Error 不是 Exception,`catch(Exception)` 拦不住**——导致 openSettings 崩溃、进程被 `Force finishing`,表现为"上上下下退出软件"。logcat 铁证:`E/AndroidRuntime ... MainActivity.openSettings(SourceFile:4)` + `Force finishing activity` + `Process ... has died`。修复:`SDK_INT >= LOLLIPOP` 版本守卫 + `catch(Throwable)` 双保险;`tryLockTask()` 整条 Lock Task 链在 4.4 上整体早返回跳过。
- **遥控主页键回到播放墙**: manifest 启用 HomeAlias 不足以让 4.4 的 HOME 键生效(框架保留 preferred-HOME 关联)。`lmw_provision.sh` 新增设默认 HOME 步骤:`cmd package set-home-activity`(高版本)/ `pm clear-preferred-activity`(4.4 回退,禁用 youku 桌面后唯一启用的 CATEGORY_HOME 目标=播放端被自动选中)。设置页「设为主页」默认勾选。

## [v1.10.3] — 2026-07-05

### Fixed
- **被控端上上下下键不再"退出软件"**: `exitKiosk()` 会 `finish()` 掉唯一的 kiosk Activity,在 YunOS/AliOS 4.4 盒子上导致进程被系统回收,看起来像软件直接退出。改为 `openSettings()`——挂起 kiosk 看门狗 + 用 `REORDER_TO_FRONT` 把设置页压在播放 Activity 之上,不 finish,进设置稳定可靠。左上角连点 7 下同走此路径。
- **遥控主页键(HOME)现在回到播放墙**: `HomeAlias` activity-alias 由默认 `enabled="false"` 改为 `true`,盒子成为 HOME 候选;配合 provision 脚本已禁用的 OEM(youku)桌面,主页键直达播放墙。
- **控制端版本号一直显示 1.10.0**: `remote_flutter/pubspec.yaml` 版本从未随播放端抬升;现同步到 `1.10.3+23`,CI 从 pubspec 动态解析 build-name/number 烧进 APK。

### Changed
- **控制端播放编排按钮文案去歧义**: `下发并预缓存` → `①仅下发缓存 (不播)`;`全员就绪 · 同步起播` → `②推送并播放`(即"推送并播放"就是这个键)。README 说明「预缓存就绪 N/M」含义:M 台目标里 N 台已完成本次列表的下载+校验;盒子未收到 prepare 时不下载,故停在 0/M。

## [v1.10.0] — 2026-07-05

### Added
- **远程自更新 (`update_app`, §23)**: 遥控端选 APK → 上传到 broker 媒体库(得 url+sha256)→ 下发 `update_app` 给某台/某组/全部,被控端自己拉取并 root 安装(`su` 复制进 `/data/app` + reboot,4.4 外贸盒唯一可靠路径),免逐台 adb 刷机。被控端回报 `update_status`(downloading/installing/rejected/failed)。
- **四条安全护栏**: (1) 仅接受**已鉴权**帧(`Envelope.authed`——open/空签名一律拒),(2) `version_code` 必须**严格更新**(防降级/重放),(3) `url`+64 位 hex `sha256` 必填且下载后**重算比对**(不符删文件拒装),(4) 同签名由 Android 平台开机包扫描强制(免额外代码)。
- **控制端 UI**: 设备墙动作条新增「远程更新固件」入口,支持选目标(全部/按组)+ 填 versionCode + 一键上传下发。

### Notes
- 仅内网使用:`update_app` 依赖 `auth_mode`≠`open` + 已配 PSK 才生效;切勿把被控端暴露公网。
- 纯逻辑护栏(`UpdateGuard`)+ 安装命令(`RootInstaller.installScript`)+ `authed` 语义均有 JVM 单测覆盖。

## [v1.9.0] — 2026-07-05

### Added
- **分组增删改 (group CRUD)**: broker/controller 支持 `update_group`/`delete_group`,遥控端可重命名分组、解散分组回收成员到未分组池;registry 落地 CRUD 并广播拓扑变更。
- **设备远程配置 (`configure_device`)**: 遥控端下发 `configure_device` 直接改被控端运行参数(broker host/端口/分组/WSS/密钥),免 adb 上盒子,配合已有的自诊断与重置连接。
- **本地文件上传到媒体库**: controller 通过 broker 媒体库(HTTP PUT/GET,带 Range 断点续传)推本地文件,盒子从 broker 拉取带缓存续传 + sha256 校验;不再强依赖 NAS。
- **预缓存栅栏 (prefetch barrier)**: `prepare` 新增 prefetch 语义与更长的 barrier 超时,多屏在真正 `play_at` 前先把媒体拉全,减少首帧不同步。
- **横屏 UI 重构**: 遥控端设备墙横屏布局重排,适配横向大屏操作。

### Changed
- **版本对齐 1.9.0**: player `versionName 1.9.0 / versionCode 19`;controller `pubspec 1.9.0+19`,`flutter build apk` 传 `--build-name=1.9.0 --build-number=19`。修复 v1.9.0 tag 内部版本号仍烧成 1.8.0 的漂移。

### Verified
- broker + windows_player 全套 pytest 绿(含新增 `test_group_mgmt`/`test_media_server`/`test_configure_and_barrier`)。
- 四端(broker/flutter/android/windows)云编译走同一 tag SHA,GitHub Actions 全绿方视为发布。
- README 同步门槛 `scripts/check_readme_sync.sh` 通过:模块代码改动均有对应 README 更新。

## [v1.8.0] — 2026-07-04

### Fixed
- **未配置被控端不再死连示例 broker (§2)**: `Settings.brokerHost` 默认从硬编码 `192.168.1.10` 改为**空串**;传输选择改以 `hasBroker`(`brokerHost.isNotBlank()`)为准而非 `isConfigured`——broker 留空的盒子先自动发现、发现不到就进 P2P 服务端等遥控端扫码,修复扫码后一直「连接断开」。`SettingsActivity.save()` 无条件写 host(含空、已 trim),使坏 broker 可被清空回自动发现。`192.168.1.10` 仅保留为输入框占位提示。

### Added
- **连接自诊断 (§8)**: 新增进程内 `ConnState`(仿 `KioskState`),`PlayerService` 发布 `STARTING/DISCOVERING/CONNECTING_BROKER/CONNECTED_BROKER/P2P_WAITING/P2P_CONNECTED/DISCONNECTED(+原因)`;设置页每秒刷新,status loop 对账 live link,断线/重连不再显示过期状态。
- **硬件自检 (§5)**: 设置页显示真实 `MemTotal`(读 `/proc/meminfo`)+ `/data` 可用/总容量(`StatFs`),远程截图即可判断盒子硬件。纯展示。
- **挖矿/垃圾包提示 (§6)**: `SystemInfo.scanBloatware` 检测已知预装包(`com.youku.taitan.tv`/`com.youku.cloud.dog` 等,列表常量可扩展),提示手动禁用;不自动卸载/杀进程。
- **重置连接配置 (§9)**: 设置页新增按钮,`Settings.resetConnection()` 清空 broker/端口/WSS/分组/密钥回到未配置态并重启服务重选传输、重显配对二维码;保留设备身份与缓存,免 adb 自救。
- **批量装机脚本 (§7)**: `scripts/deploy_player.sh` 遍历 root 盒子推 APK 到 `/data/app` → chmod → reboot 采纳 → 校验版本,绕开假容量闪存的 `INSTALL_FAILED_INVALID_INSTALL_LOCATION`,支持多设备循环与 `SKIP_REBOOT`/`BOOT_TIMEOUT` 等环境变量。

### Changed
- **退出 kiosk 取消 PIN (§4)**: 暗键手势(左上 7 连击 / 遥控 ↑↑↓↓)命中后**直接退出**,移除 PIN 弹窗与 `kioskExitPin`/`DEFAULT_KIOSK_EXIT_PIN` 等死代码。手势本身不变。
- **控制端应用名 (§3)**: `flutter-build.yml` 在生成 android/ 后把 `android:label` 注入为**媒体墙遥控**(不动 pubspec name / Dart import,副作用最小)。
- **版本对齐 1.8.0 (§2)**: player `versionName 1.8.0 / versionCode 18`;controller `pubspec 1.8.0+18`,并在 `flutter build apk` 传 `--build-name=1.8.0 --build-number=18` 确保进入最终 APK。

### Verified
- `python3 -m py_compile broker/*.py windows_player/*.py` 通过;`pytest -q broker/tests windows_player/tests` = **221 passed**(broker 84 + windows_player 137)。Dart 端 `remote_flutter/test` 走云 CI。
- Android 源码级引用完整性自检:新增 `R.string`/`R.id`/binding id、`ConnState`/`SystemInfo`/`resetConnection`/`hasBroker`/`deviceIp`/`brokerHintFromWsUrl`/`isConnected` 均已定义;color/style 资源齐全。
- Android/Flutter 编译走 GitHub Actions 云 CI(ARM 容器不跑 gradle/flutter)。

## [v1.7.0] — 2026-07-03

### Added
- **Flutter 遥控端真·摄像头扫码入组 (§15)**: 邀请页新增“扫码添加”，用 `mobile_scanner` 扫被控端展示的 `lmw://pair?...`，与粘贴链接/手填 IP 共用 `addDeviceFromPairUri` 入组路径。
- **设备墙即时可见性 (§14.5)**: 发现/扫码/手填的设备立即以占位卡出现，显示“已发现/连接中/已连接/失败+原因”，WS 回传 `DeviceStatus` 后覆盖占位，不再静默吞连接失败。
- **未配置被控端 broker 发现广播**: Android player 即使未配置但已通过局域网发现 broker，也常驻 8772 announce 并广播实际连上的 broker hint，修复“有 broker 但两台互不发现”。

### Fixed
- **Android 4.4 安装链路补齐**: R8 规则去掉 ExoPlayer/OkHttp 宽 keep，保留窄入口 + dontwarn，恢复 DCE；补传统 PNG launcher mipmap，避免 API 19 矢量图标/图标空白问题。

### Verified
- release_readiness_review: PASS（py_compile 25 files；broker 84 passed；windows_player 137 passed；联跑 221 passed；Kotlin R 引用/required_wired/contract checks pass）。
- Android/Flutter/Windows/Broker 编译验收走 GitHub Actions 云 CI。

## [v1.4.0] — 2026-07-02

### Added
- **Android 扫码配对 UI (§15)**: 设置页新增 Scan pairing QR 按钮，拉起 CameraX 后置摄像头预览 + ZXing 解码，扫到 `lmw://pair?...` 后自动回填 broker host/port/group/WSS/name/密钥字段，真正免手输。
- **Android 数字标牌加固**: Device Owner/Lock Task 真 kiosk 注册、无 Device Owner 时不弹屏幕固定确认；隐藏退出后门(左上 7 连击或遥控 ↑↑↓↓ + PIN)；缓存 LRU 配额/保护当前 playlist；心跳补充 app_version/内存/温度字段。
- **Windows player 硬解参数**: mpv 默认 `--hwdec=auto-safe`，支持显式关闭/指定解码器，配套 pytest 覆盖。

### Changed
- Android `APP_VERSION` 改为读取 Gradle `BuildConfig.VERSION_NAME`，避免协议上报版本与 APK 版本漂移。
- Android PSK 输入遵循 open 语义：空 PSK 表示无密钥/open 模式，不再强制填写。

### Verified
- windows_player pytest: 137 passed。
- windows_player py_compile: pass(使用独立 pycache 前缀；仅保留既有 mpv docstring escape warning)。
- Android 本地仅做引用/资源/manifest/CameraX API 静态核对；APK 编译按项目约束走 GitHub Actions 云端。

## [v1.1.0] — 2026-06-24

### Added (易用性 / 上手门槛大幅降低)
- **可选鉴权 `auth_mode` (§13)**: `open`(默认,零配置、不验签)/ `optional` / `required`。默认不再强制 PSK——开箱即用,安全需求再切档。ts-window + msg_id 防重放在所有模式下保持。
- **拓扑三模式 `topology` (§14)**: `dedicated`(独立 broker，现状)/ `cohosted`(被控端兼职 broker，零额外机器)/ `p2p`(彻底无 broker，遥控端兼协调者 + 时钟主)。自动发现找不到 broker 自动退化到 p2p。
- **二维码配对 `lmw://pair?...` (§15)**: 遥控端生成配对二维码，被控端(尤其 Android)扫码免手输入组；`open` 模式不含 psk。
- **关联 id 澄清 (§16)**: fallback 匹配(group_id+playlist_id / 回显 t1)固化为正式契约，显式 id(prepare_id / req_msg_id)列为可选推荐——全部向后兼容。

### Implementation
- broker: auth-mode 门控、`run_broker()` 可嵌入入口(cohosted)、announce 携带 topology/auth_mode、pairing URI 生成 + 终端 QR。
- windows_player: auth 自适应、cohosted broker host、p2p server 角色翻转、`lmw://` 解析。
- android player: 扫码配对解析、auth 自适应、p2p server + 自动发现。
- remote_flutter: auth 自适应、二维码生成、完整 p2p 协调器(时钟主 / 三段握手 / 组扇出 / 设备墙聚合)。

### Verified
- broker pytest 59 passed + 端到端同步链 smoke 5/5 PASS;windows_player pytest 100 passed;android Gradle BUILD SUCCESSFUL;四端云 CI 全绿。

### Compatibility
- 完全向后兼容 v1.0.x：默认行为等价于 `dedicated` + `required`(若配了 PSK)；新模式均为附加项。

## [v1.0.2] — 2026-06-24

### Fixed
- **broker-build release path**: the broker lane runs with `working-directory: broker`, so PyInstaller emits to `broker/dist/...`, but the upload + release-attach steps still pointed at `dist/...`. The two broker binaries never attached on v1.0.1. Paths corrected to `broker/dist/...`.

### Result
- All four CI lanes green (`ci`, `windows-build`, `android-build`, `flutter-build`, `broker-build`).
- Release v1.0.2 attaches all 7 artifacts: 4 controller/player APKs, the Windows installer, and both `lmw-broker` (Linux ELF) + `lmw-broker.exe`.

## [v1.0.1] — 2026-06-24

### Added
- `flutter-build.yml` — cloud-build the `remote_flutter` controller APK (per-ABI release splits, ~14–19 MB instead of the 141 MB debug).
- `broker-build.yml` — PyInstaller onefile lane for standalone `lmw-broker` binaries.
- Slimmed all artifacts: split-per-ABI release APKs, Windows installer measured under the 60 MB ceiling.

### Fixed
- Robust mpv runtime download in `windows-build` (GitHub mirror primary, SourceForge fallback with a proper UA); avoid self-copy when mpv extracts to the runtime root.

### Known issue (fixed in v1.0.2)
- broker binaries did not attach to the release due to a `dist/` vs `broker/dist/` path mismatch.

## [v1.0.0] — 2026-06-23

### Added
- **Phase 1** — protocol contract (`protocol_spec.md` v1) plus three ends against it:
  - **broker** (Python, asyncio): WS/WSS server, signed-envelope auth (HMAC-SHA256 + ts window + msg_id dedup), device registry + grouping with atomic `state.json`, master clock + SNTP-style `time_sync`, three-phase `prepare→ready→play_at` sync state machine, UDP discovery, thumbnail relay. 27 unit tests + end-to-end smoke.
  - **windows_player** (Python + mpv via JSON IPC): reconnect, resumable Range downloads + sha256, kiosk fullscreen-topmost + taskbar hide, watchdog crash recovery + `resume_last`. 34 unit tests, OS-coupled paths import-guarded for cross-platform CI.
  - **remote_flutter** (Flutter controller): device wall, playlist editor, prefetch, synced play, per-group volume/mute/audio-master, group assignment; byte-for-byte canonical-JSON HMAC alignment with the Python ends.
- **Phase 2** — native **Android Kotlin player** (Media3/ExoPlayer), behaviorally on par with the Windows player; protocol bumped to **v1.1** (backward-compatible additions: `prepare_id` sync-session correlation, `wall.devices[]` field set, `welcome` fields, `controller_presence`, `time_sync_ack.req_msg_id`).
- GitHub Actions cloud-build for the Windows exe and Android APK.

[v1.0.2]: https://github.com/Jieoz/lan-media-wall/releases/tag/v1.0.2
[v1.0.1]: https://github.com/Jieoz/lan-media-wall/releases/tag/v1.0.1
[v1.0.0]: https://github.com/Jieoz/lan-media-wall/releases/tag/v1.0.0

[v1.7.0]: https://github.com/Jieoz/lan-media-wall/releases/tag/v1.7.0
