# FEEDBACK_TO_UPSTREAM — windows_player (§17 派生密钥)

## [windows_player] 零感知派生模式下,端如何**验签 broker 下行帧**?(spec gap)

**问题**:§17.4 规定各被控端"只存自己的 `device_key`,永不接触 PSK";配对 URI 在 derived 下把 `psk` 换成 `dk`+`id`。但 §17.2 要求接收方验 broker 帧时,需用 `HMAC(PSK,"broker")` 派生 broker 的 key 才能比对 `sig`。一个**零 PSK** 的端**没有 PSK,也没有 broker 的 key**,因此无法验任何 broker 下行帧 —— 在 `required` 下会把所有 broker 帧丢弃,端不可用。spec §17.4 对"端如何验 broker 帧"未着墨。

**我的默认实现(安全且可逆,向后兼容)**:
配对 URI 在 derived 模式下,除了端自己的 `dk`(device_key hex)+`id`(identity),**再携带一个可选字段 `bk`** = broker 的验签 key 的 hex = `HMAC(PSK,"broker").hexdigest()`,由 broker 出码时现场算出嵌入 QR。端存 `bk` 仅用于**验** broker 下行帧,绝不用于签名,端仍永不接触 PSK。
- `bk` 缺失时:若端持有 PSK(老/混合部署),按 §17.2 现场派生验签;两者都没有 → 该端在 derived+required 下无法验 broker 帧(记录软错误,保持连接,不崩溃)。
- `bk` 是**纯增量字段**:老端忽略未知 query 参数(§15.1 向前兼容),不影响 global/老部署。
- 协调端(p2p/cohost,持 PSK)不受影响:对任意 `from` 现场派生验签,无状态。

**理由**:这是让"零 PSK 端"在 derived 下能验 broker 帧的**唯一**方式(否则要么端持 PSK 违反 §17.4,要么端验不了任何下行)。`bk` 只下发"验 broker 这一把公钥性质的 key",不暴露 PSK,泄露一台端只暴露 `dk`(自己)+`bk`(全网共享的 broker 验签 key)——`bk` 本身不能用来伪造任意 `from`(它只对 `from="broker"` 有效),仍满足泄露隔离的核心目标(攻破一台端不能伪装成**其他端/controller**)。

**请上游确认**:是否把 `bk` 字段正式写入 §15.1 / §17.4。我已按上述默认实现并继续,不阻塞。

---

## [flutter_controller] §17.4 "各端不再持有 PSK" 与 controller 的双角色 — 我的默认

**问题**:§17.4 硬约束"各被控端/遥控端不再持有 PSK"。但 controller 在本仓是**动态双角色**(`WallState._evaluateTopology`):
- **leaf**(连真 broker):纯客户端,理应零 PSK —— 此时撞上 windows_player 提的同一 gap(零 PSK 端验不了 broker 下行帧)。
- **coordinator**(p2p/cohost 兼任 broker,§14.3):它就是 §17.2 里"持 PSK、对任意 from 现场派生验签"的协调端角色,**必须**持 PSK 才能验 N 台 player 的帧。零 PSK 的 p2p 协调端无法验任何 player 帧 = 不可用。

**我的默认(安全、可逆、零新增配置)**:controller **沿用 v1.2 的 PSK-in-settings 模型**(PSK 存本端 settings)。理由:§17.1 的威胁模型针对"常年裸放展厅的墙机被物理接触",controller 是**操作者随身可信端**,不在该威胁面内;持 PSK 让它在 leaf 角色能验 broker 下行、在 coordinator 角色能对任意 from 派生验签,两边都工作且零新增配置、字节级兼容。
- controller **出码邀请 player** 时,在 derived 下只下发 player 自己的 `dk`+`id`(player 才是裸放的被控端),**绝不把 PSK 放进 QR**——这条严格遵守 §17.4。
- controller 的 `PairUri.tryParse` **优雅忽略**未知字段(含 windows_player 提议的 `bk`),向前兼容;若上游正式纳入 `bk`,我的 p2p 协调端出码会补发 `bk`=`HMAC(PSK,"controller:<coordinatorId>").hex`(注意:p2p 下下行帧 `from` 是 `controller:<id>` 而非 `broker`,故 `bk` 的派生 identity 应是**协调端自身 identity**,不是字面 `"broker"` —— 这一点请上游在 `bk` 定义里明确区分 broker 拓扑 vs p2p/cohost 拓扑)。

**对 `bk` 提案的补充**:支持 windows_player 的 `bk` 增量字段。但需在 §17.4 写清 `bk` 的派生 identity 随拓扑变化(broker 拓扑→`"broker"`;p2p/cohost→协调端的 `controller:<id>`),否则零 PSK 端在 p2p 下仍验不了协调端帧。

**请上游确认**:(1) controller 作为可信操作端保留 PSK 是否可接受(我已据此实现,全绿不阻塞);(2) `bk` 定义是否补上"派生 identity 随拓扑变化"。
