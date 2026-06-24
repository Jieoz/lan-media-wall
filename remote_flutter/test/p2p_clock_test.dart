import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/p2p/clock_master.dart';

void main() {
  group('ClockMaster (§8.1 / §14.3 p2p 主时钟)', () {
    test('serverTime 取注入的 now', () {
      var t = 1000;
      final cm = ClockMaster(nowFn: () => t);
      expect(cm.serverTime(), 1000);
      t = 2000;
      expect(cm.serverTime(), 2000);
    });

    test('ackPayload 回 t1/t2/t3 + req_msg_id', () {
      var t = 5000;
      final cm = ClockMaster(nowFn: () => t);
      final ack = cm.ackPayload(
        {'t1': 1234},
        reqMsgId: 'req-1',
        recvMs: 4999,
      );
      expect(ack['t1'], 1234);
      expect(ack['t2'], 4999); // 注入的 recvMs
      expect(ack['t3'], 5000); // serverTime()
      expect(ack['req_msg_id'], 'req-1');
    });

    test('recvMs 缺省取 serverTime', () {
      final cm = ClockMaster(nowFn: () => 7777);
      final ack = cm.ackPayload({'t1': 1});
      expect(ack['t2'], 7777);
      expect(ack['t3'], 7777);
      expect(ack.containsKey('req_msg_id'), isFalse);
    });

    test('t1 缺失或非法 → 0', () {
      final cm = ClockMaster(nowFn: () => 1);
      expect(cm.ackPayload(const {})['t1'], 0);
      expect(cm.ackPayload({'t1': 'x'})['t1'], 0);
      expect(cm.ackPayload({'t1': '42'})['t1'], 42);
    });
  });
}
