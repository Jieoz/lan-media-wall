# LAN Media Wall — 通信协议规范 (Protocol Spec) v1.10.7

> 这是 broker / Windows 被控端 / Android 被控端 / Flutter 遥控端 **共同遵守的合同**。
> 任何一端都不得擅自更改字段名或语义；如需扩展，只能新增 `type` 或在 `payload` 里加可选字段，并升 `v`。
>
> 线协议主版本仍为 envelope 字段 `v:1`。本文档版本跟随产品 release，记录 v1.1–v1.10.7 的向后兼容扩展；任何破坏性字段语义变更才需要提升 envelope `v`。

---

## 0. 角色与拓扑

```
  遥控端(controller, Flutter)
        │  WSS/WS  (只连 broker)
        ▼
  ┌─────────────┐   WSS/WS    ┌──────────────────────┐
  │   broker    │ ◄────────► │ 被控端 player (N≈30) │
  │ (群晖 Docker)│            │ Windows10 / Android   │
  └─────────────┘            └──────────────────────┘
```

- **broker**：中央协调者。维护设备注册表、分组(group)、playlist 下发、状态汇总、时钟同步基准、命令扇出。所有遥控端与被控端都只与 broker 建立 WebSocket 长连接，端到端不直连。
- **controller(遥控端)**：发命令、看设备墙。可多个同时在线。
- **player(被控端)**：执行播放，周期上报状态。Windows(Python+mpv) 与 Android(Kotlin+Media3) 行为一致，仅内核不同。

---

## 1. 传输与连接

- 传输：WebSocket。默认端口 **broker 监听 `8770`**(WS) / `8771`(WSS，证书存在时启用)。
- UDP 发现端口：**`8772`**(见 §7)。
- 文本帧承载 JSON(UTF-8)。二进制帧仅用于缩略图(见 §6.4)。
- 心跳：传输层每 20s 一个 WS ping;应用层状态包见 §5。
- 重连:断线后指数退避重连(1s,2s,4s … 上限 30s),重连后必须重新 `hello` + 重新时钟握手。

---

## 2. 消息信封 (envelope)

**所有** JSON 消息统一外层结构：

```json
{
  "v": 1,
  "type": "<message_type>",
  "msg_id": "<uuid4>",
  "ts": 1750000000000,
  "from": "controller:<id> | player:<device_id> | broker",
  "to":   "broker | player:<device_id> | group:<group_id> | all",
  "sig":  "<hmac_sha256_hex>",
  "payload": { ... }
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `v` | int | 协议版本，当前 `1` |
| `type` | string | 消息类型，见 §4–§7 |
| `msg_id` | string | uuid4，去重 + ack 关联用 |
| `ts` | int | 发送方**本地** epoch 毫秒(注意：用于鉴权时效，不用于同步) |
| `from`/`to` | string | 路由地址 |
| `sig` | string | HMAC-SHA256 签名，见 §3 |
| `payload` | object | 消息体 |

---

## 3. 鉴权与防重放 (HMAC)

- 全系统共享一个**预置密钥** `PSK`(部署时配置，32+ 字节随机串)。
- 签名对象 = `f"{v}|{type}|{msg_id}|{ts}|{from}|{to}|{canonical_json(payload)}"`，
  其中 `canonical_json` = `json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)`。
- `sig = HMAC_SHA256(PSK, 上述字符串).hexdigest()`。
- 接收方校验：
  1. 重算 `sig` 比对，不符直接丢弃。
  2. `abs(now - ts) > 30000ms` → 丢弃(防重放，依赖各端时钟大致同步;首次连接放宽到 120s)。
  3. `msg_id` 在最近 5 分钟内见过 → 丢弃(LRU 去重缓存)。
- 鉴权失败的连接，broker 累计 5 次后断开并冷却 60s。

> 注：WSS 可选叠加。即使无 WSS，HMAC 也保证控制指令不可伪造、不可重放。

---

## 4. 接入与注册

### 4.1 `hello` (player→broker / controller→broker)
被控端 / 遥控端上线第一帧。
```json
// player
{"type":"hello","payload":{
  "role":"player","device_id":"win-lobby-01","device_name":"大厅左屏",
  "platform":"windows|android","app_version":"1.0.0",
  "ip":"192.168.1.50","screen":{"w":1920,"h":1080},
  "capabilities":["video","image","audio","thumbnail"],
  "group_id":"lobby"   // 上次持久化的分组，broker 以注册表为准可覆盖
}}
// controller
{"type":"hello","payload":{"role":"controller","controller_id":"phone-jay","app_version":"1.0.0"}}
```

### 4.2 `welcome` (broker→对端)
```json
{"type":"welcome","payload":{
  "assigned":true,
  "server_time":1750000000000,   // broker 主时钟，见 §8
  "snapshot": { /* controller 收到：完整设备墙快照，见 §5.2 */ }
}}
```

**[v1.1] `welcome` 补充字段：**
- `v`(int)：broker 实现的协议版本，端侧据此判断兼容。
- `group_id`(string，仅发给 player)：broker 注册表**权威**分配的分组(§4.1 说 broker 可覆盖 player 上报的 group_id)。player 收到后以此为准。
- `controllers_online`(int，仅发给 player)：当前在线 controller 数。player 据此决定是否采集/上报缩略图(§6.4 的门控信号)。broker 在该数值变化时应主动补发一帧 `welcome` 或 `controller_presence`(见下)。
- `assigned`(bool)语义明确：对 player 表示"broker 是否已接纳并完成注册";`assigned:false` 仅作软错误，player 继续播放但应稍后重发 hello。对 controller 无强制语义。

### 4.3 `controller_presence` (broker→player) **[v1.1 新增]**
broker 在 controller 上线/全部离线导致 `controllers_online` 变化时，主动推给各 player：
```json
{"type":"controller_presence","payload":{"controllers_online":1,"present":true}}
```
player 据此精确门控缩略图采集(§6.4)，无需轮询。`thumbnail.always_collect=true` 的设备忽略此门控、始终采集。

---

## 5. 状态上报与汇总

### 5.1 `status` (player→broker，每 1–2s 一次)
```json
{"type":"status","payload":{
  "device_id":"win-lobby-01",
  "online":true,
  "group_id":"lobby",
  "state":"playing|paused|idle|buffering|downloading",
  "current": {"item_id":"a1","name":"promo.mp4","position_ms":12000,"duration_ms":60000},
  "playlist_id":"pl-lobby-1",
  "volume":80,            // 0–100
  "muted":false,
  "audio_master":true,    // 该机是否为本组出声端，见 §9.3
  "cache":{"a1":"ready","b2":"downloading:45%"},
  "clock_offset_ms": -12, // 本机相对 broker 主时钟的偏移(见 §8)
  "cpu":18,"errors":[]
}}
```
> broker 把各 player 的 `status` 合并进设备墙快照，按 §5.2 推给所有 controller(聚合后 ~1s 一次，避免风暴)。

**[v1.1] `wall.devices[]` 字段集明确**：每个 device 条目 = §5.1 `status` 的**完整最后一帧** + 以下身份/存活字段:`device_name`、`group_id`、`last_ip`、`online`(bool)、`last_seen`(epoch ms)。controller 对未知/缺失字段必须**防御式**处理(忽略而非崩溃)，以兼容未来新增字段。

### 5.2 `wall` (broker→controller，设备墙快照)
```json
{"type":"wall","payload":{
  "server_time":1750000000000,
  "groups":[
    {"group_id":"lobby","name":"大厅","sync":true,
     "playlist_id":"pl-lobby-1",
     "members":["win-lobby-01","and-lobby-02"]}
  ],
  "devices":[ { /* 同 5.1 的 status 字段子集 + last_seen */ } ]
}}
```

---

## 6. 媒体与缓存

### 6.1 媒体单元 (media item)
```json
{"item_id":"a1","type":"video|image","name":"promo.mp4",
 "url":"http://nas.local/media/promo.mp4",   // WebDAV 或 HTTP GET，避开 SMB
 "size":10485760,"sha256":"…",               // 完整性校验
 "duration_ms":60000,   // image 必填(轮播停留时长);video 可选
 "loop":false}
