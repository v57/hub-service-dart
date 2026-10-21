import 'dart:async';

import 'package:channel_dart/server.dart';

/// The hub key fake hubs answer hub/info with.
const String fakeHubKey =
    'MCowBQYDK2VwAyEAiojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w=';

/// An in-process hub that records each connect's headers and answers
/// hub/info unless [lite]. [onUpdate] runs on every hub/service/update with
/// the connection's sender (to call the service back).
class FakeHub {
  FakeHub._(this.server);

  final ChannelServer<Object?> server;
  final List<Map<String, String>> connects = <Map<String, String>>[];

  /// network/shares/replace bodies received.
  final List<Map<String, Object?>> replaced = <Map<String, Object?>>[];

  int get port => server.httpServer.port;

  static Future<FakeHub> start({
    bool lite = false,
    void Function(Sender<Object?> sender)? onUpdate,
  }) async {
    late FakeHub hub;
    final channel = Channel<Object?>();
    if (!lite) {
      channel.post(
        'hub/info',
        (ChannelBody<Object?> _) => <String, Object?>{
          'key': fakeHubKey,
          'protocol': 1,
          'pro': true,
          'mode': 'default-allow',
        },
      );
    }
    channel.post('hub/profile/update', (ChannelBody<Object?> _) => null);
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

  Future<void> stop() => server.stop();
}
