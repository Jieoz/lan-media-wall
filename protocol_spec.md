# LAN Media Wall — 通信协议规范 (Protocol Spec) v1.1

> 这是 broker / Windows 被控端 / Android 被控端 / Flutter 遥控端 **共同遵守的合同**。
> 任何一端都不得擅自更改字段名或语义；如需扩展，只能新增 `type` 或在 `payload` 里加可选字段，并升 `v`。
>
> **v1.1 变更(全部向后兼容的加法，`v` 仍声明为 `1`，实现可声明 minor=1)**：根据三端实现反馈，补齐了同步会话关联、wall 字段集、welcome 字段、time_sync 关联与 controller 在线信号等歧义点。详见各节 `[v1.1]` 标注。

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
