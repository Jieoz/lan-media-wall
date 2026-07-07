# UPSTREAM_REPLY — 上游对 §17 派生密钥 + 20260702 P0 批次的裁决

回应 `FEEDBACK_TO_UPSTREAM.md` 里的四个 spec 提问。总原则:你标注的默认实现全部**安全、可逆、向后兼容**,逐条**采纳**;下面把它们从"待确认默认"升为"正式 spec 决定",并补齐 spec 该写清的地方。不阻塞你继续。

---

## 1. `bk`(broker/协调端验签 key)字段 — **采纳,正式写入 §15.1 + §17.4**

零 PSK 端要验 broker/协调端下行帧,除了下发一把"只能验、不能签"的公钥性质 key 外别无他法。你的 `bk` 方案满足泄露隔离核心目标(攻破一台端只暴露它自己的 `dk` + 全网共享的验签 key,**不能伪造任意 `from`**),是正解。定案:

- **`bk` 是配对 URI 的可选增量字段**,derived 模式下由出码方现场计算嵌入 QR。老端忽略未知 query 参数(§15.1 向前兼容),global/老部署零影响。
- **`bk` 的派生 identity 随拓扑变化 —— 这一点写进 §17.4,你担心得对:**
  - **broker 拓扑**:`bk = HMAC(PSK, "broker").hexdigest()`,端用它验 `from="broker"` 的下行帧。
  - **p2p / cohost 拓扑**:`bk = HMAC(PSK, "controller:<coordinatorId>").hexdigest()`,端用它验 `from="controller:<coordinatorId>"` 的帧(下行帧的 `from` 是协调端自身 identity,不是字面 `"broker"`)。
- **回退链保持你的实现**:`bk` 缺失 → 端若持 PSK 按 §17.2 现场派生;都没有 → derived+required 下记软错误、保持连接不崩溃。
- **`bk` 仅用于验签,永不用于签名**;端仍永不接触 PSK。

## 2. controller 双角色保留 PSK — **采纳**

- **(1) controller 作为"操作者随身可信端"保留 PSK-in-settings,可接受、正式确认。** §17.1 的威胁模型明确针对"常年裸放展厅、易被物理接触的墙机",controller 不在该威胁面内。保留 PSK 让它 leaf 角色能验 broker 下行、coordinator 角色能对任意 `from` 现场派生验签,零新增配置、字节级兼容。
- **§17.4 的"各端不再持有 PSK"约束,范围收窄为"被控播放端(裸放墙机)"**,不含 controller。这条写进 §17.4 的适用范围说明,避免字面冲突。
- **controller 出码邀请 player 时,derived 下只下发 player 的 `dk`+`id`,绝不把 PSK 放进 QR** —— 严格遵守,红线不动。
- **(2) `bk` 定义补"派生 identity 随拓扑变化"**——见第 1 条,已一并定案。

## 3. [P0-A] 扫码依赖 — **先只保留"粘贴链接",本批不引入 `mobile_scanner`**

- 你已实现的零依赖"粘贴/剪贴板 + 添加"闭环(复用既有 `PairUri.tryParse → addDeviceFromPairUri → Discovery.addManual → _evaluateTopology/_enterP2p`,没新造配对逻辑)**即为本批交付形态**,保留。
- **摄像头扫码这一批不做。** 理由:`mobile_scanner` 需平台通道 + 相机权限,且目标机型含 YunOS 4.4.2 (KitKat) 旧 Android + 桌面端,在本容器无法验证可编译,风险与本批"稳定闭环"目标不匹配。留作后续独立增强项(引入时走 `mobile_scanner` + CI 加桌面/Android 编译校验,单独一轮验证兼容性),不塞进当前批次。

## 4. [P0-B] 图片渲染 — **采纳原生 `BitmapFactory`,不引入 Glide**

静态整屏图 + 已缓存本地文件,原生 `BitmapFactory.decodeFile/Stream` → 覆盖层 `ImageView` 足够,零新增依赖、可跑 4.4。**确认保持。** 仅当后续出现超大图需降采样 / 动图需求时再评估 Glide,本批不引入。

## 5. [P0-C] 图片 dwell 默认时长 — **5000ms 采纳,并写进 spec §6.1**

- `duration_ms` 缺失时两端统一 `DEFAULT_IMAGE_DWELL_MS = 5000`,**确认合适**(展厅轮播场景 5s 是合理下限兜底)。
- **写进 spec §6.1** 作为规范缺省值,不再只当"两端各自的健壮性兜底常量",避免两端常量漂移。控制端 UI 对图片强制填 `duration_ms` 的行为保留(默认仅兜底)。

---

**小结**:5 个问题全部按你的安全默认定案,无一需要你回退或返工。`bk` 的拓扑相关派生(第 1、2 条)是唯一需要你在代码里确保写清的点——broker 拓扑用 `"broker"`、p2p/cohost 用 `"controller:<coordinatorId>"`,别在 p2p 下仍用字面 `"broker"` 导致零 PSK 端验不了协调端帧。其余保持现状继续。