```

### 6.2 `cache_prefetch` (controller→broker→group/player)
```json
{"type":"cache_prefetch","payload":{"items":[ {/*media item*/} ]}}
```
被控端后台**断点续传**下载到本地缓存目录，下载完按 `sha256` 校验，结果反映在 `status.cache`。

### 6.3 `playlist` (controller→broker→group)
```json
{"type":"playlist","payload":{
  "playlist_id":"pl-lobby-1",
  "group_id":"lobby",
  "sync":true,                 // true=组内同步同一内容; false=各自独立(每台一组时即“各播各的”)
  "loop":true,
  "items":[ {/*media item*/}, … ]   // 长度 1 即“单文件”;>1 即“轮播”
}}
```

### 6.4 缩略图 (player→broker→controller，设备墙预览)
- player 每 ~5s 截当前帧，缩放为 ≤320px 宽的 JPEG。
- 先发一个 JSON `thumb_meta`(`device_id`,`seq`,`bytes`,`mime`),紧跟一个**二进制帧**承载 JPEG 数据。broker 转发给 controller。
- 带宽控制：仅当至少一个 controller 在线时才采集/上报。

---

## 7. 设备发现 (UDP 广播，同网段)

- 被控端后台监听 UDP `8772`。
- 遥控端(或 broker)广播 `discover` 包(UDP 广播地址)，被控端单播回 `announce`：
```json
// announce (UDP, 同样带 §3 的 sig 字段以防伪造)
{"v":1,"type":"announce","payload":{
  "device_id":"win-lobby-01","device_name":"大厅左屏",
  "ip":"192.168.1.50","broker_hint":"192.168.1.10:8770"}}
