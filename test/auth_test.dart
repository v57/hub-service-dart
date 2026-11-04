import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:hub_service/hub_service.dart';
import 'package:test/test.dart';

import 'support/fake_hub.dart';

/// Verifies [token]'s signature over its hub, challenge and expiry with its
/// embedded key.
Future<bool> verify(String token) {
  final parts = token.split('.');
  return Ed25519().verify(
    utf8.encode('hub1:$fakeHubKey:${parts[4]}:${parts[3]}'),
    signature: Signature(
      base64.decode(parts[2]),
      publicKey: SimplePublicKey(
        base64.decode(parts[1]).sublist(12),
        type: KeyPairType.ed25519,
      ),
    ),
  );
}

Map<String, Object?> section(String name) => vectors[name]! as Map<String, Object?>;

Future<void> pause(int milliseconds) => Future<void>.delayed(Duration(milliseconds: milliseconds));

Map<String, Object?> noProof(String nonce, String challenge) =>
    <String, Object?>{'key': fakeHubKey, 'protocol': 2, 'challenge': challenge};

/// Claims the real hub's key, signs with its own.
Future<Map<String, Object?>> anotherSigns(String nonce, String challenge) async =>
    <String, Object?>{...await proving('service')(nonce, challenge), 'key': fakeHubKey};

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

  test('the token matches the vector', () async {
    final auth = section('auth');
    final service = decodeKeyFile(keyVector('service')['keyFile']! as String);
    expect(
      await token(service, auth['expiry']! as int, fakeHubKey, auth['nonce']! as String),
      (auth['v1']! as Map<String, Object?>)['header'],
    );
  });

  test('the proof matches the vector', () async {
    final info = section('hubInfo');
    final nonce = info['nonce']! as String;
    expect(hubInfoSignedData(fakeHubKey, nonce), info['signedData']);
    final answer = <String, Object?>{'key': fakeHubKey, 'proof': info['proof'], 'challenge': 'c'};
    expect(await verifyHubProof(answer, nonce), isTrue);
    expect(await verifyHubProof(answer, 'another-nonce-another-nonce'), isFalse);
    expect(await verifyHubProof(<String, Object?>{...answer, 'key': keyVector('service')['publicKey']}, nonce), isFalse);
    expect(await verifyHubProof(<String, Object?>{'key': fakeHubKey, 'challenge': 'c'}, nonce), isFalse);
    expect(await verifyHubProof(<String, Object?>{'key': fakeHubKey, 'proof': info['proof']}, nonce), isFalse);
    expect(await verifyHubProof('no answer', nonce), isFalse);
  });

  test('transports match the vectors', () {
    for (final vector in vectors['transport']! as List<Object?>) {
      final entry = vector! as Map<String, Object?>;
      expect(hubTransportOf(entry['url']! as String).name, entry['transport'], reason: entry['url']! as String);
    }
    expect(hubTransportOf(1997), HubTransport.loopback);
    expect(hubTransportOf('1997'), HubTransport.loopback);
  });

  test('a client nonce is 32 bytes of base64url', () {
    final nonce = makeClientNonce();
    expect(nonce, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    expect(makeClientNonce(), isNot(nonce));
  });

  test('a token lasts thirty seconds, over the challenge', () async {
    final signed = await sign(fakeHubKey, 'challenge');
    expect(await verify(signed), isTrue);
    expect(signed.split('.')[4], 'challenge');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    expect(int.parse(signed.split('.')[3]), closeTo(now + 30, 5));
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

  test('a token goes out only after the proof, and the key is pinned', () async {
    final hub = await FakeHub.start();
    final service = Service(address: hub.port, device: Device(path: '${dir.path}/device.key'))..start();
    try {
      // A call made right away waits for the authenticated connection.
      expect(await service.send('test/echo', body: 'hi').timeout(const Duration(seconds: 5)), 'hi');
      expect(hub.connects.first.containsKey('auth'), isFalse);
      expect(hub.connects.first.containsKey('device'), isFalse);
      final connect = hub.connects.last;
      expect(connect['v'], '1');
      expect(connect.containsKey('device'), isTrue);
      expect(await verify(connect['auth']!), isTrue);
      expect(connect['auth']!.split('.')[4], 'challenge-1');
      expect(HubPins('${dir.path}/hubs.json').get(service.target), fakeHubKey);
      expect(service.hubKey, fakeHubKey);
      service.forgetHubKey();
      expect(service.hubKey, isNull);
    } finally {
      service.stop();
      await hub.stop();
    }
  });

  test('each connect has its own challenge', () async {
    final nonces = <String>[];
    final prove = proving();
    final hub = await FakeHub.start(answer: (String nonce, String challenge) {
      nonces.add(nonce);
      return prove(nonce, challenge);
    });
    final service = Service(address: hub.port, device: false)..start();
    try {
      await hub.waitUpdates(1);
      // The hub drops the connection: the reconnect asks again.
      await hub.dropConnections();
      await hub.waitUpdates(2);
      expect(nonces, hasLength(2));
      expect(nonces[0], isNot(nonces[1]));
      final tokens = hub.credentials.map((Map<String, String> h) => h['auth']!).toList();
      expect(tokens.map((String t) => t.split('.')[4]), <String>['challenge-1', 'challenge-2']);
      for (final signed in tokens) {
        expect(await verify(signed), isTrue);
      }
    } finally {
      service.stop();
      await hub.stop();
    }
  });

  for (final entry in <String, HubAnswer>{'no proof': noProof, "another key's proof": anotherSigns}.entries) {
    test('a hub with ${entry.key} gets nothing and is not pinned', () async {
      final hub = await FakeHub.start(answer: entry.value);
      final service = Service(address: hub.port, device: Device(path: '${dir.path}/device.key'))..start();
      try {
        await pause(1500);
        expect(hub.connects.length, greaterThanOrEqualTo(2), reason: 'it keeps asking');
        expect(hub.credentials, isEmpty);
        expect(hub.updates, 0);
        expect(service.hubKey, isNull);
        expect(File('${dir.path}/hubs.json').existsSync(), isFalse);
        expect(service.lastError, contains("didn't prove"));
      } finally {
        service.stop();
        await hub.stop();
      }
    });
  }

  test('a hub with another key than the pin gets nothing', () async {
    // Proves its own key, but this address is pinned to the real hub's.
    final hub = await FakeHub.start(answer: proving('service'));
    final service = Service(address: hub.port, device: false);
    service.pins.set(service.target, fakeHubKey);
    service.start();
    try {
      await pause(1200);
      expect(hub.credentials, isEmpty);
      expect(hub.updates, 0);
      expect(service.pins.get(service.target), fakeHubKey);
      expect(service.lastError, contains('not the pinned'));
    } finally {
      service.stop();
      await hub.stop();
    }
  });

  test('a supplied hub key is a pin', () async {
    final hub = await FakeHub.start(answer: proving('service'));
    final service = Service(address: hub.port, hubKey: fakeHubKey, device: false)..start();
    try {
      await pause(400);
      expect(hub.credentials, isEmpty);
      expect(service.hubKey, fakeHubKey);
    } finally {
      service.stop();
      await hub.stop();
    }
  });

  test('stop ends the wait for a proof', () async {
    final hub = await FakeHub.start(answer: noProof);
    final service = Service(address: hub.port, device: false);
    try {
      service.start();
      await pause(200);
      final asked = hub.connects.length;
      service.stop();
      await pause(1500);
      expect(hub.connects.length, lessThanOrEqualTo(asked + 1));
    } finally {
      await hub.stop();
    }
  });

  test('a custom sign gets the proven key and the challenge, after the proof', () async {
    final calls = <List<String>>[];
    Future<String> custom(String hubKey, String challenge) {
      calls.add(<String>[hubKey, challenge]);
      return sign(hubKey, challenge);
    }

    final silent = await FakeHub.start(answer: noProof);
    final refused = Service(address: silent.port, sign: custom, device: false)..start();
    await pause(300);
    expect(calls, isEmpty);
    refused.stop();
    await silent.stop();

    final hub = await FakeHub.start();
    final service = Service(address: hub.port, sign: custom, device: false)..start();
    try {
      await hub.waitUpdates(1);
      expect(calls, <List<String>>[
        <String>[fakeHubKey, 'challenge-1'],
      ]);
    } finally {
      service.stop();
      await hub.stop();
    }
  });

  test('a public ws:// address is not dialed', () {
    final service = Service(address: 'ws://hub.example.com:1997', device: false)..start();
    expect(service.lastError, contains('unencrypted'));
    expect(() => service.send('x'), throwsA(predicate((Object? e) => '$e'.contains('unencrypted'))));
    service.stop();
  });

  test('allowPlaintext dials it', () async {
    final service = Service(address: 'ws://hub.invalid-name:1', allowPlaintext: true, device: false)..start();
    expect(service.lastError, isNull);
    final call = service.send('x');
    service.stop();
    await expectLater(call, throwsA(anything));
  });
}
