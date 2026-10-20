/// ed25519 keychain: load-or-generate the `auth` key file and sign tokens.
///
/// Hub-pro auth parity with the TS reference (hub-service/keychain.ts):
///
/// - The key file (`auth` in the working directory, matching the TS keychain)
///   is the base64 encoding of the 48-byte PKCS8 DER private key followed by
///   the 44-byte SPKI DER public key (92 bytes total, 124 base64 chars).
/// - A signed token has the shape `key.<pub>.<sig>.<expiry>` where:
///     pub     = base64 of the 44-byte SPKI public key (bytes 48..92 of the
///               file)
///     sig     = base64 ed25519 signature over the signed data
///     expiry  = DECIMAL epoch-seconds string of now + 60 (protocol default;
///               hub-pro rejects it once expired or over 5 minutes ahead)
/// - The signed data depends on the `v` header (Docs/Devices/protocol.md):
///     v: 0    the expiry string alone
///     v: 1    `hub1:<hub key>:<expiry>`, so the token only works on the hub
///             whose key it names
/// - The hub verifies the signature against the embedded public key and treats
///   the key as the connection identity (owner/host/group permissions).
/// - Hub keys learned from `hub/info` are pinned in `hubs.json` beside the key
///   file: `{"<address>": "<hub SPKI>"}` (see [HubPins]).
///
/// Usage:
///
/// ```dart
/// import 'package:hub_service/hub_service.dart';
///
/// final token = await sign();                    // v0 token for a connect
/// final token = await sign(60, hubKey);          // v1 token bound to one hub
/// final pub = await publicKey();                 // the service's public key
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// PKCS8 DER private key length for ed25519 (the first 16 bytes are the
/// PKCS8 header, the remaining 32 are the raw seed).
const int privateDerLength = 48;

/// SPKI DER public key length for ed25519 (the first 12 bytes are the SPKI
/// header, the remaining 32 are the raw public key).
const int publicDerLength = 44;

/// PKCS8 header for an ed25519 private key, followed by the 32-byte seed.
const List<int> _pkcs8Prefix = <int>[
  0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, //
  0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
];

/// SPKI header for an ed25519 public key, followed by the 32 raw key bytes.
const List<int> _spkiPrefix = <int>[
  0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, //
  0x70, 0x03, 0x21, 0x00,
];

String? _keyPath;
Uint8List? _keyData;
SimpleKeyPairData? _keyPair;
Future<SimpleKeyPairData>? _loading;

/// Overrides the key file location (default: `auth` in the cwd, or the
/// `HUBKEY` env var). Pass `null` to reset to the default.
void setKeyPath(String? path) {
  _keyPath = path;
  _keyData = null;
  _keyPair = null;
  _loading = null;
}

String _defaultKeyPath() => Platform.environment['HUBKEY'] ?? 'auth';

/// The service key file in use.
String keyPath() => _keyPath ?? _defaultKeyPath();

/// Loads (or generates) the ed25519 key pair and returns it.
Future<SimpleKeyPairData> _loadOrGenerate() {
  final cached = _keyPair;
  if (cached != null) {
    return Future<SimpleKeyPairData>.value(cached);
  }
  final inFlight = _loading;
  if (inFlight != null) {
    return inFlight;
  }
  final future = _doLoadOrGenerate();
  _loading = future;
  return future;
}

Future<SimpleKeyPairData> _doLoadOrGenerate() async {
  try {
    final bytes = await loadKeyFile(keyPath());
    _keyData = bytes;
    _keyPair = keyPairOf(bytes);
    return _keyPair!;
  } finally {
    _loading = null;
  }
}

/// Key file bytes from its base64 text.
Uint8List decodeKeyFile(String text) {
  final data = base64.decode(text.trim());
  if (data.length != privateDerLength + publicDerLength) {
    throw StateError(
      'Invalid auth key file: expected ${privateDerLength + publicDerLength} '
      'bytes, got ${data.length}',
    );
  }
  return Uint8List.fromList(data);
}

/// The Ed25519 key pair in key file bytes.
SimpleKeyPairData keyPairOf(Uint8List keyFile) => SimpleKeyPairData(
      Uint8List.fromList(
        keyFile.sublist(_pkcs8Prefix.length, privateDerLength),
      ),
      type: KeyPairType.ed25519,
      publicKey: SimplePublicKey(
        Uint8List.fromList(keyFile.sublist(privateDerLength + _spkiPrefix.length)),
        type: KeyPairType.ed25519,
      ),
    );

/// The public half of key file bytes: base64 of the 44-byte SPKI DER.
String spkiOf(Uint8List keyFile) => base64.encode(
      keyFile.sublist(privateDerLength, privateDerLength + publicDerLength),
    );

/// Key file bytes for a 32-byte seed (TS layout).
Future<Uint8List> keyFileBytes(List<int> seed) async {
  final keyPair = await Ed25519().newKeyPairFromSeed(seed);
  final publicKey = await keyPair.extractPublicKey();
  return Uint8List.fromList(
    <int>[..._pkcs8Prefix, ...seed, ..._spkiPrefix, ...publicKey.bytes],
  );
}

