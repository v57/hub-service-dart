/// Device key and service certificates (Docs/Devices/protocol.md).
///
/// - The device key lives in `~/.hub/device.key` (`/var/lib/hub/device.key`
///   for a Linux system service, `HUB_DEVICE_KEY` overrides both) in the same
///   layout as the `auth` file. It is created atomically on first use.
/// - A service certificate is `<base64url(JSON)>.<base64 signature>`, signed
///   by the device key over the payload string, and sent in the `device`
///   header. It names the service key, the instance and the device's
///   suggested name.
///
/// Usage:
///
/// ```dart
/// final device = Device();                       // ~/.hub/device.key
/// final header = await device.certificate(serviceKey, 's3-local/Backup Disk');
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'keychain.dart' as keychain;

/// Certificate lifetime: 7 days.
const int certificateLifetime = 7 * 24 * 3600;

/// Certificates are renewed at connect with less than this left (24 h).
const int certificateRenewal = 24 * 3600;

/// `HUB_DEVICE_KEY`, else the system or user location.
String defaultDeviceKeyPath() {
  final env = Platform.environment['HUB_DEVICE_KEY'];
  if (env != null && env.isNotEmpty) {
    return env;
  }
  if (Platform.isLinux && _isRoot()) {
    return '/var/lib/hub/device.key';
  }
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
  return '$home/.hub/device.key';
}

bool _isRoot() {
  try {
    return '${Process.runSync('id', <String>['-u']).stdout}'.trim() == '0';
  } catch (_) {
    return false;
  }
}

List<int> _sha256(String publicKey) =>
    Sha256().toSync().hashSync(base64.decode(publicKey)).bytes;

String _hex(List<int> bytes) =>
    bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();

/// First 32 hex characters of SHA-256 over the device SPKI DER.
String deviceId(String publicKey) => _hex(_sha256(publicKey)).substring(0, 32);

/// The code shown on both sides when approving a device: `"ddd ddd"`.
String safetyCode(String publicKey) {
  final n = int.parse(_hex(_sha256(publicKey)).substring(0, 8), radix: 16) % 1000000;
  final digits = n.toString().padLeft(6, '0');
  return '${digits.substring(0, 3)} ${digits.substring(3)}';
}

/// The protocol platform string for this OS.
String defaultPlatform() {
  if (Platform.isMacOS) return 'macos';
  if (Platform.isLinux) return 'linux';
  if (Platform.isWindows) return 'windows';
  if (Platform.isIOS) return 'ios';
  if (Platform.isAndroid) return 'android';
  return 'other';
}

/// The macOS computer name, else the host name.
String defaultDeviceName() {
  if (Platform.isMacOS) {
    try {
      final result = Process.runSync('scutil', <String>['--get', 'ComputerName']);
      final name = '${result.stdout}'.trim();
      if (result.exitCode == 0 && name.isNotEmpty) {
        return name;
      }
    } catch (_) {}
  }
  final name = Platform.localHostname;
  return name.isEmpty ? 'device' : name.replaceFirst(RegExp(r'\.local$'), '');
}

/// A service certificate from device key file bytes, fields in protocol
/// order with no whitespace.
Future<String> issueCertificate(
  Uint8List deviceKey, {
  required String service,
  required String instance,
  required int iat,
  required int exp,
  String? deviceName,
  String? platform,
  String? parent,
}) async {
  final instanceBytes = utf8.encode(instance).length;
  if (instanceBytes < 1 || instanceBytes > 128) {
    throw ArgumentError.value(instance, 'instance', 'must be 1-128 UTF-8 bytes');
  }
  if (parent != null && utf8.encode(parent).length > 64) {
    throw ArgumentError.value(parent, 'parent', 'must be at most 64 UTF-8 bytes');
  }
  final payload = <String, Object?>{
    'v': 1,
    'device': keychain.spkiOf(deviceKey),
    'service': service,
    'instance': instance,
    if (deviceName != null) 'deviceName': deviceName,
    if (platform != null) 'platform': platform,
    if (parent != null) 'parent': parent,
    'iat': iat,
    'exp': exp,
  };
  final encoded = base64Url.encode(utf8.encode(jsonEncode(payload))).replaceAll('=', '');
  return '$encoded.${await keychain.signData(deviceKey, encoded)}';
}

/// The `exp` of a certificate header.
int certificateExpiry(String header) {
  final payload = header.split('.').first;
  final json = utf8.decode(base64Url.decode(base64Url.normalize(payload)));
  return (jsonDecode(json) as Map<String, Object?>)['exp']! as int;
}

/// This device's key and the certificates it issues to services.
class Device {
  /// [path]: the key file (default: [defaultDeviceKeyPath]); [key]: key file
  /// bytes to use instead of a file (tests, or a key kept in another store);
  /// [name]: suggested device name (default: the computer name);
  /// [platform]: protocol platform string (default: from the OS); [parent]:
  /// declared parent device name, for containers and VMs.
  Device({this.path, Uint8List? key, String? name, String? platform, this.parent})
      : _key = key,
        _name = name,
        platform = platform ?? defaultPlatform();

  final String? path;
  final String platform;
  final String? parent;
  Uint8List? _key;
  String? _name;
  final Map<String, String> _certificates = <String, String>{};

  /// Device key file bytes, loaded or created on first use.
  Future<Uint8List> key() async =>
      _key ??= await keychain.loadKeyFile(path ?? defaultDeviceKeyPath(), private: true);

  /// The suggested device name (at most 64 UTF-8 bytes).
  String get name => _name ??= truncateUtf8(defaultDeviceName(), 64);

  Future<String> publicKey() async => keychain.spkiOf(await key());

  Future<String> id() async => deviceId(await publicKey());

  Future<String> safety() async => safetyCode(await publicKey());

  /// The certificate for a service key, renewed with < 24 h left.
  Future<String> certificate(String service, String instance, {int? now}) async {
    final time = now ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final id = '$service\n$instance';
    final cached = _certificates[id];
    if (cached != null && certificateExpiry(cached) - time >= certificateRenewal) {
      return cached;
    }
    return _certificates[id] = await issueCertificate(
      await key(),
      service: service,
      instance: instance,
      iat: time,
      exp: time + certificateLifetime,
      deviceName: name,
      platform: platform,
      parent: parent,
    );
  }

}

/// At most [limit] UTF-8 bytes of [text], cut on a character boundary.
String truncateUtf8(String text, int limit) {
  final buffer = StringBuffer();
  var bytes = 0;
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    bytes += utf8.encode(char).length;
    if (bytes > limit) break;
    buffer.write(char);
  }
  return buffer.toString();
}
