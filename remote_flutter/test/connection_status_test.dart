import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/net/broker_client.dart' show ConnState;
import 'package:remote_flutter/state/wall_state.dart' show Topology;
import 'package:remote_flutter/ui/connection_status.dart';

void main() {
  group('connectionLabel — topology-derived truth (§B)', () {
    test('P2P with peers shows 已连接 N 台', () {
      expect(
        connectionLabel(topology: Topology.p2p, peers: 3, conn: ConnState.disconnected),
        'P2P · 已连接 3 台',
      );
    });

    test('P2P with no peers shows 正在发现设备 (never optimistic connected)', () {
      expect(
        connectionLabel(topology: Topology.p2p, peers: 0, conn: ConnState.connecting),
        'P2P · 正在发现设备',
      );
    });

    test('Broker connected shows Broker · 已连接', () {
      expect(
        connectionLabel(topology: Topology.dedicated, peers: 0, conn: ConnState.connected),
        'Broker · 已连接',
      );
    });

    test('Broker connecting shows Broker · 重连中', () {
      expect(
        connectionLabel(topology: Topology.dedicated, peers: 0, conn: ConnState.connecting),
        'Broker · 重连中',
      );
    });

    test('Broker disconnected also shows Broker · 重连中 (auto-reconnect)', () {
      expect(
        connectionLabel(topology: Topology.dedicated, peers: 0, conn: ConnState.disconnected),
        'Broker · 重连中',
      );
    });

    test('cohosted broker is labelled Broker, not P2P', () {
      expect(
        connectionLabel(topology: Topology.cohosted, peers: 0, conn: ConnState.connected),
        'Broker · 已连接',
      );
    });
  });

  group('validateBrokerPort — strict 1..65535, no silent fallback (§B)', () {
    test('accepts in-range', () {
      expect(validateBrokerPort('8770'), const PortResult(port: 8770));
      expect(validateBrokerPort('1'), const PortResult(port: 1));
      expect(validateBrokerPort('65535'), const PortResult(port: 65535));
    });

    test('rejects zero / out of range with an error and no port', () {
      expect(validateBrokerPort('0').port, isNull);
      expect(validateBrokerPort('0').error, isNotNull);
      expect(validateBrokerPort('65536').port, isNull);
      expect(validateBrokerPort('-3').port, isNull);
    });

    test('rejects non-numeric / empty — never substitutes 8770', () {
      expect(validateBrokerPort('abc').port, isNull);
      expect(validateBrokerPort('').port, isNull);
      expect(validateBrokerPort('87 70').port, isNull);
      // Crucially, the error path does not smuggle in 8770.
      expect(validateBrokerPort('abc').port, isNot(8770));
    });

    test('trims surrounding whitespace', () {
      expect(validateBrokerPort('  8771 ').port, 8771);
    });
  });
}
