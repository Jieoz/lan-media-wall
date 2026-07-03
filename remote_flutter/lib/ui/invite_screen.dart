import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../protocol/auth_mode.dart';
import '../state/wall_state.dart';

/// 邀请设备 / 添加页（protocol_spec.md §15）：由当前连接信息**生成** `lmw://pair?...`
/// 配对 URI 并渲染成二维码，供被控端扫码免手输入组。
///
/// - `open` 模式不含 psk（纯“扫一下进组”）。
/// - `optional`/`required` 携带 psk（带密钥的入场券）。
class InviteScreen extends StatefulWidget {
  const InviteScreen({super.key});

  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<InviteScreen> {
  final _group = TextEditingController(text: 'lobby');
  final _host = TextEditingController();
  final _invitee = TextEditingController();
  final _enroll = TextEditingController();
  bool _hostLoaded = false;

  @override
  void dispose() {
    _group.dispose();
    _host.dispose();
    _invitee.dispose();
    _enroll.dispose();
    super.dispose();
  }

  /// 消费被控端出示的 enroll 链接：粘贴/输入 `lmw://pair?...` → 解析 → 登记设备。
  void _addFromEnroll(WallState state) => _enroll.text.trim().isEmpty
      ? null
      : _consume(state, _enroll.text.trim(), clearField: true);

  /// 三层入口（自动发现/扫码/手填）汇流到同一入组路径：解析 `lmw://pair?...`
  /// → [WallState.addDeviceFromPairUri]（= 一次成功的 UDP 发现）。扫码/粘贴/手填
  /// 都走这里，不各造一套配对逻辑。
  void _consume(WallState state, String raw, {bool clearField = false}) {
    final name = state.addDeviceFromPairUri(raw);
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    if (name == null) {
      messenger.showSnackBar(const SnackBar(
          content: Text('链接无效：需形如 lmw://pair?host=...&id=...')));
      return;
    }
    if (clearField) _enroll.clear();
    setState(() {});
    messenger.showSnackBar(SnackBar(content: Text('已添加设备「$name」，正在连接…')));
  }

  /// 打开真·摄像头扫码页（§15 扫码入口）；扫到 `lmw://pair?...` 后复用 [_consume]。
  Future<void> _scan(WallState state) async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const _ScanPage()),
    );
    if (!mounted || raw == null || raw.trim().isEmpty) return;
    _consume(state, raw.trim());
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<WallState>();
    // p2p 模式下没有单一 broker host，预填为空让用户填本机 IP。
    if (!_hostLoaded) {
      _hostLoaded = true;
      _host.text = state.isP2p ? '' : state.brokerHost;
    }

    final invitee = _invitee.text.trim();
    final uri = state.buildPairUri(
      group: _group.text.trim().isEmpty ? 'lobby' : _group.text.trim(),
      overrideHost: _host.text,
      inviteeId: invitee,
    );
    final uriStr = uri.build();
    final canRenderQr = uri.connHost.isNotEmpty;
    // §17.4：派生密钥模式下，需先填受邀端设备 id 才能为其派生 device_key（QR 不含 PSK）。
    final derived = state.keyMode == KeyMode.derived &&
        state.authMode != AuthMode.open &&
        state.psk.isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('邀请设备 / 添加')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _AddDeviceSection(
            controller: _enroll,
            onAdd: () => _addFromEnroll(state),
            onScan: () => _scan(state),
            onPaste: () async {
              final data = await Clipboard.getData(Clipboard.kTextPlain);
              final txt = data?.text?.trim() ?? '';
              if (txt.isNotEmpty) {
                _enroll.text = txt;
                setState(() {});
              }
            },
          ),
          const SizedBox(height: 20),
          _ModeBanner(mode: state.authMode),
          const SizedBox(height: 12),
          TextField(
            controller: _host,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: '协调端地址 host',
              hintText: state.isP2p ? '本机 IP（p2p 下遥控端兼任协调端）' : '192.168.1.10',
              prefixIcon: const Icon(Icons.dns),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _group,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: '目标分组 group',
              prefixIcon: Icon(Icons.group_work),
            ),
          ),
          if (derived) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _invitee,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: '受邀设备 id（派生密钥模式）',
                hintText: '如 win-lobby-01（为该设备单独派生密钥，二维码不含全局 PSK）',
                prefixIcon: Icon(Icons.devices_other),
              ),
            ),
            if (invitee.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  '派生密钥模式：填入受邀设备 id 后，二维码只携带该设备专属密钥；'
                  '留空则回退为携带全局 PSK。',
                  style: TextStyle(fontSize: 12),
                ),
              ),
          ],
          const SizedBox(height: 20),
          if (canRenderQr)
            Center(
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    color: Colors.white,
                    child: QrImageView(
                      data: uriStr,
                      version: QrVersions.auto,
                      size: 240,
                      gapless: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text('扫码即可入组（${state.authMode.label}模式）',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text(
                '请先填入协调端地址（host）以生成二维码。\n'
                'p2p 模式下填本机在局域网中的 IP。',
                textAlign: TextAlign.center,
              ),
            ),
          const SizedBox(height: 20),
          _UriRow(uri: uriStr),
          const SizedBox(height: 8),
          if (state.authMode != AuthMode.open && state.psk.isEmpty)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text('当前为加密/可选模式但未设置 PSK，二维码不含密钥。请在「设置」配置 PSK。'),
              ),
            ),
        ],
      ),
    );
  }
}