/// Loads key file bytes, creating the file if missing. [private] creates it
/// atomically with mode 0600 inside a 0700 directory (device keys).
Future<Uint8List> loadKeyFile(String path, {bool private = false}) async {
  final file = File(path);
  if (await file.exists()) {
    return decodeKeyFile(await file.readAsString());
  }
  final keyPair = await Ed25519().newKeyPair();
  final bytes = await keyFileBytes(await keyPair.extractPrivateKeyBytes());
  if (!private) {
    await file.writeAsString(base64.encode(bytes));
    return bytes;
  }
  final directory = file.parent;
  if (!await directory.exists()) {
    await directory.create(recursive: true);
    await _chmod('700', directory.path);
  }
  final temp = File('${directory.path}/.device.${DateTime.now().microsecondsSinceEpoch}.$pid');
  await temp.create(exclusive: true);
  try {
    await _chmod('600', temp.path);
    await temp.writeAsString(base64.encode(bytes), flush: true);
    if (Platform.isWindows) {
      await temp.rename(path);
      return bytes;
    }
    // A hard link, not a rename: a key another process created first wins.
    final link = await Process.run('ln', <String>[temp.path, path]);
    if (link.exitCode != 0) {
      if (await file.exists()) {
        return decodeKeyFile(await file.readAsString());
      }
      throw FileSystemException('cannot create the key file', path);
    }
    return bytes;
  } finally {
    if (await temp.exists()) {
      await temp.delete();
    }
  }
}

Future<void> _chmod(String mode, String path) async {
  if (Platform.isWindows) {
    return;
  }
  final result = await Process.run('chmod', <String>[mode, path]);
  if (result.exitCode != 0) {
    throw FileSystemException('chmod $mode failed', path);
  }
}

/// The base64 Ed25519 signature of [data] with key file bytes.
Future<String> signData(Uint8List keyFile, String data) async {
  final signature = await Ed25519().sign(
    utf8.encode(data),
    keyPair: keyPairOf(keyFile),
  );
  return base64.encode(signature.bytes);
}

/// An auth token for an exact expiry from key file bytes; v1 (hub-bound)
/// when [hubKey] is set.
Future<String> token(Uint8List keyFile, int expiry, {String? hubKey}) async {
  final data = hubKey != null && hubKey.isNotEmpty ? 'hub1:$hubKey:$expiry' : '$expiry';
  return 'key.${spkiOf(keyFile)}.${await signData(keyFile, data)}.$expiry';
}

/// The hubs.json key for a hub address: a bare port is
/// `ws://localhost:<port>`; a URL keeps its form with the scheme and host
/// lowercased and no trailing slash (channel TS normalization).
String pinAddress(Object address) {
  final text = '$address';
  if (address is int || RegExp(r'^\d+$').hasMatch(text)) {
    return 'ws://localhost:$text';
  }
  var url = text;
  final match = RegExp(r'^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]*)(.*)$', dotAll: true).firstMatch(url);
  if (match != null) {
    var authority = match.group(2)!;
    final at = authority.lastIndexOf('@');
    authority = at < 0
        ? authority.toLowerCase()
        : authority.substring(0, at + 1) + authority.substring(at + 1).toLowerCase();
    url = '${match.group(1)!.toLowerCase()}://$authority${match.group(3)}';
  }
  return url.replaceFirst(RegExp(r'/+$'), '');
}

/// Hub keys pinned per address in `hubs.json` (beside the service key file).
class HubPins {
  HubPins(this.path);

  final String path;

  Map<String, Object?> _load() {
    try {
      final data = jsonDecode(File(path).readAsStringSync());
      return data is Map<String, Object?> ? data : <String, Object?>{};
    } on FileSystemException {
      return <String, Object?>{};
    } on FormatException {
      return <String, Object?>{};
    }
  }

  String? get(String address) {
    final value = _load()[address];
    return value is String ? value : null;
  }

  void set(String address, String hubKey) {
    final pins = _load();
    pins[address] = hubKey;
    _write(pins);
  }

  void forget(String address) {
    final pins = _load();
    if (pins.remove(address) != null) {
      _write(pins);
    }
  }

  void _write(Map<String, Object?> pins) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    final temp = File('$path.${DateTime.now().microsecondsSinceEpoch}.tmp');
    temp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(pins));
    temp.renameSync(path);
  }
}

/// The service's public key: base64 of the 44-byte SPKI DER (bytes 48..92 of
/// the auth file, TS parity).
Future<String> publicKey() async {
  await _loadOrGenerate();
  final data = _keyData!;
  return base64.encode(
    data.sublist(privateDerLength, privateDerLength + publicDerLength),
  );
}

/// A fresh auth token: `key.<pub>.<sig>.<expiry>`.
///
/// With [hubKey] (the pinned hub key) it signs `hub1:<hub key>:<expiry>` for
/// `v: 1`; without it the token is v0, the DECIMAL expiry string alone.
Future<String> sign([int expires = 60, String? hubKey]) async {
  await _loadOrGenerate();
  final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + expires;
  return token(_keyData!, expiry, hubKey: hubKey);
}
