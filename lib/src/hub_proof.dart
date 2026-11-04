/// Auth v2's client side (Docs/Devices/protocol.md section 2): before every
/// connect the service asks hub/info on an anonymous connection with a fresh
/// nonce, and sends its token only if the hub proved the key it claims, over
/// that nonce.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:channel_dart/client.dart';
import 'package:cryptography/cryptography.dart';

/// How a connection to an address travels. [refused] is plain ws:// beyond
/// loopback, the overlay and the LAN: it isn't dialed unless `allowPlaintext`
/// says so.
enum HubTransport { encrypted, loopback, overlay, localNetwork, refused }

final RegExp _address = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*)://(?:[^/?#@]*@)?(\[[^\]]*\]|[^/?#:]*)');

/// Classifies an address before anything is dialed.
HubTransport hubTransportOf(Object address) {
  final text = '$address';
  if (address is int || RegExp(r'^\d+$').hasMatch(text)) {
    return HubTransport.loopback;
  }
  final match = _address.firstMatch(text);
  if (match == null) {
    return HubTransport.refused;
  }
  final scheme = match.group(1)!.toLowerCase();
  var host = match.group(2)!.toLowerCase();
  if (host.endsWith('.')) {
    host = host.substring(0, host.length - 1);
  }
  if (scheme == 'wss' || scheme == 'https' || scheme == 'quic') {
    return HubTransport.encrypted;
  }
  if (scheme != 'ws' && scheme != 'http') {
    return HubTransport.refused;
  }
  if (host.startsWith('[')) {
    final v6 = host.substring(1, host.length - 1);
    if (v6 == '::1') {
      return HubTransport.loopback;
    }
    return RegExp(r'^(f[cd]|fe[89ab])').hasMatch(v6) ? HubTransport.localNetwork : HubTransport.refused;
  }
  final v4 = _ipv4(host);
  if (v4 != null) {
    final a = v4[0];
    final b = v4[1];
    if (a == 127) {
      return HubTransport.loopback;
    }
    if (a == 100 && b >= 64 && b <= 127) {
      return HubTransport.overlay;
    }
    if (a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) || (a == 169 && b == 254)) {
      return HubTransport.localNetwork;
    }
    return HubTransport.refused;
  }
  if (host == 'localhost' || host.endsWith('.localhost')) {
    return HubTransport.loopback;
  }
  if (host.endsWith('.hub.invalid')) {
    return HubTransport.overlay;
  }
  return host.endsWith('.local') ? HubTransport.localNetwork : HubTransport.refused;
}

List<int>? _ipv4(String host) {
  final parts = host.split('.');
  if (parts.length != 4 || !parts.every((String part) => RegExp(r'^\d{1,3}$').hasMatch(part))) {
    return null;
  }
  final bytes = parts.map(int.parse).toList();
  return bytes.every((int byte) => byte <= 255) ? bytes : null;
}

final Random _random = Random.secure();

/// The nonce for one hub/info: 32 fresh random bytes in base64url.
String makeClientNonce() {
  final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// The string a hub/info proof signs.
String hubInfoSignedData(String hubKey, String nonce) => 'hubinfo1:$hubKey:$nonce';

const List<int> _spkiPrefix = <int>[
  0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, //
  0x70, 0x03, 0x21, 0x00,
];

/// Whether a hub/info answer proves its key over [nonce]. A relayed answer
/// passes too, so it never decides which credentials a hub gets.
Future<bool> verifyHubProof(Object? info, String nonce) async {
  if (info is! Map) {
    return false;
  }
  final key = info['key'];
  final proof = info['proof'];
  if (key is! String || proof is! String || info['challenge'] is! String) {
    return false;
  }
  try {
    final spki = base64.decode(key);
    final signature = base64.decode(proof);
    if (spki.length != 44 || signature.length != 64) {
      return false;
    }
    for (var i = 0; i < _spkiPrefix.length; i++) {
      if (spki[i] != _spkiPrefix[i]) {
        return false;
      }
    }
    return await Ed25519().verify(
      utf8.encode(hubInfoSignedData(key, nonce)),
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(spki.sublist(12), type: KeyPairType.ed25519),
      ),
    );
  } on FormatException {
    return false;
  }
}

/// A hub/info answer whose proof checked out.
class HubProof {
  const HubProof(this.key, this.challenge);

  final String key;
  final String challenge;
}

/// Asks the hub at [address] for its key and a challenge, on a short anonymous
/// connection, and returns the answer only with a valid proof. [cancelled]
/// ends the wait early.
Future<HubProof> askHub(
  Object address, {
  Duration timeout = const Duration(seconds: 5),
  Future<void>? cancelled,
}) async {
  final nonce = makeClientNonce();
  final probe = Channel<Object?>().connect(address);
  unawaited(cancelled?.then((_) => probe.stop()));
  Object? info;
  try {
    info = await probe.send<Object?>('hub/info', body: <String, Object?>{'nonce': nonce}).timeout(timeout);
  } on TimeoutException {
    throw StateError('hub/info timed out');
  } finally {
    probe.stop();
  }
  if (!await verifyHubProof(info, nonce)) {
    throw StateError("hub didn't prove its key");
  }
  final answer = info! as Map;
  return HubProof(answer['key'] as String, answer['challenge'] as String);
}
