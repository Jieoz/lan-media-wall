# LAN Media Wall — 盒子一键工具（安装升级 + 清理，整合版）

两批盒子审计结论：**同一款硬件、同一套系统**（QZX_C1 / Hi3798MV300 / Android 4.4.2 /
HiSilicon / root adb），包集几乎一样，**一份脚本两批通用**。

## 一个脚本搞定一切

以前分三个脚本（装机 / 清理 / 盘点）。现在**合并成一个** `lmw_setup`：
安装升级 player → 安装并启动 root 守护进程 `lmw_root_daemon` + 协议探测 → 禁用媒体墙
之外的一切 → 让盒子开机直进媒体墙。

| 文件 | 作用 |
|---|---|
| **`lmw_setup.bat`** | ⭐ 主入口。一条命令全干完（自动桥接中途那次重启） |
| `lmw_setup.sh` | 盒子内执行体（两段状态机；bat 会自动跑两遍） |
| `lmw_root_daemon` | 远程重启/推送升级用的 **root 守护进程**（armv7）。以 root 启动并常驻，监听抽象套接字 `@lmw_root_daemon`，`SO_PEERCRED` 校验 App uid。**不是 setuid**（目标机 `no_new_privs` 下 setuid 无效）。普通 `restart`=只重启播放 App（`RESTART_APP`，保住 Wi-Fi）；升级走 `pm install -r`（不整机 reboot）；整机 `REBOOT` 为单独高危动作。v1.14.4：`RESTART_APP` 是确定性「验证-重试」状态机——force-stop→显式 `am start -n <组件>`→核验后再重试(有限次,无 reboot 兜底);证据日志 `/data/local/tmp/lmw_restart.log` 区分 **PROCESS_UP**(进程在 `ps` 里)与 **ACTIVITY_RESUMED**(我们的活动在前台,读 `dumpsys activity activities`,回退 `mCurrentFocus`),终态行为显式 `restart_verified`/`restart_failed`。root-only `-restart` CLI 跑同一 worker(仅 root 可达,像 `-probe`;绝不整机 reboot) |
| `lmw_restore.bat` / `.sh` | 一键还原：把禁掉的程序全部重新启用 |
| `lmw_audit.bat` / `.sh` | 只读盘点（想先看盒子里有啥再动手时用） |
| `qzx_field_check.bat` / `.sh` | ⭐ **一键真机体检**（v1.14.4）。插一台盒子、双击一次:(A) **重启证据**——驱动真实守护进程 worker(`lmw_root_daemon -restart`,与 socket `RESTART_APP` 同一状态机),双信号判定:PASS 需**进程回来(新 PID)且我们的活动在前台**;仅进程回来、前台是别的活动、或盒子无法上报活动均记 FAIL。抓前后 uptime/Wi-Fi/版本号/守护进程 probe/`lmw_restart.log`/logcat。(B) **内核 A/B**——同盒同素材各跑 `PLAY_SECONDS` 秒,汇总掉帧诚实值(Exo 真实数 vs MediaPlayer `n/a`)与「从未起播」标记。保守:不 reboot/不卸载/不 remount/不清数据/不清 logcat,唯一写入=A/B 覆盖文件+重启本 App,Ctrl-C 也还原。产出一个 ZIP + `report.txt` |
| `qzx_ab_backend.bat` / `.sh` | **一键 A/B 对比两个视频内核**（ExoPlayer vs 原生 MediaPlayer，v1.14.2）。逐内核：写 `/data/local/tmp/lmw_video_backend` → 重启播放墙(盒子自动 `resume_last` 重放上次素材) → 放一会 → 拉 `player.log`+logcat+meminfo 到一个文件夹；最后删覆盖文件并重启,盒子恢复原内核。**只写那一个覆盖文件 + 重启本 App,结束即还原**——不装/不重启系统/不动素材配置。(注:`qzx_field_check` 把重启证据 + A/B 合成一键,新体检优先用它) |
| `qzx_verify_update.bat` / `.sh` | **真机验收：升级免整机重启**（v1.14.2）。用你给的 APK 复现守护进程的 `pm install -r <暂存>` 流程,核验两件事:①包 `versionCode` 变了(新代码已激活、PM 上报新版本)②整机 uptime 没归零(没重启)。只装你指定的 APK,不重启/不卸载/不动素材配置,结束删暂存文件 |

### 一键真机体检 · 重启证据 + A/B(v1.14.4)——最先跑这个