```
- 用途：自动刷新设备列表、回填 IP。**控制仍走 broker WS**;UDP 仅做发现/兜底。
- 遥控端持久化“上次成功设备清单(IP+名)”，重启先按缓存直连发现，连不上再广播。

---

## 8. 时钟同步 (同步播放的命门)

**不依赖系统 NTP。** 复用 WS 长连接做 SNTP 式握手：

### 8.1 `time_sync` 往返 (player↔broker，连接后 + 每 30s)
```json
// player→broker
{"type":"time_sync","payload":{"t1": <player_send_ms>}}
// broker→player (回包带 broker 收发时刻)
{"type":"time_sync_ack","payload":{"t1":<echo>,"t2":<broker_recv_ms>,"t3":<broker_send_ms>,"req_msg_id":"<echo player msg_id>"}}
```
- **[v1.1]** broker 在 `time_sync_ack.payload` 里回 `req_msg_id`(原 time_sync 的 `msg_id`)，player 优先用它关联请求，避免同毫秒 `t1` 撞车;无 `req_msg_id` 时回退用 `t1`(向后兼容)。
- player 收到时记 `t4`。按 NTP 公式：
  - `offset = ((t2 - t1) + (t3 - t4)) / 2`
  - `rtt = (t4 - t1) - (t3 - t2)`
- 取最近若干次中 **rtt 最小** 的 offset 为准，写入 `status.clock_offset_ms`。
- **broker 主时钟**(`server_time`)是全系统唯一权威时间轴。

### 8.2 起播折算
- 同步指令携带 `play_at`(**broker 主时钟**毫秒)。
- 各 player 起播本地目标时刻 = `play_at - clock_offset_ms`(把主时钟时刻折回本地时钟)。
- 目标精度 **±50–100ms**。长时间播放靠 §8.1 周期握手持续校正漂移。

---

## 9. 同步播放控制 (三段握手)

### 9.1 `prepare` (controller→broker→group)
```json
{"type":"prepare","payload":{
  "playlist_id":"pl-lobby-1","group_id":"lobby",
  "start_index":0,"seek_ms":0}}
