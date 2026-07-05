# 控制端(遥控端 Flutter)重做 — 设计合同 v1

> 面向**手机遥控端**的产品重做定稿。对标 `player-tv-ux-redesign.md`(被控端合同)。
> 本文件是给实现方的**设计合同**:先定契约,再改代码,云 CI 验收。

## 0. 最高原则:预缓存本地播放,遥控端可离线(2026-07 Jay 定稿)

- **播放模型 = 提前缓存到受控端 + 本地文件播放,绝不流媒体。**
  受控端(盒子/Windows)先把媒体下载到本机缓存 → `sha256` 校验 → 从本地文件播放。
  播放期间不依赖任何实时流、不依赖遥控端在线。
- **遥控端(手机)是"临时纳管/分发器",不是"常驻服务器"。**
  手机只在「分发缓存」这段窗口需要在线;媒体全部下发完成 + 各端校验 OK 后,
  手机可离线,盒子照常从本地缓存播放。**任何设计都不得要求手机在播放期常在线。**
- 违反此原则的方案(如播放期从手机流媒体)一律不采纳。

## 1. 现状根因(逐条核对代码,2026-07)

| 痛点 | 根因(代码级) | 修复层 |
|---|---|---|
| 功能布局不合理 | `control_panel.dart` 把选组/编列表/传输/音量/出声/改组 6 块堆在一个 ListView;三 Tab(设备墙/控制/设置)割裂,无任务流 | 控制端 UI |
| 分组不能新建 | 协议只有 `assign_group`(改组),**无 `create_group`**;组只能从 broker wall 快照被动出现,UI 只能选已有组 → 无法从零建第一个组 | 协议+broker+UI |
| 不能设置盒子配置 | 无 per-device 配置命令(改名/独立设置);`assign_group` 埋控制页最底,不成体系 | 协议+broker+UI |
| 自动发现不可用 | 控制端 `discovery.dart` 只广播 255.255.255.255,**手机侧未取 MulticastLock**(安卓 WiFi 默认过滤组播/广播);仅手动 discover 一次、无周期重试 | 控制端+安卓权限 |
| 图片视频不能上传本地(最离谱) | media item **只吃 URL**;broker 只转发 WS + 中转缩略图,**不存不供媒体**;无任何上传通道 → 手机本地文件无法上墙 | 架构新增(A+B) |

## 2. 上传架构 = A + B(Jay 定)

"上传"本质 = 让手机本地文件变成受控端在**分发窗口**能 GET 的 URL,下载到本地缓存后手机可走。

### 2.1 模式 B — broker 媒体库(broker 模式主路径)
- 手机把选中的本地文件 **HTTP PUT/POST 上传到 broker** 的媒体接收端点。
- broker 落盘到媒体目录,按 `sha256` 命名/校验,**静态 HTTP 服务**该文件。
- 媒体 item 的 `url` 指向 broker(如 `http://<broker>:<mediaPort>/media/<sha256>.<ext>`)。
- 各受控端走**现有** `cache_prefetch` 链路 GET 到本地缓存(复用断点续传 + sha256,零改动)。
- broker 本就常在线,天然适合当媒体库;上传完手机即可离线。

### 2.2 模式 A — 手机临时 HTTP(P2P / 无 broker 兜底)
- 无 broker 时,手机选文件后**本机起临时 HTTP 服务**(仅分发窗口存活)。
- media item 的 `url` 指向手机 IP(如 `http://<phoneIp>:<ephemeralPort>/m/<id>`)。
- 各受控端从手机 GET 到本地缓存 + sha256 校验。
- **全员 `cache=ready` 后**遥控端广播 `play_at` 统一起播 → 起播后手机可关服务/离线。

### 2.3 预缓存栅栏(prefetch barrier,P2P 与 broker 通用)
- 下发 playlist + cache_prefetch 后,进入"分发中"状态,UI 显示每台下载进度/校验态。
- **等组内所有(在线)成员上报 `cache=ready`(全部下完 + 校验通过)才允许统一起播**;
  这正是"等所有设备都下载完成后再统一从头开始播放"。
- broker 模式:沿用 §9.1 `prepare`→收齐 `ready`→`play_at`,但 `ready` 条件强化为
  "缓存就绪 + 预加载到位"。P2P 模式:遥控端本地编排同一栅栏(见 p2p_coordinator)。
- 超时策略:可配置等待上限;到时对已就绪者起播 + 明确标出未就绪台(不静默)。

## 3. 协议新增(protocol_spec.md + broker + 两端)

| 新增 type | 方向 | payload 关键字段 | 语义 |
|---|---|---|---|
| `create_group` | controller→broker | `group_id`,`name`,`sync` | 新建空分组(修"不能新建组") |
| `delete_group` | controller→broker | `group_id` | 删除分组(成员回落默认组) |
| `update_group` | controller→broker | `group_id`,`name?`,`sync?` | 改组名/同步模式 |
| `configure_device` | controller→broker→player | `device_id`,`device_name?`,`group_id?`,... | 盒子配置(改名/设组/单机项) |
| media 上传(HTTP) | controller→broker | (HTTP PUT 二进制 + meta) | 模式 B 上传端点(非 WS) |