/// 添加设备:粘贴/输入被控端出示的 enroll 链接(`lmw://pair?...`)→ 登记为 p2p 目标。
/// 这是配对闭环里遥控端**消费**被控端二维码的零依赖路径(§15 反向)。
class _AddDeviceSection extends StatelessWidget {
  const _AddDeviceSection({
    required this.controller,
    required this.onAdd,
    required this.onScan,
    required this.onPaste,
  });
  final TextEditingController controller;
  final VoidCallback onAdd;
  final VoidCallback onScan;
  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.add_link),
                const SizedBox(width: 8),
                Text('添加设备(扫描/粘贴其二维码链接)',
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              '被控端(TV 盒/Windows)开机会出示自己的 lmw:// 二维码。'
              '三种方式都能把它加进设备墙:直接扫码、粘贴链接、或手填 IP。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            // 入口一:真·摄像头扫码（§15）。醒目主按钮。
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('扫码添加'),
                onPressed: onScan,
              ),
            ),
            const SizedBox(height: 8),
            // 入口二:粘贴 lmw:// 链接兜底。
            TextField(
              controller: controller,
              minLines: 1,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: 'lmw://pair?host=...&id=...',
                prefixIcon: const Icon(Icons.content_paste_go),
                suffixIcon: IconButton(
                  tooltip: '从剪贴板粘贴',
                  icon: const Icon(Icons.content_paste),
                  onPressed: onPaste,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('添加'),
                onPressed: onAdd,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeBanner extends StatelessWidget {
  const _ModeBanner({required this.mode});
  final AuthMode mode;

  @override
  Widget build(BuildContext context) {
    final (icon, desc) = switch (mode) {
      AuthMode.open => (Icons.lock_open, '开放模式：二维码不含密钥，扫一下即进组'),
      AuthMode.optional => (Icons.lock_outline, '可选模式：若已设 PSK 则随码下发'),
      AuthMode.required => (Icons.lock, '加密模式：二维码即带密钥的入场券'),
    };
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text('鉴权模式：${mode.label}'),
        subtitle: Text(desc),
      ),
    );
  }
}

/// 真·摄像头扫码页（§15 扫码入口）：用 mobile_scanner 打开后置摄像头，扫到第一个
/// 含 `lmw://pair` 的二维码即 pop 回其原始文本，交由 [_InviteScreenState._consume]
/// 复用与「粘贴/发现」完全相同的入组路径。摄像头权限由 CI 注入的 CAMERA 声明支撑
/// （见 .github/workflows/flutter-build.yml），运行时由 mobile_scanner 触发授权弹窗。
class _ScanPage extends StatefulWidget {
  const _ScanPage();

  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  final MobileScannerController _controller = MobileScannerController();
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue?.trim();
      if (raw == null || raw.isEmpty) continue;
      // 只接受配对 URI，避免误扫其它二维码。大小写无关地匹配 scheme。
      if (raw.toLowerCase().startsWith('lmw://pair')) {
        _handled = true;
        Navigator.of(context).pop(raw);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('扫描设备二维码'),
        actions: [
          IconButton(
            tooltip: '手电筒',
            icon: const Icon(Icons.flash_on),
            onPressed: () => _controller.toggleTorch(),
          ),
          IconButton(
            tooltip: '切换摄像头',
            icon: const Icon(Icons.cameraswitch),
            onPressed: () => _controller.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        alignment: Alignment.center,
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          // 取景提示框 + 文案。
          Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white70, width: 2),
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          const Positioned(
            bottom: 40,
            child: Text(
              '对准被控端屏幕上的 lmw:// 配对二维码',
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}

class _UriRow extends StatelessWidget {
  const _UriRow({required this.uri});
  final String uri;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('配对 URI', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            SelectableText(uri,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('复制'),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: uri));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已复制配对 URI')),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