盒子曾出现「点 restart 后 App 被 force-stop 但没自动回来,一直黑屏,要手动
`am start` 才好」。这一版把重启做成**确定性状态机**并给出**可证据化**的双信号判定。
插好**一台**盒子(须已装好并在播放),双击:

```
qzx_field_check.bat
```

它做两件事,产出一个 ZIP + `report.txt`:

- **(A) 重启证据**:驱动**真实**守护进程 worker(`lmw_root_daemon -restart`,与
  socket `RESTART_APP` 是同一个 `lmw_restart_app_run` 状态机——不是另写一段 shell),
  在有限超时内轮询判定:
  - **PROCESS_UP**:播放 App 的主进程重新出现在 `ps`(新 PID)。
  - **ACTIVITY_RESUMED**:我们的 `.MainActivity` 真的在前台(读
    `dumpsys activity activities` 的 `mResumedActivity`/`mFocusedActivity`,回退
    `dumpsys window windows` 的 `mCurrentFocus`)。
  - **完全恢复 = 两者都成立**。只有进程回来但前台是桌面 ⇒ **PARTIAL/FAIL**(就是那个黑屏 bug),
    绝不记 PASS。老 ROM 若压根报不出活动 ⇒ **FAIL(无法完成双信号验证)**，不得用人肉确认替代机器成功判据。
  - 抓前后 uptime(归零=发生了整机 reboot,危险)、Wi-Fi 接口/状态、versionName/Code、
    守护进程 `-probe`、守护进程自留的 `lmw_restart.log`(终态行显式
    `restart_verified`/`restart_failed`,含 `attempts=`/`process_up=`/`activity_resumed=`)、logcat 尾。
- **(B) 内核 A/B**:同盒同素材(盒子 `resume_last` 重放上次素材)对 `exoplayer`、
  `mediaplayer` 各跑 `PLAY_SECONDS` 秒,汇总**诚实**指标:Exo 掉帧给真实数,MediaPlayer
  记 `n/a`(不是编造的 0);外加 first-frame/prepared/卡顿/GC,以及「**从未起播**」标记
  (既无首帧又无 prepared ⇒ 该内核结论无效,检查盒子有没有 `resume_last` 素材)。

**为什么走守护进程 `-restart` 而不是重写 shell**:socket 用 `SO_PEERCRED` 按 App uid 鉴权,
adb/root 无法在 socket 上冒充 App。要验**真实**的重启 worker,守护进程另开一个 root-only
`-restart` CLI,内联跑同一状态机、按完全恢复退 0/1——只有已是 root 的调用者可达(与 `-probe`
一致),生产鉴权毫不削弱,且该路径永不触及整机 `REBOOT`。守护进程不在盒上时,脚本退回一个
**明确标注的人肉「在控制器点 restart」检查点**,采集器继续跑。

保守边界:**不** reboot / 不卸载 / 不 remount / 不清数据 / 不清 logcat / 不广删。唯一写盘=
A/B 覆盖文件 + 重启本 App,结束(含 Ctrl-C)一律还原覆盖文件并重启回配置内核。
可选环境变量:`PLAY_SECONDS`(每内核秒数,默认 60)、`RESTART_TIMEOUT`(等自动回来的秒数,默认 30)。

### 视频内核 A/B(v1.14.2）——盒子掉帧/黑屏时用

盒子若在 ExoPlayer 下掉帧或黑屏,用它对比原生 MediaPlayer(走盒子厂商自己的
Stagefright/OMX,常更稳)。插好**一台**盒子(须已装好并在播放),双击:

```
qzx_ab_backend.bat
```

