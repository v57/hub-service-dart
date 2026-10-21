import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:channel_dart/client.dart' show Sender;
import 'package:hub_service/hub_service.dart';
import 'package:test/test.dart';

import 'support/fake_hub.dart';

/// The hub-net agent's /challenge and /attest over a Unix socket.
class FakeAgent {
  FakeAgent._(this._server, this.expired);

  final ServerSocket _server;
  final bool expired;
  final Map<String, String> _nonces = <String, String>{};

  static Future<FakeAgent> start(String path, {bool expired = false}) async {
    final server = await ServerSocket.bind(InternetAddress(path, type: InternetAddressType.unix), 0);
    final agent = FakeAgent._(server, expired);
    server.listen(agent._handle);
    return agent;
  }

  Future<void> stop() => _server.close();

  Future<void> _handle(Socket client) async {
    final raw = <int>[];
    await for (final chunk in client) {
      raw.addAll(chunk);
      final text = utf8.decode(raw, allowMalformed: true);
      final split = text.indexOf('\r\n\r\n');
      if (split < 0) continue;
      final length = int.parse(RegExp(r'content-length: *(\d+)', caseSensitive: false).firstMatch(text)!.group(1)!);
      if (utf8.encode(text.substring(split + 4)).length < length) continue;
      final (status, reply) = await _route(text.split(' ')[1], jsonDecode(text.substring(split + 4)) as Map);
      client.add(utf8.encode('HTTP/1.1 $status OK\r\nContent-Length: ${utf8.encode(reply).length}\r\n\r\n$reply'));
      await client.flush();
      break;
    }
    await client.close();
  }

  Future<(int, String)> _route(String path, Map<Object?, Object?> body) async {
    final name = body['shareName']! as String;
    if (path == '/challenge') {
      _nonces[name] = 'nonce-$name';
      return (200, jsonEncode(<String, Object?>{'nonce': _nonces[name]}));
    }
    if (path == '/attest') {
      final valid = await Ed25519().verify(
        utf8.encode(_nonces[name]!),
        signature: Signature(
          base64.decode(body['signature']! as String),
          publicKey: SimplePublicKey(
            base64.decode(body['serviceKey']! as String).sublist(12),
            type: KeyPairType.ed25519,
          ),
        ),
      ).catchError((Object _) => false);
      if (!valid) return (403, 'bad signature');
      final issued = DateTime.now().toUtc().subtract(Duration(seconds: expired ? 600 : 0));
      return (200, jsonEncode(<String, Object?>{
        'version': 1,
        'attestationId': 'att-$name',
        'serviceKey': body['serviceKey'],
        'key': 'agent-key',
        'shareName': name,
        'protocol': body['protocol'],
        'target': body['target'],
        'issuedAt': issued.toIso8601String(),
        'expiresAt': issued.add(const Duration(seconds: 300)).toIso8601String(),
        'signature': 'c2lnbmF0dXJl',
      }));
    }
    return (404, 'not found');
  }
}

Map<String, Object?> share([String name = 's3', int port = 9001]) => <String, Object?>{
      'name': name,
      'protocol': 'tcp',
      'target': <String, Object?>{'host': '127.0.0.1', 'port': port},
    };

void main() {
  late Directory dir;
  late Directory socketDir;
  late String socket;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('hubnet-dart-');
    // Unix socket paths are short.
    socketDir = await Directory('/tmp').createTemp('hn');
    socket = '${socketDir.path}/agent.sock';
    setKeyPath('${dir.path}/auth');
  });

  tearDown(() async {
    setKeyPath(null);
    await dir.delete(recursive: true);
    await socketDir.delete(recursive: true);
  });

  test('share validation', () {
    validateShare(share());
    for (final bad in <Map<String, Object?>>[
      <String, Object?>{...share(), 'name': ''},
      <String, Object?>{...share(), 'protocol': 'sctp'},
      <String, Object?>{...share(), 'target': <String, Object?>{'host': 'h', 'port': 70000}},
      <String, Object?>{...share(), 'policy': <String, Object?>{'mode': 'keys', 'keys': <Object?>[]}},
    ]) {
      expect(() => validateShare(bad), throwsArgumentError);
    }
  });

  test('declared shares publish on connect and follow updates', () async {
    final agent = await FakeAgent.start(socket);
    final hub = await FakeHub.start();
    final service = Service(address: hub.port, hubKey: fakeHubKey, device: false)
      ..network.agentSocket = socket
      ..share('s3', 'tcp', '127.0.0.1', 9001, <String, Object?>{'mode': 'hub'})
      ..start();
    try {
      for (var i = 0; i < 100 && hub.replaced.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final wire = (hub.replaced.first['shares']! as List).first as Map;
      expect(<Object?>[wire['name'], wire['version'], wire['policy']], <Object?>['s3', 1, <String, Object?>{'mode': 'hub'}]);
      expect((wire['attestation'] as Map)['serviceKey'], await publicKey());
      expect(service.sharePublication('s3')?['resourceId'], 'hnr1_s3');

      List<Object?> last() => hub.replaced.last['shares']! as List;
      await service.publishShare('ssh', 'tcp', '127.0.0.1', 22);
      expect(last().map((Object? s) => (s! as Map)['name']), <String>['s3', 'ssh']);
      expect((last()[1]! as Map)['policy'], <String, Object?>{'mode': 'private'});

      await service.updateShare('ssh', port: 2222);
      expect((last()[1]! as Map)['target'], <String, Object?>{'host': '127.0.0.1', 'port': 2222});
      expect(service.sharePublication('ssh')?['port'], 2222);

      await service.removeShare('s3');
      expect(last().map((Object? s) => (s! as Map)['name']), <String>['ssh']);
      expect(service.sharePublications.map((Map<String, Object?> p) => p['resourceId']), <String>['hnr1_ssh']);
    } finally {
      service.stop();
      await hub.stop();
      await agent.stop();
    }
  });

  test('an expired attestation is refused and rolled back', () async {
    final agent = await FakeAgent.start(socket, expired: true);
    final publisher = NetworkPublisher(agentSocket: socket);
    try {
      await expectLater(
        publisher.publishShare(share(), await publicKey(), signChallenge, _NoSender()),
        throwsA(isA<LocalAgentError>().having((LocalAgentError e) => e.code, 'code', 'attestation-expired')),
      );
      expect(publisher.hasShares, isFalse);
    } finally {
      await agent.stop();
    }
  });

  test('agent unavailable and rejected', () async {
    final publisher = NetworkPublisher(agentSocket: socket);
    await expectLater(
      publisher.requestAttestation(share(), await publicKey(), signChallenge),
      throwsA(isA<LocalAgentError>().having((LocalAgentError e) => e.code, 'code', 'agent-unavailable')),
    );
    final agent = await FakeAgent.start(socket);
    try {
      await expectLater(
        publisher.requestAttestation(share(), await publicKey(), (String _) => 'AAAA'),
        throwsA(isA<LocalAgentError>()
            .having((LocalAgentError e) => e.code, 'code', 'agent-rejected')
            .having((LocalAgentError e) => e.status, 'status', 403)),
      );
    } finally {
      await agent.stop();
    }
  });
}

/// A sender that is never reached (attestation fails first).
class _NoSender implements Sender<Object?> {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('not reached');
}
