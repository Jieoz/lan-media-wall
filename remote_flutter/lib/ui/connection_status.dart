import '../net/broker_client.dart' show ConnState;
import '../state/wall_state.dart' show Topology;

/// 操作员选择的连接方式（§B 拓扑真相）。
///  - [autoP2p]：`自动发现 / P2P（推荐）`。忽略遗留 broker 地址，走发现 → P2P 直连。
///  - [broker]：`连接 Broker（高级）`。使用手填 broker host/port/WSS。
///
/// 与 [Topology] 分开：Topology 是**实际运行**的连接方式（可能因发现结果切换），
/// ConnectionMode 是**操作员意图**。持久化后 [WallState._evaluateTopology] 据此决定
/// 是否拨号 broker，避免一个想走 P2P 的控制端因残留 broker 地址被动连 broker。
enum ConnectionMode { autoP2p, broker }

extension ConnectionModeStore on ConnectionMode {
  /// 稳定持久化标识（跨版本不随枚举顺序漂移）。
  String get storeKey => switch (this) {
        ConnectionMode.autoP2p => 'autoP2p',
        ConnectionMode.broker => 'broker',
      };

  static ConnectionMode fromStore(String? raw) => switch (raw) {
        'broker' => ConnectionMode.broker,
        'autoP2p' => ConnectionMode.autoP2p,
        _ => ConnectionMode.autoP2p,
      };
}

/// 由**实际拓扑 + 对端/连接态**派生的连接标签（§B）。措辞与设计合同示例逐字一致：
///  - P2P：有对端 → `P2P · 已连接 N 台`；无对端 → `P2P · 正在发现设备`。
///  - Broker（dedicated/cohosted 皆算 broker 传输）：已连 → `Broker · 已连接`；
///    连接中/断开 → `Broker · 重连中`（断开态本就在自动重连）。
///
/// 关键：绝不因「保存成功」乐观显示已连接——标签只反映真实状态机。
String connectionLabel({
  required Topology topology,
  required int peers,
  required ConnState conn,
}) {
  if (topology == Topology.p2p) {
    return peers > 0 ? 'P2P · 已连接 $peers 台' : 'P2P · 正在发现设备';
  }
  return conn == ConnState.connected ? 'Broker · 已连接' : 'Broker · 重连中';
}

/// 端口校验结果：合法时 [port] 非空、[error] 为空；非法时 [port] 为 null 且带 [error]。
/// 绝不静默把非法输入替换成 8770（§B）。
class PortResult {
  const PortResult({this.port, this.error});
  final int? port;
  final String? error;

  bool get ok => port != null;

  @override
  bool operator ==(Object other) =>
      other is PortResult && other.port == port && other.error == error;

  @override
  int get hashCode => Object.hash(port, error);
}

/// 严格校验 broker 端口整数 1–65535（§B）。空/非数字/越界一律返回错误，绝不回落默认值。
PortResult validateBrokerPort(String raw) {
  final t = raw.trim();
  if (t.isEmpty) {
    return const PortResult(error: '请填写端口（1–65535）');
  }
  final n = int.tryParse(t);
  if (n == null) {
    return const PortResult(error: '端口必须是整数（1–65535）');
  }
  if (n < 1 || n > 65535) {
    return const PortResult(error: '端口须在 1–65535 之间');
  }
  return PortResult(port: n);
}
