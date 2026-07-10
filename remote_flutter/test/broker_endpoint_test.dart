import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/net/broker_client.dart';
import 'package:remote_flutter/protocol/auth_mode.dart';
import 'package:remote_flutter/protocol/envelope.dart';
import 'package:remote_flutter/protocol/remote_endpoint.dart';

void main() {
  group('normalizeRemoteHost', () {
    test('真实故障样本：通配监听地址不能作为 broker 远端', () {
      expect(normalizeRemoteHost('0.0.0.0'), isEmpty);
      expect(normalizeRemoteHost('::'), isEmpty);
      expect(normalizeRemoteHost('[::]'), isEmpty);
    });

    test('保留可拨号主机并去除空白', () {
      expect(normalizeRemoteHost(' 10.10.8.20 '), '10.10.8.20');
      expect(normalizeRemoteHost('broker.lan'), 'broker.lan');
    });
  });

  test('未连接 broker 时发送明确返回 false', () {
    final client = BrokerClient(
      codec: EnvelopeCodec(
        psk: '',
        fromAddress: 'controller:test',
        authMode: AuthMode.open,
      ),
      controllerId: 'test',
    );

    expect(client.send('create_group', to: 'broker'), isFalse);
    client.dispose();
  });
}