import 'dart:io';

import 'package:channel_dart/server.dart';
import 'package:hub_service/hub_service.dart';
import 'package:test/test.dart';

void main() {
  test('each connect sends the profile and service updates once', () async {
    final dir = await Directory.systemTemp.createTemp('hubconnect-dart-');
    setKeyPath('${dir.path}/auth');
    final paths = <String>[];
    final channel = Channel<Object?>()
      ..post('hub/profile/update', (ChannelBody<Object?> body) {
        paths.add(body.path);
        return null;
      })
      ..post('hub/service/update', (ChannelBody<Object?> body) {
        paths.add(body.path);
        return null;
      });
    final server = await channel.listen(0);
    final service = Service(address: server.httpServer.port, name: 'Echo', device: false)
      ..post('echo', (Object? body) => body)
      ..start();
    try {
      for (var i = 0; i < 100 && paths.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(paths, <String>['hub/profile/update', 'hub/service/update']);
    } finally {
      service.stop();
      await server.stop();
      setKeyPath(null);
      await dir.delete(recursive: true);
    }
  });
}
