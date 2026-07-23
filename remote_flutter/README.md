# remote_flutter — LAN Media Wall 遥控端 (controller)

> **v1.19.2：播放模式可见，模式操作回到播放控制区。** 设备卡和单台状态面板显示
> 当前播放模式（图片/视频、音乐终端、待机）。普通单台播放控制区新增
> **「切换音乐终端」**、**「保存并播放」**、**「恢复图片/视频」**，不再要求操作员
> 进入音乐终端弹窗才能切换模式或恢复视觉播放；保存并播放只在有权威本地音乐清单时
> 启用，避免旧端只上报数量时被空列表覆盖。单一版本源为 `1.19.2+1192`。
>
> **v1.19.1：显式强制 P2P。** Controller 发送 `transport_mode:p2p`，并在切换自身
> 连接前验证 Player 的持久化回执、递增 revision 和状态快照均为 P2P。普通清空 Broker
> 使用 `auto`，不再与强制 P2P 混淆。单一版本源为 `1.19.1+1191`。
>
> **v1.19.0：权威清单、严格缩略图与安全 P2P 还原。**音乐终端从 Player 的完整
> `active_music_playlist` 恢复，旧 Player 仅报告非零数量时禁止空列表覆盖。缩略图严格
> 校验连接设备、播放项、模式、generation/session、序列和长度，并在换项/离开 visual
> 时清除旧预览。设置页一次选择一台 Player，经当前 Broker 清除设备配置并确认持久化
> P2P 连接身份只由握手/状态建立；业务 payload 的 `device_id` 不能重绑定连接。
> 回读后才切 Controller 到自动发现，并要求 20 秒内建立 direct 连接；超时明确报错。
> 单一版本源为 `1.19.0+1190`。
>
> **v1.18.9 正式版：模式控制按操作员语义归位。**音乐终端新增明确的
> **「恢复图片/视频」**，直接选择 `visual`，不再让“恢复前态”冒充退出音乐的入口；
> **「待机 / 退出待机」**从音乐列表编辑窗移到单设备播放控制，与暂停、继续、停止
> 平级。最终提示仍等待设备的 request/device 关联结果，不把投递成功冒充执行成功。
> 对应版本源为 `1.18.9+1189`。
>
> **v1.18.8 正式版：独立播放模式与设备音乐终端。**设备卡可显式切换
> `visual` / `music` / `standby`；音乐使用每台设备独立的 `music_playlist`，不混入
> 视觉墙同步列表。控制端按 `request_id + device_id` 关联模式/列表结果，连续保存时从
> status 与最近成功 result 的最大 revision 继续递增，避免快速操作复用旧 revision。
> 同版包含未单独发布的 v1.18.7 批量 Broker 迁移：预检、限并发写入、失败重试、
> 精确回读与新 Broker welcome 超时回滚。单一版本源为 `1.18.8+1188`；真机播放、
> 迁移与 OTA 观察作为安装后的现场证据继续记录。
>
> **v1.18.6 正式版：APK manifest 是升级目标版本的唯一真相。**控制端选择 APK 后
> 解析二进制 `AndroidManifest.xml`，校验包名为 Player，并把真实 `versionCode` /
> `versionName` 写入 `update_app`；UI 不再允许手填虚假目标版本。该链路已在
> API 19/YunOS 实机通过 P2P 完成 `1185 → 1186` 激活、重启和重连验收。
>
> **v1.18.2：安全远程配置。**`configure_device` 仅允许设备名、分组、音量和静音，
> 控制端按 capabilities/snapshot 显示可编辑项，以 revision 防冲突，并等待逐字段
> `config_patch_result`。连接设置走 `transport_configure`，密钥轮换走
> `rotate_device_key`；普通快照和结果从不含密钥。
>
> **v1.18.1：Windows 无 Python 现场 OTA 检测器。**本版是工具/打包层交付：
> QZX Update Tools 新增双击启动器 `OTA检测.bat` 与独立
> `android_ota_diag.exe`，可在 stock Windows x64 上离线生成中文诚实诊断；
> 不改遥控端协议、传输、路由或 OTA 安装合同。该历史版本为
> `1.18.1+1181`；当前正式版本为 `1.18.9+1189`，本页顶部为 `1.19.0+1190` 候选。
>
> **v1.18.0：操作员 UX 重构。**P2P 为主链路,Broker 降为高级/次要;无协议、传输、
> 精确 `device_id` 路由、缓存/OTA/安全合同改动,纯 UX 层。**设置拓扑真相**:新增
> 连接方式切换「自动发现 / P2P（推荐）」vs「连接 Broker（高级）」并持久化
> (`settings.connection_mode`;存过 broker 地址的老用户迁到 Broker 模式,否则默认
> P2P);P2P 模式隐藏 broker host/port/WSS/上传 token;连接标签由实际拓扑+对端/连接
> 态派生(`P2P · 已连接 N 台` / `P2P · 正在发现设备` / `Broker · 已连接` /
> `Broker · 重连中`),经单一真相源 `WallState.connectionStatusLabel`,绝不乐观;端口
> 严格校验 1–65535,非法输入绝不静默回落 8770;保存提示「设置已保存，正在重新连接」。
> **统一单台推送**:编排栏「推送到此设备」与设备卡「推送内容」共用
> `lib/ui/push_workflow.dart` 的 `showPushToDeviceDialog`,确认摘要写明目标/条目数/
> 替换或追加/缓存/是否起播,最终二选一「仅下发并缓存 / 缓存完成后播放」,保留精确
> 单播路由与上传/缓存栅栏。**措辞真相**:本地清空改名「清空本地草稿」;远程清空改名
> 「停止播放并清空设备列表」加红色二次确认(精确目标+已知在线台数+停播黑屏+缓存保留);
> ACK 前一律「命令已发送，等待设备确认」(pause/resume/stop/prev/next、远程清空、追加)。
> 新增 Dart 测试(`test/connection_status_test.dart`、`push_workflow_test.dart`、
> `settings_topology_test.dart`,云 CI 跑)+ 本地 Python 静态合同
> `scripts/tests/test_ux_optimization_contracts.py`。版本随全端单一真相源
> `pubspec.yaml` = `1.18.0+1180`。