```
- **[v1.1]** broker 给本次同步会话分配 `prepare_id`(= 该 prepare 的 `msg_id`)，扇出给 group 的 prepare 帧 payload 里带上 `prepare_id` 与 `group_id`。
- player 收到后：确认目标 item 已 `cache=ready`，预加载/seek 到位，**回 `ready`**(原样带回 `prepare_id` + `group_id`)。
```json
{"type":"ready","payload":{"device_id":"win-lobby-01","playlist_id":"pl-lobby-1","group_id":"lobby","prepare_id":"<echo>","ready":true}}
```
- broker 按 `prepare_id` 精确匹配会话(不再靠"每组至多一个在途 prepare"的假设)，支持同组并发会话。`prepare_id` 缺失时回退按 `group_id`+`playlist_id` 匹配(向后兼容)。

### 9.2 `play_at` (broker→group，收齐 ready 后)
- broker 收齐组内所有(在线)成员的 `ready`(或超时 2s 后对已就绪者)广播：
```json
{"type":"play_at","payload":{
  "playlist_id":"pl-lobby-1","group_id":"lobby",
  "start_index":0,"seek_ms":0,
  "play_at": 1750000003000   // broker 主时钟毫秒
}}
```
- 各 player 按 §8.2 折算，在本地目标时刻起播。

### 9.3 其它控制 (controller→broker→group/player)
| type | payload 关键字段 | 语义 |
|---|---|---|
| `pause` | `group_id`/`device_id` | 暂停 |
| `resume` | + `play_at` | 同步恢复 |
| `stop` | | 停止，回到黑屏/占位图 |
| `next`/`prev` | | 切 playlist 项(同步组走三段握手) |
| `set_volume` | `volume`(0–100),`device_id?` | 全组或单机音量 |
| `set_mute` | `muted`,`device_id?` | 静音开关 |
| `set_audio_master` | `device_ids:[…]` | 指定本组哪几台出声(其余静音)。**默认组内全部出声**;此命令用于按需指定子集 |
| `assign_group` | `device_id`,`group_id` | 改设备分组 |
| `set_schedule` | `schedule:[{cron,playlist_id}]` | 定时编排(几点切哪个 playlist) |

> **同步 vs 各播各的**：`playlist.sync=true` → 走 §9.1–9.2 三段握手同步起播;`sync=false`(典型场景:每台设备自成一组) → broker 直接对单机下 `play_at=now`，各放各的。**同一套消息，sync 标志切换两种模式。**

---

## 10. 运维类 (Phase 2 预留，先占位 type)

| type | 方向 | 语义 |
|---|---|---|
| `ota_check`/`ota_apply` | controller→broker→player | 远程更新被控端 |
| `reboot` | controller→broker→player | 远程重启被控端/机器 |
| `resume_last` | broker→player | 断电恢复后自动回到上次任务(player 本地也持久化 last task) |
| `ack` | 任意 | 对带 `msg_id` 命令的确认:`payload:{ack_of:"<msg_id>",ok:true,err:""}` |
| `error` | player→broker→controller | 异常上报 |

---

## 11. 黑屏防呆 (被控端硬约束)

- `idle`/`stop` 状态：被控端必须显示**纯黑或指定占位图**，全屏置顶，**严禁露出操作系统桌面/任务栏**。
- Windows：mpv 无边框全屏置顶 + 隐藏任务栏 + 看门狗;Android:kiosk/锁定任务 + 开机自启。
- 崩溃/假死：看门狗在 5s 内重启播放进程并 `resume_last`。

---

## 12. 版本与兼容

- 本文件即 v1 合同。破坏性变更必须升 `v` 并在 broker 做双版本兼容窗口。
- 各端启动时打印自己实现的协议版本;broker 在 `welcome` 里回 `v`，端侧不匹配时告警但尽量降级兼容。

---

# v1.2 增补 — 易用性三件套(可选鉴权 / 拓扑模式 / 零配置配对)

> **v1.2 仍是向后兼容的加法**,`v` 保持声明为 `1`,实现可声明 minor=2。
> 三大目标:**默认零配置能跑**、**安卓端免手输**、**broker 形态可选(含彻底无 broker)**。
> 所有现有字段语义不变;v1.1 及更早实现与 v1.2 broker 互通(详见各节兼容说明)。

## 13. 鉴权模式 (auth_mode) — §3 的可选化

§3 的 HMAC 仍是**唯一**鉴权机制,但是否强制由部署侧的 `auth_mode` 决定。引入三档:

| auth_mode | 发送方 `sig` | 接收方校验 | ts 时效 + msg_id 去重 | 适用 |
|---|---|---|---|---|
| `open`(**默认**) | 允许为 `""`(空串) | **不验签** | **仍执行**(防重放卫生,不需密钥) | 家庭/展厅/可信局域网,零配置 |
| `optional` | 有 PSK 就签,没有填 `""` | `sig` 非空才验,空则放行 | 仍执行 | 迁移过渡期 |
| `required` | 必填合法 `sig` | **强制验签**,失败丢弃 | 仍执行 | 不可信网络,可叠加 WSS |

- **协调端(broker / cohost / P2P controller)的 `auth_mode` 是该拓扑的权威**,在 `welcome.payload.auth_mode`(string)与 UDP `announce.payload.auth_mode` 中声明。
- 被控端/遥控端**自适应**:连上后读 `auth_mode`,据此决定是否在出站帧填 `sig`。无 PSK 的端遇到 `required` → 软错误(继续重试,UI 提示需要密钥),不崩。
- `open` 模式下 `sig` 字段**仍存在**(填 `""`),信封结构 §2 不变,`parse` 不报错。
- 鉴权失败计数/冷却(§3 末)**仅在 `required` 生效**。
- **兼容**:老的 `required`-only 实现收到 `sig:""` 会判失败丢弃——这是预期的(两端模式不一致时本就不该互通);同模式间完全兼容。

## 14. 拓扑模式 (topology) — broker 形态可选

同一套消息(§2–§12)在三种拓扑下都成立,**消息格式不变**,只是"谁扮演协调者"不同。协调端在 `welcome.payload.topology` 与 `announce.payload.topology` 中声明,供端侧诊断展示。

```
A. dedicated   遥控端 → broker(独立机/Docker) → 被控端 ×N        ← 现状,30 屏正式部署
B. cohosted    遥控端 → broker(寄生在某台被控端进程内) → 被控端 ×N ← 零额外机器,推荐兜底
C. p2p         遥控端 ⇄ 被控端 ×N(无 broker,遥控端兼任协调)     ← 彻底无 broker,接受退化
```

### 14.1 模式 A `dedicated`(现状)
broker 独立进程/容器,被控端与遥控端都**作为 WS 客户端**拨向 broker。即 §0–§12 原样。

### 14.2 模式 B `cohosted`(被控端兼职 broker)
- **同一份 broker 实现**寄生在某台被控端进程内(被控端启动参数 `--broker` 或设置项"我来当协调中心")。对**其它端完全透明**:它就是一个恰好和某台 player 同机的 broker,监听 8770。
- 该机的 player 子模块作为**本机 WS 客户端**连 `127.0.0.1:8770`,与其它被控端无差别。
- 通过 §7 UDP `announce` 把自己的 `broker_hint` 广播出去,其它端自动发现并连接。
- **无任何协议改动**——纯部署形态。

### 14.3 模式 C `p2p`(彻底无 broker,纯直连)
无 broker 进程。**遥控端兼任协调者**,直接连每台被控端。明确的退化代价见 §14.4。

角色翻转(这是模式 C 唯一的实质性新增):
- **被控端在 p2p 模式下运行一个 WS 服务端**(监听 8770),而非拨向 broker。其余行为(播放/缓存/状态/三段握手响应)完全照旧。
- **遥控端作为 WS 客户端**,通过 §7 UDP 发现各被控端后,对每台**各开一条 WS**。
- **遥控端 = 主时钟**。被控端的 §8 `time_sync` 直接发给遥控端,遥控端回 `time_sync_ack`(扮演原 broker 的时钟角色)。`server_time` = 遥控端本地时钟。
- **三段握手由遥控端直接编排**(§9):遥控端把 `prepare` 分发给目标各被控端 → 收齐 `ready`(或 `ready_timeout_ms` 超时)→ 算 `play_at = controller_now + buffer_ms` → 发给各被控端。即遥控端在客户端侧本地完成原 broker 的扇出与收齐逻辑。
- **路由**:`to:"player:<id>"` 走对应那条直连 socket;`to:"group:<gid>"` 由遥控端**客户端侧展开**为对组内每个成员逐条发送(无 broker 代为扇出)。
- **状态墙**:遥控端直接聚合各被控端的 `status`,本地渲染设备墙(无 broker 的 `wall` 聚合帧;遥控端自己合并)。
- **welcome**:被控端 WS 服务端在遥控端连入时回 `welcome`(扮演 broker),带 `topology:"p2p"`。

### 14.4 模式 C 的明确退化(实现与文档都要写清)
- **同步精度**:协调者(遥控端)通常在 WiFi 上,抖动比有线 broker 大;主时钟随遥控端走,遥控端断开则同步会话中断。目标精度从 ±50–100ms 放宽到**尽力而为(典型 ±100–200ms)**。
- **规模**:遥控端要同时维持 N 条连接并本地扇出,**适合小规模(经验值 ≤8 台)**;30 屏仍应用模式 A/B。
- **多遥控端**:p2p 下不建议多个遥控端同时控同一批被控端(无 broker 做单一真相源,时钟主可能打架)。如需多控,用模式 A/B。
- **持久化**:无 broker 的 `state.json` 注册表;遥控端在本地持久化"上次设备清单"作为兜底(§7 已有)。

### 14.5 模式选择与发现(零配置默认)
- 端侧默认**自动**:被控端启动先 UDP 广播找协调者(§7)。
  - 收到 `announce`(模式 A/B 的 broker)→ 作为客户端连过去。
  - **超时无 broker** → 被控端自动进入 **p2p 服务端模式**(监听 8770),等遥控端直连。
- 遥控端启动先 UDP 发现:
  - 发现 broker → 模式 A/B,连 broker。
  - 只发现一堆 p2p 被控端、无 broker → 模式 C,逐台直连。
- 三种模式下用户**都不必手填 IP**——能发现就自动连。手填/扫码仅作发现失败的兜底。

## 15. 二维码配对与 `lmw://` 配对 URI(免手输)