- broker 侧:`registry` 增加 create/delete/update group;媒体接收 + 静态服务(新 HTTP 端点,
  与现有 WS 端口分离);wall 快照反映新组。
- media item 扩展:允许 `url` 由上传后回填;保留 `sha256`/`size`/`duration_ms` 语义不变。
- 向后兼容:老 broker 无新端点时,UI 探测失败则回落模式 A(P2P 手机临时服务)。

## 4. 控制端 UI 重构(信息架构)—— 横屏平板为主场景(Jay 定)

### 4.0 主场景 = 横屏平板(landscape tablet first)
- **主要使用设备 = 横屏平板**,不是手机竖屏。布局按横屏宽屏优先设计,
  竖屏/手机为自适应降级,不是反过来。
- 横屏用**双栏/三栏并置**(master-detail),充分利用横向空间,避免手机式单列长滚动。
- 断点(LayoutBuilder / MediaQuery):
  - **宽 ≥ 900dp(平板横屏,主场景)**:左「设备墙栏」固定 + 右「编排/详情栏」并置,
    顶部通栏状态条(发现/连接/拓扑)。分组管理与盒子配置以右栏面板或侧边抽屉呈现,
    不跳页。
  - **600–900dp(小平板/横屏手机)**:两栏可折叠,详情可抽屉化。
  - **< 600dp(手机竖屏,降级)**:回落底部导航 + 单列(现结构的整理版)。
- 交互面向平板:更大的点击目标、可并排看设备墙缩略图与编排、拖拽排序 playlist(横屏空间够)。

### 4.1 三大功能区(以任务流组织,横屏并置而非割裂 Tab)
1. **设备墙栏(左,常驻)**:设备卡(缩略图/名/组/在线/缓存态/接入相位),支持
   - 顶部:发现状态 + 手动刷新 + 扫码纳管 + 手输 IP 兜底
   - 卡片操作:配置盒子(改名/设组)、单机控制
   - **新建/管理分组**入口(修"不能新建组")
2. **播放编排栏(右,主工作区)**:选组 → 编列表(**本地上传** + URL + 图片停留时长)
   → 预缓存(看栅栏进度)→ 全员就绪后一键同步起播 → 传输控制/音量/出声台
3. **设置**:broker 地址/端口/WSS/PSK/controller_id + 诊断日志(次级入口:抽屉/顶栏菜单,
   非主 Tab)

- 全中文;关键状态(发现/缓存/就绪/失败原因)一眼可见,不静默。
- 本地上传入口:调 file/image picker 选手机文件 → 按 §2 A/B 生成可 GET 的 URL → 进列表。

## 4.9 默认参数(Jay 确认前用推荐默认)
| 参数 | 默认 | 说明 |
|---|---|---|
| 上传单文件大小上限 | 500MB | 1080p H264 短视频足够,防误传超大文件 |
| broker 媒体目录 | broker 同级 `./media/`(容器挂卷持久) | 可改到 NAS 挂载点 |
| prefetch 栅栏等待超时 | 120s | 超时对已就绪台起播 + 明确标出未就绪台 |

## 5. 自动发现修复(控制端)

- 安卓侧**取 `MulticastLock`**(WifiManager.createMulticastLock().acquire()),分发/发现期持有,
  否则 WiFi 下收不到 announce(与被控端 §6.1 暗坑同源,控制端也中招)。
- 发现改为**周期重试**(启动 + 定时 + 手动),不止一次性广播。
- 双出口(有线/WiFi)正确取本机 IP 用于模式 A 的 URL 与首启显示。
- Android 权限:`CHANGE_WIFI_MULTICAST_STATE` + `INTERNET`;file/image 上传相关权限按需。

## 6. 验收边界

- Android/Flutter **不在容器内跑 gradle/flutter**;编译验证走 **GitHub Actions 云 CI**
  (push tag/commit 触发 android-build.yml)。容器内仅源码级自检(import/资源 id/类型/Manifest)。
- broker(Python)可在本地/容器跑 pytest 验证协议新增。
- 多台效果:CI 绿 + 至少一次真机多端联调(Jay 现场)确认预缓存栅栏 + 全员就绪起播。

## 7. 实施阶段(建议顺序)

1. **协议 + broker**:create/delete/update_group、configure_device、媒体上传+静态服务、prefetch 栅栏强化 → pytest。
2. **控制端网络层**:MulticastLock + 周期发现、上传客户端(A+B)、新协议出站命令。
3. **控制端 UI 重构**:设备墙/播放编排/设置三段重排,本地上传入口,分组管理,盒子配置,栅栏进度。
4. **播放端**:确认 cache=ready 语义满足栅栏;必要时补 configure_device 处理。
5. **云 CI 全绿** → 真机多端联调 → 发版。