> **v1.17.7：通用 Android OTA 诊断框架随 QZX Update Tools 发布。**离线
> `android_ota_diag.py` + profile + 主机 legacy 仿真器;版本随全端单一真相源
> `pubspec.yaml` = `1.17.7+1177`。控制端功能无本版业务改动。
>
> **v1.17.6：二次 legacy OTA 不再因残留 `.lmw-backup` 永久失败。**root
> 守护进程 re-stage 前自动 commit/restore leftover backup。已走过 legacy 的
> 盒子需 QZX Update Tools 重装 daemon。版本随全端单一真相源
> `pubspec.yaml` = `1.17.6+1176`。
>
> **v1.17.5：远程改名墙面回显 + 推送升级诚实路径。**播放端 `status` 现带
> `device_name`,改名后设备墙立刻显示新名(控制端既有 `configureDevice` 无需改
> 协议)。同版 root 守护进程修 4.4 上 `pm` Success/exit 误判与 `pkg:`-only
> detail;失败类盒子需用 QZX Update Tools 重装 daemon。版本随全端单一真相源
> `pubspec.yaml` = `1.17.5+1175`。
>
> **v1.17.4：单台推送/清空 broker 连接。**该版的 `configure_device` 连接/PSK
> 旁路已由 v1.18.2 取代：普通配置仅安全字段，连接走 `transport_configure`，密钥走
> `rotate_device_key`。同版播放端另含 cache SOE 修复、API19 冻结帧与设置页回主页键
> (见 player README)。
>
> **v1.17.1-field-fix：分组当前清单回读。**编排栏此前只能从**单台**在线设备载入 `active_playlist`,选中分组无法回填草稿(操作员反映「分组清单拉不到」)。「目标分组(推送/同步目标)」区新增 **「载入分组当前清单」** 按钮:从组内在线成员里选一个**代表**,把其有序 `active_playlist` 载入草稿。代表策略(纯逻辑 `lib/state/group_playlist_load.dart`):优先 `active_playlist.group_id` 与所选组一致者,否则任一在线且非空的成员,平手时 `playing`/`buffering` 优先于 `idle`,再按 `device_id` 字典序稳定取小。载入时如实汇报一致性:按成员指纹(`playlist_id` + 有序 `item_id` join)与代表比较,提示组内多少台一致/不同/未上报(如 `已从代表 and-xxx 载入；组内 2 台一致、1 台不同、1 台未上报`)。单台回读路径(现名「单台当前播放列表(精确回读某一台)」)不变。不新增线协议类型,复用现有 `status.active_playlist`。

> **v1.17.0 Phase B 缓存清理接线(已发布):**控制端把 broker 与 P2P 两条 `cache_cleanup_result` / `cache_inventory_result` 接收路径**汇入同一个 `CacheOpsReducer`**(`lib/state/cache_ops.dart`),按 `request_id + device_id` 键做设备隔离、幂等去重、陈旧/迟到结果拒绝、超时收割与互不混淆的终态(成功/部分/失败/超时/不支持/离线/代次冲突)。设备详情弹窗新增独立的**「缓存管理」**入口(`lib/ui/cache_management.dart`):清单 → 演练(dry-run,零删除) → 显式确认 → 提交,展示总量/可回收/受保护/下载中摘要与逐项保护原因,提供每台设备终态与重试;真实删除必须过一道确认对话框并只按演练回来的候选 `item_id` 下发。能力真值:目标未广告 `cache_cleanup_v1` / `cache_inventory_v1` 直接置 `unsupported`,绝不「发了没回」冒充支持。播放列表行删除仍只是「移出列表」,不动缓存。窄屏(320)不溢出。不含 Phase C 组实时编排;正式字节由 exact-SHA 云 CI + release-promote 门禁。

