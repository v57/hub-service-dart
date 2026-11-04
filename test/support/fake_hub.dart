import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:channel_dart/server.dart';
import 'package:hub_service/hub_service.dart';

final Map<String, Object?> vectors = jsonDecode(
  File('../../Docs/Devices/vectors.json').readAsStringSync(),
) as Map<String, Object?>;

Map<String, Object?> keyVector(String name) =>
    (vectors['keys']! as Map<String, Object?>)[name]! as Map<String, Object?>;

/// The hub key fake hubs answer hub/info with.
final String fakeHubKey = keyVector('hub')['publicKey']! as String;

/// What a hub answers hub/info with.
typedef HubAnswer = FutureOr<Map<String, Object?>> Function(String nonce, String challenge);

/// An answer that proves the key of a vector key.
HubAnswer proving([String name = 'hub']) {
  final vector = keyVector(name);
  final keyFile = decodeKeyFile(vector['keyFile']! as String);
  final key = vector['publicKey']! as String;
  return (String nonce, String challenge) async => <String, Object?>{
        'key': key,
        'protocol': 2,
        'challenge': challenge,
        'proof': await signData(keyFile, hubInfoSignedData(key, nonce)),
      };
}

/// Makes [channel] answer hub/info as [answer] says, default proving the
/// vectors' hub key, with a fresh challenge per question.
void answerHubInfo(Channel<Object?> channel, [HubAnswer? answer]) {
  final respond = answer ?? proving();
  var asked = 0;
  channel.post('hub/info', (ChannelBody<Object?> body) {
    asked += 1;
    return respond((body.body! as Map)['nonce'] as String, 'challenge-$asked');
  });
}

/// An in-process hub that records each connect's headers and answers
/// hub/info as [answer] says. [onUpdate] runs on every hub/service/update with
/// the connection's sender (to call the service back).
class FakeHub {
  FakeHub._(this.server);

  final ChannelServer<Object?> server;
  final List<Map<String, String>> connects = <Map<String, String>>[];

  /// network/shares/replace bodies received.
  final List<Map<String, Object?>> replaced = <Map<String, Object?>>[];

  /// hub/service/update calls received.
  int updates = 0;

  int get port => server.httpServer.port;

  /// The connects that carried credentials.
  List<Map<String, String>> get credentials => connects
      .where((Map<String, String> headers) => headers.containsKey('auth') || headers.containsKey('device'))
      .toList();

  static Future<FakeHub> start({
    HubAnswer? answer,
    void Function(Sender<Object?> sender)? onUpdate,
  }) async {
    late FakeHub hub;
    final channel = Channel<Object?>();
    answerHubInfo(channel, answer);
    channel.post('hub/profile/update', (ChannelBody<Object?> _) => null);
    channel.post('test/echo', (ChannelBody<Object?> body) => body.body);
    channel.post('network/shares/replace', (ChannelBody<Object?> body) {
      final request = Map<String, Object?>.from(body.body! as Map);
      hub.replaced.add(request);
      return <String, Object?>{
        'shares': <Object?>[
          for (final share in request['shares']! as List)
            <String, Object?>{
              'version': 1,
              'resourceId': 'hnr1_${share['name']}',
              'authority': '${share['name']}.hub.invalid',
              'providerId': 'provider',
              'protocol': share['protocol'],
              'overlayAddress': '100.96.0.2',
              'port': (share['target'] as Map)['port'],
            },
        ],
      };
    });
    channel.post('hub/service/update', (ChannelBody<Object?> body) {
      hub.updates += 1;
      if (onUpdate != null) {
        scheduleMicrotask(() => onUpdate(body.sender));
      }
      return null;
    });
    final server = await channel.listen(
      0,
      options: ListenOptions<Object?>(
        state: (Map<String, String> headers) {
          hub.connects.add(Map<String, String>.of(headers));
          return null;
        },
      ),
    );
    hub = FakeHub._(server);
    return hub;
  }

  Future<void> waitConnects(int count) async {
    for (var i = 0; i < 250 && connects.length < count; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (connects.length < count) {
      throw StateError('expected $count connects, got ${connects.length}');
    }
  }

  Future<void> waitUpdates(int count) async {
    for (var i = 0; i < 250 && updates < count; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (updates < count) {
      throw StateError('expected $count service updates, got $updates');
    }
  }

  /// Closes every connection, as a restarting hub would.
  Future<void> dropConnections() async {
    for (final connection in server.connections.toList()) {
      await connection.socket.close();
    }
  }

  Future<void> stop() => server.stop();
}
