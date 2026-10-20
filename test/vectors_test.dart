import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hub_service/hub_service.dart';
import 'package:test/test.dart';

/// Docs/Devices/vectors.json: every string must match exactly.
final Map<String, Object?> vectors = jsonDecode(
  File('../../Docs/Devices/vectors.json').readAsStringSync(),
) as Map<String, Object?>;

Map<String, Object?> section(String name) => vectors[name]! as Map<String, Object?>;

Map<String, Object?> keyVector(String name) => section('keys')[name]! as Map<String, Object?>;

String field(Map<String, Object?> map, String name) => map[name]! as String;

Uint8List key(String name) => decodeKeyFile(field(keyVector(name), 'keyFile'));

List<int> hex(String text) => <int>[
      for (var i = 0; i < text.length; i += 2) int.parse(text.substring(i, i + 2), radix: 16),
    ];

void main() {
  final service = field(keyVector('service'), 'publicKey');

  test('key files and public keys', () async {
    for (final name in <String>['hub', 'service', 'device']) {
      final vector = keyVector(name);
      expect(spkiOf(key(name)), field(vector, 'publicKey'));
      expect(base64.encode(await keyFileBytes(hex(field(vector, 'seed')))), field(vector, 'keyFile'));
    }
  });

  test('device id and safety code', () {
    final device = keyVector('device');
    expect(deviceId(field(device, 'publicKey')), field(device, 'deviceId'));
    expect(safetyCode(field(device, 'publicKey')), field(device, 'safetyCode'));
  });

  test('auth tokens', () async {
    final auth = section('auth');
    final expiry = auth['expiry']! as int;
    expect(await token(key('service'), expiry), field(auth['v0']! as Map<String, Object?>, 'header'));
    expect(
      await token(key('service'), expiry, hubKey: field(keyVector('hub'), 'publicKey')),
      field(auth['v1']! as Map<String, Object?>, 'header'),
    );
  });

  test('certificates', () async {
    final header = await issueCertificate(
      key('device'),
      service: service,
      instance: 's3-local/Backup Disk',
      iat: 1792500000,
      exp: 1793104800,
      deviceName: 'Mac Studio',
      platform: 'macos',
    );
    expect(header, field(section('certificate'), 'header'));
    expect(header.split('.').first, field(section('certificate'), 'payload'));
    final child = await issueCertificate(
      key('device'),
      service: service,
      instance: 'builder',
      iat: 1792500000,
      exp: 1793104800,
      deviceName: 'builder',
      platform: 'linux',
      parent: 'Mac Studio',
    );
    expect(child, field(section('childCertificate'), 'header'));
  });

  test('a Device issues the vector certificate', () async {
    final device = Device(key: key('device'), name: 'Mac Studio', platform: 'macos');
    expect(await device.id(), field(keyVector('device'), 'deviceId'));
    expect(
      await device.certificate(service, 's3-local/Backup Disk', now: 1792500000),
      field(section('certificate'), 'header'),
    );
  });
}