> **v1.16.0：**本次为播放端 Phase A 缓存清理内核 + 协议合同(仅内核,未接线)统一晋级,**控制端本身无功能改动**;版本随全端单一真相源 `pubspec.yaml` 同步递增。Phase B(请求路由、状态发射、broker/P2P 回传、Flutter UI、能力声明)在上面的候选条目落地。

> **v1.15.3：**控制端选择在线设备后，会把该机上报的有序 `active_playlist`、当前播放项和循环模式完整载入同一个 `PlaylistDraft`。编排栏与设备卡推送弹窗都能标记当前项、上移/下移、删除、追加并整列应用；重排按 `item_id` 跟踪当前媒体，删除节目项不删缓存。旧版设备未上报活动列表时会清空上一台草稿，避免跨设备误发；上传期间禁止关闭弹窗，避免异步回调访问已销毁状态。版本同时包含 Android Player 设置页诊断刷新修复。

> **v1.15.2：**版本随 Android Player 诊断导出完整性修复统一晋级；控制端即时启动与显式设置入口行为保持 v1.15.1 的合同不变。

> **v1.15.1 即时启动：**Android 原生 `MainActivity` 在 Flutter 初始化前丢弃冷启动/进程重建传入的 saved-state bundle，并继续禁用 Flutter 状态保存，因此每次真正重启都进入可立即操作的 `ResponsiveShell`，不会复活配置对话框；配置只由顶部“设置”按钮显式打开，普通前后台切换仍保留用户主动打开的对话框。

> **v1.15.0 媒体推送进度：**Broker 与 P2P 在 `WallState` 汇入同一任务状态机；下载中最多显示 99%，只有校验、原子落盘并由播放器上报 `ready` 后才是 100%。每次非空 `replace` 使用唯一 `push_id`，播放器采纳后回显，避免复用 `playlist_id` 时继承旧完成状态。聚合仅计算本次任务预期条目，不把设备历史缓存库存算入；命令投递失败不会创建幽灵 0% 任务，空 `replace` 清空后历史 cache 也不会恢复进度条。

> **v1.14.13:** Android 冷重启不再恢复 FlutterActivity 的 instance/navigation state：仓库保存定制 `MainActivity.kt`，CI 在 `flutter create` 后按确定路径安装并逐字节核验，因此进程被杀或真正重启总是从 `ResponsiveShell` 主界面开始，不会复活设置对话框；普通前后台切换不重建 Activity，已打开的对话框继续保留。严格 Range 现在也拒绝重复物理 `Range` header，统一空体 `416`。release 构建与晋级从仓库内公开的 canonical 证书指纹（可由仓库变量覆盖）解析同一个期望 signer，并逐个核验 APK 包内 versionName/versionCode 与 signer。`WallState.init()` 在每个异步边界检查析构状态，快速卸载时不再在 `dispose()` 后分配链路、启动发现或通知已销毁的状态对象。

> **v1.14.12:** P2P 本地媒体服务现在只接受 `GET/HEAD`（其他方法返回 `405` + `Allow: GET, HEAD`），严格支持单段 `N-M` / `N-` / `-N` Range；malformed、multi-range、空文件 Range 与越界统一返回空体 `416` + `Content-Range: bytes */total`。成功 `206/Content-Range` 只在拿到 stream permit 后写入，满载 `503` 仅含空体、`Retry-After: 1`，与播放器有界重试/Range 续传契约一致。gate 具备运行时参数校验及 close/generation 语义，stop 会立即解除 waiter，restart 使用全新 gate；服务不会在首项 ready/play_at 后关闭，而是保守保持到 `WallState.dispose`，因此后续列表项和新上传仍可下载。HTTP loopback 集成测试覆盖 Range/HEAD/405、并发上限/FIFO 排队/503 headers、客户端断开 permit、stop waiter 与 stop→restart。

> **v1.14.11:** P2P 临时 HTTP 媒体服务采用有界 FIFO 背压：最多同时流式发送 6 条，等待队列最多 64；再超限返回空体 `503` + `Retry-After: 1`，播放器保留 `.part` 后按 Range 续传。整个文件始终从磁盘流式发送，不整块读入内存。P2P 仍定位为 ≤8 台小场景，更大规模使用 Broker/NAS。并发与队列边界由 `media_request_gate_test.dart` 和 loopback HTTP 集成测试在 Flutter CI 中验证。