它对 `exoplayer`、`mediaplayer` 各跑一轮,把证据存到 bat 旁边的
`qzx_ab_<serial>_<时间>\` 里(每个内核一个子目录)。把整个文件夹发回即可。对比要点:
`first_frame rendered`(有没有真出画面)、`state BUFFERING`/`buffering_start`(卡顿)、
`dropped_frames`(仅 ExoPlayer 有;原生记 `n/a`)、任何 `error` 行。
可选:运行前设 `PLAY_SECONDS`(每内核播放秒数,默认 40)。

### 升级免整机重启 · 真机验收(v1.14.2)——远程升级到底会不会重启盒子

v1.14.2 起远程升级(`update_app`)改用 `pm install -r` 原子激活新版本,**不再整机 reboot**
(QZX_C1 warm reboot 会丢 Wi-Fi)。要在真机上确认这条路真能走通,插好**一台**盒子,跑:

```
qzx_verify_update.bat  C:\path\to\新版或同签名.apk
```

它复现守护进程执行的那条 `pm install -r <暂存>`(经 root),然后核验:
**①包 `versionCode` 变了**(装的是更高 versionCode 的包才看得出——证明新代码真被激活、
PackageManager 上报的是新版本)、**②整机 uptime 没往回走**(证明没重启)。两项都过即打印
`RESULT: OK`。它只装你指定的 APK,不重启/不卸载/不动素材配置,结束删掉暂存文件。

## 用法（插好 adb，每台盒子跑一次）

```
lmw_setup.bat "C:\path\to\LANMediaWall-v1.13.5-Player-Android.apk"
```

就这一条。它会：推文件 → 装/升级 player →（盒子重启一次，脚本自动等）→
装并启动 root 守护进程 + 协议探测（探测失败即终止不写完成标记）→ 禁掉其余所有程序 →
把媒体墙设为默认桌面 → 打印 `SETUP COMPLETE`。

### 可选参数（跟在 APK 路径后面）

| 参数 | 含义 |
|---|---|
| `FORCE` | 清装（先卸载+清数据）。签名变更导致 KitKat 拒绝覆盖升级时用 |
| `NOCLEAN` | 只装/升级，不禁用其它程序 |
| `KEEPDEBUG` | 保留文件管理器 + 悟空遥控助手（调试时用） |
| `NOUNINST` | 只禁用、不卸载 /data 里的垃圾（默认会真卸掉后装的垃圾） |

例：`lmw_setup.bat "...\player.apk" FORCE KEEPDEBUG`

## "只当媒体墙用"到底禁了什么

脚本用**动态白名单**：`pm list packages` 里除了下面这份硬白名单，**其余全禁**。
这样未来盒子里冒出的新垃圾也会被自动扫掉，而绝不会误伤系统地基。

- **保留（约 26 个，都是 OS 地基 + 你的媒体墙）**：`com.jieoz.lanmediawall.player`、
  SystemUI、设置(settings/cos.settings)、装包器(packageinstaller)、输入法、蓝牙、
  各类 Provider(存储/设置/下载)、shell、hiRMService、provision、PicoTTS 等。
- **禁用/卸载（约 23 个）**：优酷桌面(youku.taitan.tv)、挖矿看门狗(youku.cloud.dog)、
  阿里 ASR、HiSilicon DLNA/Miracast/视频/音乐/图库、系统 Music、咪咕/腾讯TV/gitv/xhm、
  QZX 商店/翻译/asr、悟空助手、小白/系统文件管理器 等。

> 优酷桌面被禁后，媒体墙的 HomeAlias 成为唯一 HOME，盒子开机直接进媒体墙。
> 全程 `pm disable-user` 可逆，`/data` 垃圾才真卸；不刷机、不动 /system 文件。

## 关于远程重启 / 推送升级的架构（v1.14.0 起改用 root 守护进程）

盒子的 `su` 拒绝 App 的 uid,而 zygote 置了 `no_new_privs` → **setuid 位被内核忽略**,
所以旧的 `lmw_root_helper`(setuid-root)架构在这批盒子上根本行不通(App exec 后仍是
`euid=10020`)。**新架构**:`lmw_root_daemon` 是一个**以 root 启动并常驻**的守护进程,
监听抽象命名空间套接字 `@lmw_root_daemon`。App(`RootInstaller`)作为本地套接字客户端
连上去发 `PROBE` / `REBOOT` / `INSTALL <canonical-path>`;守护进程用 `SO_PEERCRED` 内核
对端凭证反查 App uid(取自 root-only 的 `/data/local/tmp/lmw_root_daemon.uid`),只接受
唯一 canonical 更新路径,原子安装后 reboot,**不执行任何 shell**。

`lmw_setup.bat` 每次会重新推送守护进程二进制 + 重装 + 立即启动 + 用守护进程自带的
`-probe` 协议探测(必须回 `ready ... daemon_euid=0`)后才写完成标记。冷启动持久化通过
ROM 支持的 `/system/etc/init.d` 钩子(或已存在的 `install-recovery.sh`)安装 —— 该 ROM
是否在冷启动真正执行 init.d 是**真机验收项**。

## 验证清单

- 脚本跑完打印 `SETUP COMPLETE. Player versionName=1.14.0`。
- 盒子重启后直接进媒体墙，遥控正常，桌面/视频全家桶消失。
- setup 打印 `daemon probe: ready ... daemon_euid=0`；控制端"推送升级"/"重启"可用。
- **真机验收**:重启盒子后 `lmw_root_daemon -probe` 仍返回 ready(确认冷启动钩子生效)。
- 想还原：`lmw_restore.bat`（禁用项全部启用；已卸载的需重装或刷机）。
