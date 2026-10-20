import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:hub_service/hub_service.dart';
import 'package:test/test.dart';

import 'support/fake_hub.dart';

/// Verifies [token]'s signature over [signed] with its embedded key.
Future<bool> verify(String token, String signed) {
  final parts = token.split('.');
  return Ed25519().verify(
    utf8.encode(signed),
    signature: Signature(
      base64.decode(parts[2]),
      publicKey: SimplePublicKey(
        base64.decode(parts[1]).sublist(12),
        type: KeyPairType.ed25519,
      ),
    ),
  );
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('hubauth-dart-');
    setKeyPath('${dir.path}/auth');
  });

  tearDown(() async {
    setKeyPath(null);
    await dir.delete(recursive: true);
  });

  test('v0 and v1 tokens sign the expiry and the hub key', () async {
    final v0 = await sign();
    expect(await verify(v0, v0.split('.')[3]), isTrue);
    final v1 = await sign(60, fakeHubKey);
    expect(await verify(v1, 'hub1:$fakeHubKey:${v1.split('.')[3]}'), isTrue);
  });

  test('pins round trip in hubs.json', () {
    final pins = HubPins('${dir.path}/hubs.json');
    expect(pins.get('ws://localhost:1997'), isNull);
    pins.set('ws://localhost:1997', fakeHubKey);
    expect(
      jsonDecode(File('${dir.path}/hubs.json').readAsStringSync()),
      <String, Object?>{'ws://localhost:1997': fakeHubKey},
    );
    pins.forget('ws://localhost:1997');
    expect(pins.get('ws://localhost:1997'), isNull);
  });

  test('pin addresses are normalized', () {
    expect(pinAddress(1997), 'ws://localhost:1997');
    expect(pinAddress('1997'), 'ws://localhost:1997');
    expect(pinAddress('WS://Hub.Example.COM:2000/'), 'ws://hub.example.com:2000');
    expect(pinAddress('wss://hub.example.com/Path/'), 'wss://hub.example.com/Path');
    expect(Service(address: 1997, device: false).target, 'ws://localhost:1997');
  });

  test('a supplied hub key connects with v1', () async {
    final headers = await Service(address: 1, hubKey: fakeHubKey, device: false).authHeaders();
    expect(headers['v'], '1');
    final auth = headers['auth']!;
    expect(await verify(auth, 'hub1:$fakeHubKey:${auth.split('.')[3]}'), isTrue);
  });

  test('a plain sign factory stays on v0', () async {
    final service = Service(address: 1, hubKey: fakeHubKey, sign: () => sign(), device: false);
    expect((await service.authHeaders())['v'], '0');
  });

  test('learns and pins the hub key, then reconnects with v1', () async {
    final hub = await FakeHub.start();
    final service = Service(address: hub.port, device: Device(path: '${dir.path}/device.key'))..start();
    try {
      await hub.waitConnects(2);
      expect(hub.connects[0]['v'], '0');
      expect(hub.connects[1]['v'], '1');
      final auth = hub.connects[1]['auth']!;
      expect(await verify(auth, 'hub1:$fakeHubKey:${auth.split('.')[3]}'), isTrue);
      expect(HubPins('${dir.path}/hubs.json').get(service.target), fakeHubKey);
      service.forgetHubKey();
      expect(service.hubKey, isNull);
    } finally {
      service.stop();
      await hub.stop();
    }
  });

  test('hub-lite keeps v0', () async {
    final hub = await FakeHub.start(lite: true);
    final service = Service(address: hub.port, device: Device(path: '${dir.path}/device.key'))..start();
    try {
      await hub.waitConnects(1);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(hub.connects.map((Map<String, String> h) => h['v']), <String>['0']);
      expect(File('${dir.path}/hubs.json').existsSync(), isFalse);
    } finally {
      service.stop();
      await hub.stop();
    }
  });
}
