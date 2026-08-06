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
///     sig     = base64 ed25519 signature over the expiry STRING
///     expiry  = DECIMAL epoch-seconds string of now + 10 (TS parity; hub-pro
///               reads it as base-36, so the decimal form never trips expiry)
/// - The hub verifies the signature against the embedded public key and treats
///   the key as the connection identity (owner/host/group permissions).
///
/// Usage:
///
/// ```dart
/// import 'package:hub_service/hub_service.dart';
///
/// final token = await sign();      // fresh token for a connect
/// final pub = await publicKey();   // the service's public key (identity)
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
  final path = _keyPath ?? _defaultKeyPath();
  final file = File(path);
  final List<int> data;
  if (await file.exists()) {
    data = base64.decode((await file.readAsString()).trim());
  } else {
    data = await _generate();
    await file.writeAsString(base64.encode(data));
  }
  if (data.length != privateDerLength + publicDerLength) {
    throw StateError(
      'Invalid auth key file: expected ${privateDerLength + publicDerLength} '
      'bytes, got ${data.length}',
    );
  }
  final bytes = Uint8List.fromList(data);
  _keyData = bytes;
  _keyPair = SimpleKeyPairData(
    Uint8List.fromList(bytes.sublist(_pkcs8Prefix.length, privateDerLength)),
    type: KeyPairType.ed25519,
    publicKey: SimplePublicKey(
      Uint8List.fromList(
        bytes.sublist(privateDerLength + _spkiPrefix.length),
      ),
      type: KeyPairType.ed25519,
    ),
  );
  _loading = null;
  return _keyPair!;
}

Future<List<int>> _generate() async {
  final keyPair = await Ed25519().newKeyPair();
  final seed = await keyPair.extractPrivateKeyBytes();
  final publicKey = await keyPair.extractPublicKey();
  final pkcs8 = Uint8List(privateDerLength)
    ..setRange(0, _pkcs8Prefix.length, _pkcs8Prefix)
    ..setRange(_pkcs8Prefix.length, privateDerLength, seed);
  final spki = Uint8List(publicDerLength)
    ..setRange(0, _spkiPrefix.length, _spkiPrefix)
    ..setRange(_spkiPrefix.length, publicDerLength, publicKey.bytes);
  return <int>[...pkcs8, ...spki];
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
/// The signature is over the DECIMAL expiry string (TS parity), not the
/// token.
Future<String> sign([int expires = 10]) async {
  await _loadOrGenerate();
  final expiry = '${DateTime.now().millisecondsSinceEpoch ~/ 1000 + expires}';
  final signature = await Ed25519().sign(
    utf8.encode(expiry),
    keyPair: _keyPair!,
  );
  return 'key.${await publicKey()}.${base64.encode(signature.bytes)}.$expiry';
}
