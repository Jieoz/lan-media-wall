import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/wall_state.dart';
import 'connection_status.dart';

/// 设置：连接方式（P2P 推荐 / Broker 高级）、可选 broker 地址、PSK、controller_id ——
/// 输入并持久化(§1/§3/§B)。连接标签由实际拓扑派生，绝不因保存成功乐观显示已连接。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _psk = TextEditingController();
  final _mediaUploadToken = TextEditingController();
  final _ctlId = TextEditingController();
  bool _secure = false;
  bool _pskVisible = false;
  bool _mediaUploadTokenVisible = false;
  bool _loaded = false;
  ConnectionMode _mode = ConnectionMode.autoP2p;
  String? _portError;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _psk.dispose();
    _mediaUploadToken.dispose();
    _ctlId.dispose();
    super.dispose();
  }

  void _loadFrom(WallState s) {
    if (_loaded) return;
    _loaded = true;
    _host.text = s.brokerHost;
    _port.text = s.brokerPort.toString();
    _psk.text = s.psk;
    _mediaUploadToken.text = s.mediaUploadToken;
    _ctlId.text = s.controllerId;
    _secure = s.brokerSecure;
    _mode = s.connectionMode;
  }

  Future<void> _save(WallState s) async {
    // §B 严格端口校验 1–65535：仅 broker 模式需要有效端口；绝不静默回落 8770。
    int port = s.brokerPort;
    if (_mode == ConnectionMode.broker) {
      final r = validateBrokerPort(_port.text);
      if (!r.ok) {
        setState(() => _portError = r.error);
        return;
      }
      port = r.port!;
    }
    setState(() => _portError = null);
    await s.updateSettings(
      connectionMode: _mode,
      host: _host.text,
      port: port,
      secure: _secure,
      newPsk: _psk.text,
      newMediaUploadToken: _mediaUploadToken.text,
      newControllerId: _ctlId.text,
    );
    if (!mounted) return;
    // 措辞真相(§B)：保存只保证已保存并触发重连，真正的已连接由状态机推进。
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('设置已保存，正在重新连接')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<WallState>();
    _loadFrom(state);
    final isBroker = _mode == ConnectionMode.broker;
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(state.connectionStatusLabel,
                  style: TextStyle(
                      color: state.connected
                          ? Colors.green
                          : Colors.orange)),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('连接方式', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SegmentedButton<ConnectionMode>(
            segments: const [
              ButtonSegment(
                value: ConnectionMode.autoP2p,
                icon: Icon(Icons.wifi_tethering),
                label: Text('自动发现 / P2P（推荐）'),
              ),
              ButtonSegment(
                value: ConnectionMode.broker,
                icon: Icon(Icons.dns),
                label: Text('连接 Broker（高级）'),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
          const SizedBox(height: 8),
          Text(
            isBroker
                ? '高级：连到独立部署的 Broker（填地址/端口/WSS）。'
                : '推荐：控制端自动发现被控端并建立 P2P 直连，无需任何服务器。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          // §B P2P 模式隐藏 broker host/port/WSS/上传 token 等高级字段。
          if (isBroker) ...[
            TextField(
              controller: _host,
              decoration: const InputDecoration(
                labelText: 'Broker 地址 (IP / 主机名)',
                hintText: '如 192.168.1.10',
                helperText: '0.0.0.0 / :: 是服务端监听地址，不能作为 broker 地址',
                prefixIcon: Icon(Icons.dns),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              onChanged: (_) {
                if (_portError != null) setState(() => _portError = null);
              },
              decoration: InputDecoration(
                labelText: '端口 (WS 8770 / WSS 8771)',
                errorText: _portError,
                prefixIcon: const Icon(Icons.numbers),
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
              controller: _mediaUploadToken,
              obscureText: !_mediaUploadTokenVisible,
              decoration: InputDecoration(
                labelText: '媒体上传 token（可选）',
                helperText: 'broker 配置 media_upload_token 时填写；留空保持开放上传兼容',
                prefixIcon: const Icon(Icons.upload_file),
                suffixIcon: IconButton(
                  icon: Icon(_mediaUploadTokenVisible
                      ? Icons.visibility_off
                      : Icons.visibility),
                  onPressed: () => setState(() =>
                      _mediaUploadTokenVisible = !_mediaUploadTokenVisible),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          // PSK 两种模式都可用（P2P 下控制端兼任协调端，PSK 决定 auth_mode）。
          TextField(
            controller: _psk,
            obscureText: !_pskVisible,
            decoration: InputDecoration(
              labelText: 'PSK (预置共享密钥, 32+ 字节)',
              helperText: isBroker
                  ? 'broker 鉴权用'
                  : 'P2P 下留空为开放模式；填写则本端兼任协调端启用鉴权',
              prefixIcon: const Icon(Icons.key),
              suffixIcon: IconButton(
                icon: Icon(
                    _pskVisible ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _pskVisible = !_pskVisible),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // controller_id 属高级身份，保留可用但非首要。
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            title: const Text('高级 · 控制端身份'),
            children: [
              TextField(
                controller: _ctlId,
                decoration: const InputDecoration(
                  labelText: 'controller_id',
                  prefixIcon: Icon(Icons.badge),
                ),
              ),
            ],
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
