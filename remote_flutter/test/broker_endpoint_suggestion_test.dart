import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/state/broker_endpoint_suggestion.dart';

void main() {
  group('suggestBrokerEndpoint priority', () {
    test('prefers the Broker this controller is actually connected to', () {
      final s = suggestBrokerEndpoint(
        controllerHost: '10.10.8.108',
        controllerPort: 8770,
        controllerOnBroker: true,
        snapshotHost: '10.10.8.99',
        snapshotPort: 9999,
      );
      expect(s, isNotNull);
      expect(s!.host, '10.10.8.108');
      expect(s.port, 8770);
      expect(s.source, BrokerSuggestionSource.controllerLink);
    });

    test('falls back to the device persisted endpoint when on P2P', () {
      final s = suggestBrokerEndpoint(
        controllerHost: '10.10.8.45',
        controllerPort: 8770,
        // Controller is on P2P: its own host is NOT a Broker address.
        controllerOnBroker: false,
        snapshotHost: '10.10.8.108',
        snapshotPort: 8771,
        snapshotSecure: true,
      );
      expect(s!.host, '10.10.8.108');
      expect(s.port, 8771);
      expect(s.secure, isTrue);
      expect(s.source, BrokerSuggestionSource.deviceSnapshot);
    });

    test('never suggests the controller own host while on P2P', () {
      final s = suggestBrokerEndpoint(
        controllerHost: '10.10.8.45',
        controllerOnBroker: false,
      );
      // Nothing trustworthy: must stay empty rather than hand back 10.10.8.45.
      expect(s, isNull);
    });

    test('uses announce broker_hint as the weakest candidate', () {
      final s = suggestBrokerEndpoint(
        controllerOnBroker: false,
        announceHint: '10.10.8.60:8770',
      );
      expect(s!.host, '10.10.8.60');
      expect(s.port, 8770);
      expect(s.source, BrokerSuggestionSource.announceHint);
    });

    test('bare host hint takes the default port', () {
      final s = suggestBrokerEndpoint(announceHint: '10.10.8.60');
      expect(s!.host, '10.10.8.60');
      expect(s.port, 8770);
    });

    test('bracketed IPv6 hint parses host and port', () {
      final s = suggestBrokerEndpoint(announceHint: '[fe80::1]:8890');
      expect(s!.host, 'fe80::1');
      expect(s.port, 8890);
    });

    test('rejects malformed or out-of-range hint instead of guessing', () {
      expect(suggestBrokerEndpoint(announceHint: '10.10.8.60:0'), isNull);
      expect(suggestBrokerEndpoint(announceHint: '10.10.8.60:70000'), isNull);
      expect(suggestBrokerEndpoint(announceHint: ':8770'), isNull);
      expect(suggestBrokerEndpoint(announceHint: '10.10.8.60:abc'), isNull);
    });

    test('blank sources yield no suggestion', () {
      expect(
          suggestBrokerEndpoint(
              controllerHost: '   ',
              controllerOnBroker: true,
              snapshotHost: '',
              announceHint: '  '),
          isNull);
    });

    test('missing port falls back to the default, not zero', () {
      final s = suggestBrokerEndpoint(
        controllerHost: '10.10.8.108',
        controllerOnBroker: true,
      );
      expect(s!.port, 8770);
    });

    test('source labels are operator-facing and distinct', () {
      final labels = BrokerSuggestionSource.values.map((e) => e.label).toSet();
      expect(labels.length, BrokerSuggestionSource.values.length);
      expect(labels.any((l) => l.trim().isEmpty), isFalse);
    });
  });
}
