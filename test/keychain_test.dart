import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:hub_service/hub_service.dart';
import 'package:test/test.dart';

/// TS reference test key (hub-pro-support-contract.md): base64 of the 48-byte
/// PKCS8 DER private key followed by the 44-byte SPKI DER public key.
const String tsAuthFile =
    'MC4CAQAwBQYDK2VwBCIEINguo0cc0FACJ0oRV3V/+ZqIyj04ON5wdMJGH4a/do8C'
    'MCowBQYDK2VwAyEAHZSDpmbLRjLrOyNMugsStFqK5EYcNluUekE4di+FalQ=';

/// The 44-byte SPKI public key slice of the TS key.
const String tsPublicKey =
    'MCowBQYDK2VwAyEAHZSDpmbLRjLrOyNMugsStFqK5EYcNluUekE4di+FalQ=';

/// Verifies a token's signature against the public key embedded in it.
Future<bool> verifyTokenSignature(String token) async {
  final parts = token.split('.');
  final spki = base64.decode(parts[1]);
  final signature = base64.decode(parts[2]);
  final expiry = parts[3];
  return Ed25519().verify(
    utf8.encode(expiry),
    signature: Signature(
      signature,
      publicKey: SimplePublicKey(
        spki.sublist(12),
        type: KeyPairType.ed25519,
      ),
    ),
  );
}

void main() {
  late Directory tempDir;
  late String keyPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('hub_keychain_');
    keyPath = '${tempDir.path}/auth';
    setKeyPath(keyPath);
  });

  tearDown(() {
    setKeyPath(null);
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('sign produces key.<pub>.<sig>.<expiry> and the signature verifies',
      () async {
    final token = await sign();
    final parts = token.split('.');
    expect(parts.length, 4);
    expect(parts[0], 'key');
    expect(parts[1], await publicKey());
    expect(parts[2], isNotEmpty);
    expect(base64.decode(parts[2]).length, 64);
    // Expiry is a DECIMAL epoch-seconds string of now + 10 (TS parity).
    expect(parts[3], matches(RegExp(r'^\d+$')));
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    expect(int.parse(parts[3]), closeTo(now + 10, 5));
    expect(await verifyTokenSignature(token), isTrue);
  });

  test('auth file is created as base64 of PKCS8+SPKI (92 bytes)', () async {
    await sign();
    final file = File(keyPath);
    expect(await file.exists(), isTrue);
    final data = base64.decode((await file.readAsString()).trim());
    expect(data.length, 92);
    // PKCS8 (48) + SPKI (44) with their standard ed25519 headers.
    expect(
      data.sublist(0, 16),
      <int>[
        0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, //
        0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
      ],
    );
    expect(
      data.sublist(48, 60),
      <int>[
        0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, //
        0x70, 0x03, 0x21, 0x00,
      ],
    );
    expect(base64.encode(data.sublist(48, 92)), await publicKey());
  });

  test('auth file round-trips through a setKeyPath reload', () async {
    final firstToken = await sign();
    setKeyPath(keyPath); // reset module cache; reload from disk
    final token = await sign();
    expect(token.split('.')[1], firstToken.split('.')[1]);
    expect(await publicKey(), firstToken.split('.')[1]);
    expect(await verifyTokenSignature(token), isTrue);
  });

  test('TS-generated auth file loads and reproduces its public key', () async {
    await File(keyPath).writeAsString(tsAuthFile);
    setKeyPath(keyPath);
    expect(await publicKey(), tsPublicKey);
    final token = await sign();
    expect(token.split('.')[1], tsPublicKey);
    expect(await verifyTokenSignature(token), isTrue);
  });

  test('sign honors the expires argument', () async {
    final token = await sign(3600);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    expect(int.parse(token.split('.')[3]), closeTo(now + 3600, 5));
    expect(await verifyTokenSignature(token), isTrue);
  });

  test('invalid auth file length throws StateError', () async {
    await File(keyPath).writeAsString(base64.encode(List<int>.filled(10, 1)));
    setKeyPath(keyPath);
    expect(sign(), throwsStateError);
  });

  test('Service defaults sign to the keychain token factory', () {
    final service = Service();
    expect(service.sign, sign);
  });
}