为安卓被控端等"输入不便"的场景提供免手输配对。

### 15.1 配对 URI 格式
```
lmw://pair?host=<ip>&port=<8770>&group=<gid>&mode=<open|optional|required>&psk=<hex?>&wss=<0|1>&name=<可选预设名>
```
- `open` 模式下**不含 `psk`**(纯"扫一下进组")。
- `required`/`optional` 模式下 `psk` 为 §3 的 32+ 字节 hex;二维码即"带密钥的入场券"。
- 字段做标准 URL 编码;未知 query 参数接收方**忽略**(向前兼容)。

### 15.2 谁生成、谁消费
- **生成**:遥控端"添加设备/邀请"页,或 broker 启动日志/管理页,生成上述 URI 并渲染成二维码。
- **消费**:被控端首启设置页提供"扫码配对",扫码后自动填好 host/port/group/mode/psk,免手输直接连。也支持遥控端扫码导入 broker 连接信息。
- 纯客户端能力,不上 WS;不改 §2–§12 任何帧。

### 15.3 默认值哲学
- 出厂默认 `auth_mode=open` + 自动发现 → **理想情况零输入零扫码即可联通**。
- 想要安全 → 协调端切 `required`,把带 PSK 的二维码发给各端扫一下即可。
- 安全是**可选叠加项**,不是上手前置门槛。

## 16. 关联 id 澄清(v1.2 — 三端实现反馈固化)

实现 broker / windows_player / android player 时,三端独立反馈了同一组「同步会话关联」歧义。本节把**当前已验证的 fallback 行为固化为正式契约**,并把**显式 id 列为可选推荐**。全部向后兼容,旧端无需改动。

### 16.1 `prepare` ↔ `ready` ↔ `play_at` 会话关联
- **正式契约(fallback,各端已实现并通过测试)**:一个同步会话由 `group_id` + `playlist_id` 唯一标识;broker 以「每组同一时刻至多一个在途 `prepare`」为前提,用 `group_id` 匹配 `ready`,用 `group_id`+`playlist_id` 关联 `play_at`。设备在 `prepare`→`ready` 之间不得切组。
- **可选推荐(未来收紧并发能力时启用)**:broker 在 fanout `prepare` 前注入 `prepare_id`(= 该 prepare 的 `msg_id`):`p = {**p, "prepare_id": env["msg_id"]}`;players 收到后在 `ready` 中回显 `prepare_id`。携带时 broker 优先按 `prepare_id` 精确匹配,缺失时回落到 `group_id` 匹配。启用后可支持「每组多个并发 prepare」。

### 16.2 `time_sync_ack` 关联(同毫秒 `t1` 碰撞)
- **正式契约(fallback)**:`time_sync_ack.payload = {t1(echo), t2, t3}`,客户端按回显的 `t1` 关联请求。
- **可选推荐**:broker 在 `time_sync_ack.payload` 附带 `req_msg_id`(原 `time_sync` 的 `msg_id`)。客户端携带时优先按 `req_msg_id` 关联,消除同毫秒 `t1` 碰撞的歧义;缺失时回落到 `t1`。

### 16.3 `wall.devices[]` 状态子集字段
§5.2 的「§5.1 状态子集 + last_seen」**正式约定**为:至少含 `device_name`、`group_id`、`last_ip`、`online`、`last_seen`,外加最近一次 `status` 的全部字段。controllers 必须对未知/缺失字段做防御式处理(向前兼容)。

### 16.4 `controller_present` 缩略图门控(§6.4)
§6.4 的「仅当 ≥1 controller 在线时采集缩略图」**正式约定**:在 broker 提供 presence 信号前,players 用本地配置 `thumbnail.always_collect`(默认 `false`)门控;需常态供墙的设备置 `true`。**可选推荐**:broker 在 `welcome` 加 `controllers_online:int`,或周期性推 `controller_presence{present:bool}`,使 players 精确门控。

---

## 17. 派生密钥 (key derivation) — §3 密钥的泄露隔离 (v1.3)

