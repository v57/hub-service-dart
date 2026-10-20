import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:channel_dart/client.dart' show Sender;
import 'package:hub_service/hub_service.dart';
import 'package:test/test.dart';

import 'support/fake_hub.dart';

final Map<String, Object?> vectors = jsonDecode(
  File('../../Docs/Devices/vectors.json').readAsStringSync(),
) as Map<String, Object?>;

Map<String, Object?> get context =>
    (vectors['caller']! as Map<String, Object?>)['context']! as Map<String, Object?>;

Map<String, Object?> get hubContext => context['hub']! as Map<String, Object?>;

void main() {
  test('parses the caller', () {
    expect(
      Caller.parse(hubContext['caller']),
      const Caller(
        key: 'MCowBQYDK2VwAyEAgTl3Dqh9F19Wo1Rmw0x+zMuNipG07jeiXfYPW4/Js5Q=',
        device: CallerDevice(id: '8cef065b7af83669150b7d32704d3d3e', name: 'Mac Studio'),
        groups: <String>['owners'],
        owner: true,
      ),
    );
  });

  test('parses anonymous and merged callers', () {
    expect(Caller.parse(<String, Object?>{'groups': <Object?>[]}), const Caller());
    final merged = Caller.parse(<String, Object?>{
      'key': 'A',
      'via': 'H',
      'claimed': <String, Object?>{'key': 'B', 'owner': true},
    });
    expect(merged?.via, 'H');
    expect(merged?.claimed, const Caller(key: 'B', owner: true));
    expect(Caller.parse(null), isNull);
  });

  test('rejects handlers of another shape', () {
    expect(() => Service().post('x', (String body) => body), throwsArgumentError);
  });

  test('handlers get the caller', () async {
    final dir = await Directory.systemTemp.createTemp('hubcaller-dart-');
    setKeyPath('${dir.path}/auth');
    final results = Completer<Map<String, Object?>>();
    final hub = await FakeHub.start(
      onUpdate: (Sender<Object?> sender) async {
        if (results.isCompleted) {
          return;
        }
        try {
          results.complete(<String, Object?>{
            'post': await sender.send<Object?>('whoami', body: 'hi', context: context),
            'plain': await sender.send<Object?>('echo', body: 'hi', context: context),
            'stream': await sender.values<Object?>('whoami/values', context: context).toList(),
            'anonymous': await sender.send<Object?>('whoami', body: 'hi', context: <String, Object?>{}),
          });
        } catch (error) {
          if (!results.isCompleted) {
            results.completeError(error);
          }
        }
      },
    );
    final service = Service(
      address: hub.port,
      hubKey: fakeHubKey,
      device: Device(path: '${dir.path}/device.key'),
    )
      ..post('whoami', (Object? body, Request request) {
        final caller = request.caller ?? const Caller();
        return <Object?>[body, caller.key, caller.owner, request.hubKey];
      })
      ..post('echo', (Object? body) => body)
      ..stream('whoami/values', (Object? body, Request request) async* {
        yield request.caller?.device?.name;
      })
      ..start();
    try {
      final out = await results.future.timeout(const Duration(seconds: 5));
      expect(out['post'], <Object?>['hi', (hubContext['caller']! as Map<String, Object?>)['key'], true, hubContext['hubKey']]);
      expect(out['plain'], 'hi');
      expect(out['stream'], <Object?>['Mac Studio']);
      expect(out['anonymous'], <Object?>['hi', null, false, null]);
    } finally {
      service.stop();
      await hub.stop();
      setKeyPath(null);
      await dir.delete(recursive: true);
    }
  });
}
