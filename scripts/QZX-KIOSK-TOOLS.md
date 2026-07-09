# LAN Media Wall — 盒子一键工具（安装升级 + 清理，整合版）

两批盒子审计结论：**同一款硬件、同一套系统**（QZX_C1 / Hi3798MV300 / Android 4.4.2 /
HiSilicon / root adb），包集几乎一样，**一份脚本两批通用**。

## 一个脚本搞定一切

以前分三个脚本（装机 / 清理 / 盘点）。现在**合并成一个** `lmw_setup`：
安装升级 player → arm 推送升级 helper → 禁用媒体墙之外的一切 → 让盒子开机直进媒体墙。

| 文件 | 作用 |
|---|---|
| **`lmw_setup.bat`** | ⭐ 主入口。一条命令全干完（自动桥接中途那次重启） |
| `lmw_setup.sh` | 盒子内执行体（两段状态机；bat 会自动跑两遍） |
| `lmw_root_helper` | 推送升级用的 setuid-root 组件（**已换成 v1.13.5 新版**，带 reboot 支持） |
| `lmw_restore.bat` / `.sh` | 一键还原：把禁掉的程序全部重新启用 |
| `lmw_audit.bat` / `.sh` | 只读盘点（想先看盒子里有啥再动手时用） |

## 用法（插好 adb，每台盒子跑一次）

```
lmw_setup.bat "C:\path\to\LANMediaWall-v1.13.5-Player-Android.apk"
```

就这一条。它会：推文件 → 装/升级 player →（盒子重启一次，脚本自动等）→
arm helper → 禁掉其余所有程序 → 把媒体墙设为默认桌面 → 打印 `SETUP COMPLETE`。

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

## 关于"推送升级修好了没"

`lmw_root_helper` 就是推送升级的核心：盒子的 `su` 拒绝 App 的 uid，所以 App 靠这个
setuid 桥装包。**之前失败(`install-failed`)的真正原因**：你旧工具包里带的是**旧版
helper**，而"推送升级"在架构上**永远碰不到 helper 自己**（它只往 /data/app 丢 APK），
所以你越用推送升级越修不好。

**修复 = 本工具包已把 helper 换成 v1.13.5 CI 编的新版，`lmw_setup.bat` 每次都会重新
推送 + 重新 arm。** 跑一次这个 bat，推送升级就通了。

## 验证清单

- 脚本跑完打印 `SETUP COMPLETE. Player versionName=1.13.5`。
- 盒子重启后直接进媒体墙，遥控正常，桌面/视频全家桶消失。
- 之后在控制端点"推送升级"不再报 `install-failed`。
- 想还原：`lmw_restore.bat`（禁用项全部启用；已卸载的需重装或刷机）。