> **v1.3 变更(向后兼容的加法)**:§3 的签名**字符串布局、canonical JSON、ts 时效、msg_id 去重**全部不变;唯一变化是 HMAC 使用的**密钥**从"全系统单一 PSK"升级为"按端身份派生的 device_key",使任一被控端泄露不再污染全局。仅影响 `auth_mode=optional/required`(签名生效)的场景;`open` 模式不涉及密钥,行为完全不变。

### 17.1 动机
v1.2 全系统共享单一 PSK:任一墙机(常年裸放展厅/大厅)被物理接触导出 PSK,即可伪造**任意端**(含 broker)的指令。派生密钥让每端只持有自己那把 key,broker 持 PSK 现场派生验签,攻破一台只暴露该台。

### 17.2 派生函数
```
device_key = HMAC_SHA256(PSK, identity).digest()        # 32 bytes
```
- `identity` = 该端 envelope 的 `from` 字段**完整字符串**,逐字节参与派生:
  - player:    `"player:<device_id>"`   (如 `"player:win-lobby-01"`)
  - controller:`"controller:<id>"`
  - broker:    `"broker"`
- 签名:`sig = HMAC_SHA256(device_key, signing_string(§3)).hexdigest()`,其中 `device_key` 是**发送方自己 identity** 派生的 key。
- 验签:接收方从被验帧的 `from` 字段取 identity → 用 PSK 派生该 identity 的 device_key → 重算 `sig` 比对。**broker 持 PSK,可对任意 `from` 现场派生,无需保存每端 key(无状态)。**

### 17.3 key_mode 协商(向后兼容)
| key_mode | 签名 key | 适用 |
|---|---|---|
| `derived`(**v1.3 默认**) | 按 §17.2 派生的 device_key | 新部署;泄露隔离 |
| `global`(v1.2 兼容) | 直接用 PSK(= 旧行为) | 与未升级的老端互通 |

- **协调端(broker / cohost / P2P controller)的 `key_mode` 是该拓扑的权威**,在 `welcome.payload.key_mode`(string)与 UDP `announce.payload.key_mode` 中声明。缺省/缺失字段 → 接收端按 `global` 处理(= v1.2 行为,向后兼容)。
- 被控端/遥控端连上后读 `key_mode`,据此决定**出站帧用 device_key 还是 PSK 签名**,并用同样口径验入站帧。
- `open` 模式下不签不验,`key_mode` 无意义(可省略)。

### 17.4 密钥分发与零感知约束(**硬约束**)
**部署体验与 v1.2 完全一致,不得新增任何 per-device 配置。**
- broker 仍只在部署时配置**一个 PSK**(`auth_mode=required/optional` 时);`open` 模式连 PSK 都不需要。
- 各被控端/遥控端**不再持有 PSK**,而是通过**已有的 §15 配对 URI / QR** 获得自己那把 `device_key` + 自身 `identity`:
  - 配对 URI 在 `required/derived` 下携带的字段从 `psk` 改为 `dk`(device_key 的 hex/base64)+ `id`(identity),不再下发 PSK 给端。
  - 用户操作不变:broker 出码、端扫码,仍是一步。
  - 派生 device_key 由 broker 在出码时用 PSK 现场算出嵌入 QR;端只存 device_key,**永不接触 PSK**。
- 兼容回退:若配对 URI 仍下发 `psk`(老 broker / `key_mode=global`),端按 v1.2 全局 PSK 行事。

### 17.5 实现一致性红线(四端必须逐字一致)
- 派生输入 `identity` = `from` 字段完整字符串,**不做任何归一化/小写化/裁剪**。
- `device_key` 是 32 字节**二进制** HMAC 输出,作为下一层 HMAC 的 key 直接使用(不要 hexencode 后再当 key)。
- broker 扇出/下行帧 `from="broker"`,用 `HMAC(PSK,"broker")` 派生的 key 签名;各端验 broker 帧时按 `from="broker"` 派生验签。
- **泄露隔离的契约符合性证据(每端必须有此负向测试)**:用 identity-A 派生的 key 去签一个 `from=identity-B` 的帧,接收方验签**必须失败丢弃**。

---

# v1.4 增补 — 分组管理 / 设备配置 / 本地媒体上传 / 预缓存栅栏

> **v1.4 仍是向后兼容的加法**,`v` 保持声明为 `1`,实现可声明 minor=4。
> 面向控制端(遥控端)重做(见 `docs/controller-ux-redesign.md`)补齐四类能力:
> **① 显式分组管理(新建/删/改)**、**② 设备配置(改名/设组)**、
> **③ 本地媒体上传(A 手机临时 HTTP / B broker 媒体库)**、**④ 预缓存栅栏(全员就绪才起播)**。
> 旧端(v1.1–1.3)无需改动;不认识新 `type` 的端按 §10 "unknown type 忽略" 处理。

## 18. 分组管理 (group management) — 补齐"不能新建组"

v1.3 及之前只有 `assign_group`(改设备的组),组只能被动地随成员出现;**无法从零新建一个空组**。
v1.4 引入显式分组管理命令(controller→broker),broker 侧落到注册表 group meta 并持久化,
随后在 §5.2 `wall` 快照的 `groups[]` 中反映。

