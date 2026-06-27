# NOTES_TO_UPSTREAM — flutter_controller (§17 派生密钥)

本端按 protocol_spec.md v1.3 §17 落地派生密钥。以下是实现决策与待上游确认项
（协议疑问不改 spec，按当前契约默认继续，已全绿）。

## 1. 派生函数与签名 key（§17.2，四端逐字节一致）
- `deriveDeviceKey(psk, identity)` = `Hmac(sha256, utf8(psk)).convert(utf8(identity)).bytes`
  → 32 字节二进制，直接作下一层 HMAC 的 key（**未** hex 后再当 key）。
- 与 broker `broker/envelope.py:derive_key`
  (`hmac.new(psk.encode, identity.encode, sha256).digest()`) **逐字节一致**，
  `test/derived_key_test.dart` 用独立参考实现交叉验证。
- `identity` = envelope `from` 字段完整字符串，**不归一化/不小写/不裁剪**（有测试覆盖）。
- 出站：`sig = HMAC(本端 identity 派生的 device_key, signing_string).hexdigest()`。
- 验签：从被验帧 `from` 取 identity → 用 PSK 现场派生 → 重算比对（broker 无状态模型）。

## 2. key_mode 协商（§17.3）
- `KeyMode.parse`：仅 `"derived"` → derived，其余（含缺失/空/未知）→ **global**（向后兼容）。
- broker 模式：`welcome.payload.key_mode` 为权威；`BrokerClient` 在**验签前**先按 welcome
  声明校正 `authMode`/`keyMode`，再验（否则引导期口径不符会把 welcome 自身丢弃）。
- p2p/cohost 模式：controller 兼任协调端，自身 `keyMode` 即权威，随 `hello` 下发
  `auth_mode`+`key_mode` 给各 player（`P2pCoordinator._sendHello`）。持 PSK → derived，
  无 PSK(open) → global。

## 3. 配对 URI（§15 + §17.4）
- derived + 已知受邀端 id → QR 携带 `km=derived&dk=<hex>&id=<identity>`，**绝不含 psk**。
- global / derived 但未指定受邀端 → 携带 `psk`（兼容回退）。
- open → 不含任何密钥字段。
- `km` 缺失 → global（兼容老 broker 的 psk 码）；未知 query 字段忽略（向前兼容，含 `bk`）。
- 与 `broker/pairing.py` 的 `km/dk/id` 字段布局一致。

## 4. 待上游确认（详见 repo-root FEEDBACK_TO_UPSTREAM.md 的 [flutter_controller] 段）
- **controller 双角色 vs §17.4 "端不持 PSK"**：controller 是操作者可信端 + 动态兼任
  协调端，默认沿用 PSK-in-settings（leaf 能验 broker 下行、coordinator 能派生验 N 台）。
  出码邀请 player 时绝不下发 PSK。等上游确认是否接受。
- **零 PSK leaf 验 broker 帧的 gap**（与 windows_player 同）：当前实现 fail-closed
  （无 PSK 且 from≠本端 → 验签失败丢弃，不崩溃）。支持 `bk` 增量字段方案，但其派生
  identity 须随拓扑变化（broker→`"broker"`；p2p/cohost→协调端 `controller:<id>`）。

## 5. 性能：未加 per-`from` 派生 key 缓存（broker 为 30 台扇入加了）
controller 扇入形态不同：leaf 只见单一 identity；p2p 协调端 ≤8 台（§14.4）且每帧仅多算
一次 ~15B 短串 HMAC（µs 级）。`from`-keyed 缓存会重新引入 §17.2 刻意去掉的状态、且 key 来自
不可信 `from`（无界增长）、并与 PSK/keyMode 失效耦合 —— 净负收益，故不加。p2p 规模逼近 30 再议。