> **v1.14.10:** P2P close diagnostics now expose RFC6455 close code/reason in
> controller logs and per-peer failure state. Reconnect backoff is reset only by
> a verified application frame (welcome or later), not by HTTP upgrade, so
> repeated `1013` closes back off 1s→2s→4s instead of retrying every second.
> Real-device validation remains pending.

> **v1.14.9:** 普通「编排/添加项目到当前列表」默认发送
> `mode=append`；整列替换改为明确标注的缓存/播放操作并显式发送
> `mode=replace`。逐项添加 A、B 因而保留为同一有序活动节目单，而不是让 B
> 静默覆盖 A。对应 Flutter 回归测试直接使用本包的 `protocol/messages.dart`，
> 云端 `analyze` 与 `flutter test` 会共同校验该编排契约。

**播放列表编排**：在线设备状态中的 `active_playlist` 是独立于 `cache` 的有序节目单。编排栏可载入单台设备的节目单、上移/下移或删除项目，再单播应用回该设备；删除节目单项目不会删除盒子上的缓存文件。

LAN 媒体墙的 Flutter 遥控端。连接 broker、查看设备墙、下发播放控制。严格遵守
[`../protocol_spec.md`](../protocol_spec.md) v1 合同。

> **当前候选版本 `1.19.0+1190`（`pubspec.yaml`）。**CI 从 pubspec 派生 `flutter build apk --build-name=<pubspec name> --build-number=<pubspec code>` 把版本号烧进 APK；播放端 `build.gradle.kts` 也从同一行派生，改 pubspec 即全端同步。只有同一 SHA 的全平台门禁通过并完成资产核验后才晋级正式 Release。
>
> **v1.14.10**：修复真实 P2P 控制面误选路——播放端明确声明 `topology=p2p` 时忽略兼容 `broker_hint`，控制端建立逐台直连并消费 `status/time_sync`，设备卡从「已发现」正常推进到「已连接」；单台改名/设组/音量也沿同一真实链路投递，UI 明确提示命令已投递。
>
> **v1.14.8**:控制端配合有序播放列表 `replace`/`append`——`sendPlaylist` 新增 `mode` 参数,编排面板新增「③追加到当前列表」按钮(`_doAppend`,复用被控端保留的 `playlist_id`,按 `item_id` 去重合并到当前序列尾部、不打断在播内容;老播放器不认 `mode` 自动回退 `replace`);`DeviceStatus` 解析 additive 的 `current_index`/`playlist_count`。**拓扑诊断诚实化**:诊断汇总区分 **operating**(本端实际连接方式)与 **declared**(协调端 welcome 声明)两个拓扑并同时打印,修「汇总说 `topology=dedicated,p2p_peers=0` 而日志说 `topology=p2p`」的自相矛盾;broker 路径收到本应由 broker 聚合的 `status/time_sync/ready` 时显式记「落到 broker 路径被丢弃」而非静默,`online=null` 变可归因。
>
> **v1.14.7**:QZX 真机默认视频内核改为原生 MediaPlayer(同素材 A/B 已确认 ExoPlayer 可见掉帧、原生更稳),`auto` 不再回落 ExoPlayer,仍可显式选 ExoPlayer;修复设置页保存内核后旧 `MainActivity`/旧 controller 未销毁、界面显示 MediaPlayer 但实际继续跑 ExoPlayer 的问题——保存现用 `NEW_TASK|CLEAR_TASK` 确定重建播放任务并按新配置重建。另据 QZX_C1 真实现场包修复诊断误判:daemon 的 `ps` 捕获不再被 8 KiB 截断,BAT 保存完整 `ps` 后解析 PID;双击窗口即使中途命令失败也保持打开;A/B 每轮清空独立日志窗口并校验实际启动 backend,daemon 非零结果不再触发第二次 fallback 重启。控制端功能无改动。
>
> **v1.14.6**:收紧 QZX 重启验收：必须由真实 daemon worker单次执行且返回成功，force-stop 成功并观察到新 PID，随后同时满足 PROCESS_UP 与 ACTIVITY_RESUMED；daemon 缺失、worker 非零、旧 PID 未变化均失败。另包含 v1.14.5 的发布资产清单修正，确保一键真机 `qzx_field_check.bat/.sh` 与守护进程一起进入 Update Tools ZIP；同时包含 v1.14.4 的 root daemon `RESTART_APP` 改为确定性「验证-重试」状态机,区分 PROCESS_UP 与 ACTIVITY_RESUMED(仅进程回来但活动没到前台=部分失败,不算恢复),重启证据日志给出显式 `restart_verified`/`restart_failed` 终态;新增一键真机 `scripts/qzx_field_check.*`(重启双信号验证 + ExoPlayer/MediaPlayer A/B)。控制端功能无改动,版本随全端 pubspec 同步递增。
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