### 18.1 `create_group` (controller→broker)
```json
{"type":"create_group","payload":{"group_id":"hall-2","name":"二号厅","sync":true}}
```
- `group_id`(必填):稳定标识,建议 ASCII slug;已存在则视为 no-op(幂等)或按 `update_group` 语义更新 meta。
- `name`(可选):显示名,缺省用 `group_id`。
- `sync`(可选,默认 `true`):组内同步模式,见 §6.3 / §9。
- broker 处理:`registry.set_group_meta(group_id, name=, sync=)` → 标记 wall dirty → 下一帧 `wall` 含该空组(`members:[]`)。

### 18.2 `update_group` (controller→broker)
```json
{"type":"update_group","payload":{"group_id":"hall-2","name":"二号大厅","sync":false}}
```
- 只更新给出的字段(`name`/`sync`);未给的保持不变。`group_id` 不可改(改名走 `name`,换 id 请新建+迁移成员)。

### 18.3 `delete_group` (controller→broker)
```json
{"type":"delete_group","payload":{"group_id":"hall-2","reassign_to":"default"}}
```
- 删除组 meta;组内成员**回落**到 `reassign_to`(缺省 `default`,即 §4 的 `DEFAULT_GROUP`)。
- `default` 组不可删除(broker 忽略对 `default` 的删除请求)。
- broker 处理:把成员 `assign_group` 到 `reassign_to` → 删 meta → 通知受影响 players 新组 → wall dirty。

## 19. 设备配置 (configure_device) — 补齐"不能设置盒子配置"

统一的 per-device 配置命令,替代/补充零散的 `assign_group`。controller→broker→player。
```json
{"type":"configure_device","payload":{
  "device_id":"and-hall-03",
  "device_name":"二号厅右屏",   // 可选:改显示名
  "group_id":"hall-2",         // 可选:设分组(等价 assign_group,统一入口)
  "volume":70,                 // 可选:持久音量偏好
  "muted":false                // 可选
}}
```
- 只处理 payload 中出现的字段;缺省字段不动。
- broker 处理:更新注册表(`device_name`/`group_id` 持久化)→ 转发给目标 player(`to:"player:<id>"`)
  让其应用本地偏好(如 `volume`/`muted`)→ wall dirty。
- `group_id` 与 `assign_group` 语义一致;`assign_group` 保留(向后兼容),`configure_device` 是超集统一入口。

## 20. 本地媒体上传 (A + B) — 补齐"图片视频不能上传本地"

**播放模型不变**:被控端始终从**本地缓存**播放(§6.2 `cache_prefetch` 下载+`sha256`校验+断点续传)。
"上传"= 让控制端本地文件在**分发窗口**变成被控端可 GET 的 URL,下载完控制端即可离线。
两条路,由控制端按当前拓扑自动择一(§14.5):

### 20.1 模式 B — broker 媒体库 (broker/cohosted 模式主路径)
- broker 额外监听一个 **HTTP 媒体端口**(默认 `8773`,与 WS `8770`/WSS `8771`/UDP `8772` 并列),提供:
  - **上传**:`PUT /media/<sha256>.<ext>`(或 `POST /media` 带 sha256 query),body = 文件二进制。
    - broker 校验落盘内容的 `sha256` 与文件名/参数一致,不一致 `400` 拒绝。
    - 幂等:同 `sha256` 已存在则直接 `200`(秒传,不重复写)。
    - 大小上限默认 **500MB**(可配 `media_max_bytes`),超限 `413`。
  - **下载(静态服务)**:`GET /media/<sha256>.<ext>`,支持 `Range`(断点续传,被控端 §6.2 依赖)。
- 上传成功后,该文件的可 GET URL = `http://<broker_host>:<media_port>/media/<sha256>.<ext>`,
  写进 media item 的 `url`,随 `playlist`/`cache_prefetch` 下发。被控端零改动复用现有下载链路。
- 媒体端点**不承载控制语义**,不参与 §2 信封/§3 签名。下载默认开放供被控端缓存;上传默认兼容开放,但 broker 可配置 `media_upload_token` 要求 `Authorization` 头携带 bearer token 才允许 `PUT/POST`。需要收窄暴露面时可把 `media_bind_host` 设为 `127.0.0.1` 并放在反代后。

### 20.2 模式 A — 控制端临时 HTTP (p2p / 无 broker 兜底)
- 无 broker 时,控制端本机起一个**临时 HTTP 服务**(仅分发窗口存活),对选中的本地文件提供:
  - `GET /m/<item_id>`(或 `/media/<sha256>`),支持 `Range`。
- media item 的 `url` 指向控制端 LAN IP:`http://<controller_ip>:<ephemeral_port>/m/<item_id>`。
- 被控端从控制端 GET 到本地缓存 + `sha256` 校验(链路与模式 B 完全一致,只是源是手机)。
- **全员 `cache=ready` 后**(§21 栅栏)才广播 `play_at`;起播后控制端可关服务/离线,被控端放本地缓存。

### 20.3 media item 的 url 回填 (§6.1 扩展)
- §6.1 的 `url` 语义扩展:除 `http://nas.local/...` 外,现也可为**上传回填**的 broker 媒体库 URL(模式 B)
  或控制端临时 HTTP URL(模式 A)。`sha256`/`size`/`duration_ms` 语义不变,仍用于完整性校验与图片停留。
- 控制端**必须**为本地上传的 item 计算并填 `sha256` 与 `size`(被控端据此校验缓存完整)。

## 21. 预缓存栅栏 (prefetch barrier) — "等所有设备下载完成再统一从头起播"

