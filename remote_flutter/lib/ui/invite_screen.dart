import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  bool _hostLoaded = false;

  @override
  void dispose() {
    _group.dispose();
    _host.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<WallState>();
    // p2p 模式下没有单一 broker host，预填为空让用户填本机 IP。
    if (!_hostLoaded) {
      _hostLoaded = true;
      _host.text = state.isP2p ? '' : state.brokerHost;
    }

    final uri = state.buildPairUri(
      group: _group.text.trim().isEmpty ? 'lobby' : _group.text.trim(),
      overrideHost: _host.text,
    );
    final uriStr = uri.build();
    final canRenderQr = uri.connHost.isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('邀请设备 / 添加')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
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
