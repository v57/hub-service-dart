import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:hub_service/hub_service.dart';
import 'package:test/test.dart';

Map<String, Object?> decode(String header) => jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(header.split('.').first))),
    ) as Map<String, Object?>;

void main() {
  late Directory dir;
  late String keyPath;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('hubdevice-dart-');
    keyPath = '${dir.path}/hub/device.key';
    setKeyPath('${dir.path}/auth');
  });

  tearDown(() async {
    setKeyPath(null);
    await dir.delete(recursive: true);
  });

  test('the key file is created private and reused', () async {
    final key = await Device(path: keyPath).publicKey();
    expect(File(keyPath).statSync().mode & 0x1ff, 0x180); // 0600
    expect(Directory('${dir.path}/hub').statSync().mode & 0x1ff, 0x1c0); // 0700
    expect(base64.decode(File(keyPath).readAsStringSync()).length, 92);
    expect(await Device(path: keyPath).publicKey(), key);
    expect(
      Directory('${dir.path}/hub').listSync().map((FileSystemEntity e) => e.uri.pathSegments.last),
      <String>['device.key'],
    );
  });

  test('the certificate is signed by the device over the payload', () async {
    final device = Device(path: keyPath, name: 'Mac Studio', platform: 'macos');
    final header = await device.certificate('SERVICE', 's3-local/Backup Disk', now: 1792500000);
    final parts = header.split('.');
    final valid = await Ed25519().verify(
      utf8.encode(parts[0]),
      signature: Signature(
        base64.decode(parts[1]),
        publicKey: SimplePublicKey(
          base64.decode(await device.publicKey()).sublist(12),
          type: KeyPairType.ed25519,
        ),
      ),
    );
    expect(valid, isTrue);
    final body = decode(header);
    expect(body.keys, <String>['v', 'device', 'service', 'instance', 'deviceName', 'platform', 'iat', 'exp']);
    expect((body['exp']! as int) - (body['iat']! as int), certificateLifetime);
  });

  test('the certificate is renewed with less than a day left', () async {
    final device = Device(path: keyPath);
    final first = await device.certificate('SERVICE', 'echo', now: 1000);
    expect(await device.certificate('SERVICE', 'echo', now: 1000 + 5 * 86400), first);
    final renewed = await device.certificate('SERVICE', 'echo', now: 1000 + 6 * 86400 + 1);
    expect(renewed, isNot(first));
    expect(certificateExpiry(renewed), 1000 + 6 * 86400 + 1 + certificateLifetime);
  });

  test('the service sends a device header for its key', () async {
    final service = Service(address: 1, instance: 'echo/main', device: Device(path: keyPath));
    final headers = await service.authHeaders();
    final body = decode(headers['device']!);
    expect(body['service'], await publicKey());
    expect(body['service'], headers['auth']!.split('.')[1]);
    expect(body['instance'], 'echo/main');
    expect(body['device'], await service.device!.publicKey());
  });

  test('instance defaults to HUB_INSTANCE, the name or the cwd name', () {
    final env = Platform.environment['HUB_INSTANCE'];
    final cwd = Directory.current.uri.pathSegments.where((String s) => s.isNotEmpty).last;
    expect(Service().instance, env ?? cwd);
    expect(Service(name: 'Echo').instance, env ?? 'Echo');
    expect(Service(instance: 'mine').instance, 'mine');
    expect(Service(instance: 'é' * 100).instance, 'é' * 64);
  });

  test('the instance length is checked', () {
    expect(
      () => Device(path: keyPath).certificate('SERVICE', 'x' * 129),
      throwsArgumentError,
    );
  });

  test('device mode off sends no header', () async {
    final headers = await Service(address: 1, device: false).authHeaders();
    expect(headers.containsKey('device'), isFalse);
  });

  test('an unusable device key falls back to a plain key connection', () async {
    File('${dir.path}/blocked').writeAsStringSync('not a directory');
    final service = Service(address: 1, device: Device(path: '${dir.path}/blocked/device.key'));
    final headers = await service.authHeaders();
    expect(headers.containsKey('device'), isFalse);
    expect(headers['auth'], startsWith('key.'));
  });

  test('HUB_DEVICE_KEY or ~/.hub/device.key is the default path', () {
    final env = Platform.environment['HUB_DEVICE_KEY'];
    expect(
      defaultDeviceKeyPath(),
      env != null && env.isNotEmpty ? env : '${Platform.environment['HOME']}/.hub/device.key',
    );
  });
}