保证一组设备**全部缓存就绪后同一时刻从头起播**,而不是各自下载完各自乱起播。

### 21.1 就绪定义强化 (§9.1 `ready` 的语义收紧)
- §9.1 `prepare`→`ready` 中,player 回 `ready:true` 的**前置条件收紧**为:
  目标 playlist 的**所有 item** `cache=ready`(下载完 + `sha256` 校验通过)且预加载/seek 到位。
- 未就绪(仍在 `downloading`/校验中)→ player **不回 `ready`**(或回 `ready:false` 带 `reason:"caching"`),
  待缓存完成后再回 `ready:true`。broker/协调端据此收齐。

### 21.2 栅栏与超时 (broker 模式)
- broker 收齐组内所有(在线)成员的 `ready:true` → 广播 `play_at`(§9.2),全员同一 `play_at` 从 `start_index=0` 起播。
- 超时:等待上限默认 **120s**(可配 `prefetch_barrier_timeout_ms`,区别于 §9 的短 `ready_timeout_ms`)。
  到时对**已就绪者**起播,并在设备墙/日志**明确标出未就绪台**(不静默)。
- 控制端 UI 在栅栏期间显示每台下载进度(来自 §5.1 `status.cache`)与就绪计数(如 "3/5 已就绪")。

### 21.3 栅栏与 p2p 模式
- p2p 下由控制端(兼任协调端,§14.3)本地编排同一栅栏:fan `prepare` → 收齐各直连被控端 `ready:true`
  (或 120s 超时)→ 算 `play_at = controller_now + buffer_ms` → 发给各被控端。逻辑与 broker 模式一致,只是执行方是控制端。

## 22. §9.3 命令表增补 (v1.4)
| type | payload 关键字段 | 语义 |
|---|---|---|
| `create_group` | `group_id`,`name?`,`sync?` | 新建空分组 (§18.1) |
| `update_group` | `group_id`,`name?`,`sync?` | 改组名/同步模式 (§18.2) |
| `delete_group` | `group_id`,`reassign_to?` | 删组,成员回落 (§18.3) |
| `configure_device` | `device_id`,`device_name?`,`group_id?`,`volume?`,`muted?` | 设备配置统一入口 (§19) |

> 以上 group 管理与 configure_device 均为 controller→broker(configure_device 再转发 player);
> 媒体上传走 §20 的 HTTP 媒体端口,不经 WS 信封。

# v1.5 增补 — 远程自更新 (update_app)

## 23. 远程自更新 (update_app) — 免逐台 adb 刷机

补齐"换新版要一台台连 adb"的痛点:控制端下发一条命令,被控端**自己拉取新 APK 并 root 安装**。
针对 4.4 外贸盒——这些盒子默认 `su`/`adb root`,但假容量闪存喂错 `recommendAppInstallLocation`,
`pm install`/PackageInstaller 会 `INSTALL_FAILED_INVALID_INSTALL_LOCATION`,所以走
`scripts/deploy_player.sh` 同款可靠路径:`su` 把 APK 复制进 `/data/app/<pkg>-1.apk` → `chmod 644` →
`reboot`,由开机包扫描采纳。

### 23.1 消息
| type | 方向 | payload 关键字段 | 语义 |
|---|---|---|---|
| `update_app` | controller→(broker→)player | `device_id`/`group_id`,`version_code`,`url`,`sha256`,`version_name?` | 令目标被控端自更新到 `url` 指向的 APK |
| `update_status` | player→coordinator | `device_id`,`state`,`detail?`,`version_code` | 回报进度:`downloading`/`installing`/`rejected`/`failed`;broker 将其并入设备墙状态(`update_state/update_detail/update_version_code`) |

- `url` 指向 broker 媒体库(§20 HTTP 端口)上的 APK,支持 Range 断点续传;若 broker 配置了 `media_upload_token`,控制端设置页需填写同一 token 供 APK 上传使用(下载仍按 URL 开放给被控端拉取)。
- `version_code` 为**目标 APK 的 Android versionCode**(整数,单调递增)。

### 23.2 四条安全护栏(被控端**必须**全部满足才安装)
1. **授权帧**:broker 模式下 `update_app` 帧的 §3 签名**必须验签通过**(`authed`)；P2P 直连模式下,来自已接入本机 P2P 控制链路的 `update_app` 视为本地操作者授权,可用于零配置首装后的自更新。非鉴权 broker 帧与非 P2P 本地链路帧一律拒绝(`rejected:unauthorized`)。
2. **版本单调**:`version_code` **必须严格大于**当前运行版本,否则拒(`rejected:not-newer`),防降级/重放旧指令。
3. **完整性**:`url` + 64 位十六进制 `sha256` 必填;下载完成后**重算 sha256 比对**,不符则删除文件、拒装
   (`failed:sha256-mismatch`),绝不半装。
4. **同签名**:Android 平台在开机包扫描升级时**强制同签名者**,签名不符的 APK 被 PackageManager 拒——平台层免费保证,无需额外代码。

### 23.3 边界
- 仅内网。broker 模式建议使用 §13 `auth_mode`≠`open` + PSK；P2P 直连更新依赖物理在场/同网段控制端临时 HTTP URL,不要暴露到公网。
- 无 root(`su` 不可用)→ 回 `failed:no-root`,不影响其他功能。
