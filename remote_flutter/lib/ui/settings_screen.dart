import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../net/broker_client.dart';
import '../state/wall_state.dart';

/// 设置：broker 地址 / 端口 / WSS、PSK、controller_id —— 输入并持久化(§1/§3)。
/// 同时展示连接态与诊断日志。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _psk = TextEditingController();
  final _ctlId = TextEditingController();
  bool _secure = false;
  bool _pskVisible = false;
  bool _loaded = false;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _psk.dispose();
    _ctlId.dispose();
    super.dispose();
  }

  void _loadFrom(WallState s) {
    if (_loaded) return;
    _loaded = true;
    _host.text = s.brokerHost;
    _port.text = s.brokerPort.toString();
    _psk.text = s.psk;
    _ctlId.text = s.controllerId;
    _secure = s.brokerSecure;
  }

  Future<void> _save(WallState s) async {
    final port = int.tryParse(_port.text.trim()) ?? 8770;
    await s.updateSettings(
      host: _host.text,
      port: port,
      secure: _secure,
      newPsk: _psk.text,
      newControllerId: _ctlId.text,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存并重连')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<WallState>();
    _loadFrom(state);
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        actions: [_connText(state.conn)],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _host,
            decoration: const InputDecoration(
              labelText: 'broker 地址 (IP / 主机名)',
              hintText: '192.168.1.10',
              prefixIcon: Icon(Icons.dns),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _port,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '端口 (WS 8770 / WSS 8771)',
              prefixIcon: Icon(Icons.numbers),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('使用 WSS (TLS)'),
            subtitle: const Text('broker 配置了证书时启用'),
            value: _secure,
            onChanged: (v) => setState(() => _secure = v),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: _psk,
            obscureText: !_pskVisible,
            decoration: InputDecoration(
              labelText: 'PSK (预置共享密钥, 32+ 字节)',
              prefixIcon: const Icon(Icons.key),
              suffixIcon: IconButton(
                icon: Icon(
                    _pskVisible ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _pskVisible = !_pskVisible),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctlId,
            decoration: const InputDecoration(
              labelText: 'controller_id',
              prefixIcon: Icon(Icons.badge),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.save),
            label: const Text('保存并重连'),
            onPressed: () => _save(state),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Text('诊断日志', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('复制全部'),
                onPressed: () async {
                  final text = state.logLines.join('\n');
                  await Clipboard.setData(ClipboardData(text: text));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('已复制 ${state.logLines.length} 行日志到剪贴板')),
                    );
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          _LogView(lines: state.logLines),
        ],
      ),
    );
  }

  Widget _connText(ConnState conn) {
    final (color, text) = switch (conn) {
      ConnState.connected => (Colors.green, '已连接'),
      ConnState.connecting => (Colors.orange, '连接中'),
      ConnState.disconnected => (Colors.red, '未连接'),
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(text, style: TextStyle(color: color)),
      ),
    );
  }
}

class _LogView extends StatelessWidget {
  const _LogView({required this.lines});
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 200,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(8),
      ),
      child: lines.isEmpty
          ? const Center(child: Text('暂无日志'))
          : ListView.builder(
              reverse: true,
              itemCount: lines.length,
              itemBuilder: (context, i) {
                final line = lines[lines.length - 1 - i];
                return SelectableText(line,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12));
              },
            ),
    );
  }
}
