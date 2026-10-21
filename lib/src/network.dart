/// Hub Network share publication (TS network.ts parity).
///
/// A share makes a local TCP/UDP port reachable through Hub Network. For each
/// declared share the service asks the local hub-net agent (HTTP over its Unix
/// socket) for an attestation: `/challenge` returns a nonce, the service signs
/// it with its key, and `/attest` returns the agent-signed attestation. The
/// complete declared set then goes to the hub in one `network/shares/replace`
/// call, which answers with one publication per share in request order. The
/// set is republished after every reconnect.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:channel_dart/client.dart';

/// Hub Network wire version.
const int networkWireVersion = 1;

/// The hub-net agent's socket on macOS.
const String defaultAgentSocket = '/var/run/hub-net/agent.sock';

const int _maxShareNameLength = 255;
final RegExp _control = RegExp(r'[\x00-\x1f\x7f]');

/// Signs an agent challenge with the service key.
typedef ChallengeSigner = FutureOr<String> Function(String challenge);

/// Supplies an attestation instead of asking the local agent (tests).
typedef AttestationProvider = Future<Map<String, Object?>> Function(
  Map<String, Object?> share,
  String serviceKey,
  ChallengeSigner sign,
);

/// The local hub-net agent was unavailable, refused or answered badly.
/// [code]: agent-unavailable, agent-timeout, agent-rejected,
/// invalid-agent-response, attestation-mismatch, attestation-expired.
class LocalAgentError implements Exception {
  LocalAgentError(this.code, this.message, [this.status]);

  final String code;
  final String message;
  final int? status;

  @override
  String toString() => 'LocalAgentError($code): $message';
}

String _string(Object? value, String field, [int? maxLength]) {
  if (value is! String ||
      value.trim().isEmpty ||
      _control.hasMatch(value) ||
      (maxLength != null && value.length > maxLength)) {
    throw ArgumentError('Invalid Hub Network $field');
  }
  return value;
}

void _port(Object? value, [String field = 'target port']) {
  if (value is! int || value < 1 || value > 65535) {
    throw ArgumentError('Invalid Hub Network $field');
  }
}

/// Throws an [ArgumentError] unless [policy] is a valid share policy.
void validatePolicy(Object? policy) {
  if (policy is! Map || policy['mode'] is! String) {
    throw ArgumentError('Invalid Hub Network policy');
  }
  switch (policy['mode']) {
    case 'hub':
    case 'private':
    case 'disabled':
      return;
    case 'group':
      _string(policy['group'], 'policy group');
      return;
    case 'keys':
      final keys = policy['keys'];
      if (keys is! List || keys.isEmpty) {
        throw ArgumentError('Invalid Hub Network policy keys');
      }
      for (final key in keys) {
        try {
          _string(key, 'policy key');
        } on ArgumentError {
          throw ArgumentError('Invalid Hub Network policy keys');
        }
      }
      return;
    default:
      throw ArgumentError('Invalid Hub Network policy mode');
  }
}

/// Throws an [ArgumentError] unless [share] is
/// `{name, protocol: tcp|udp, target: {host, port}, policy?}`.
void validateShare(Object? share) {
  if (share is! Map) {
    throw ArgumentError('Invalid Hub Network share');
  }
  _string(share['name'], 'share name', _maxShareNameLength);
  if (share['protocol'] != 'tcp' && share['protocol'] != 'udp') {
    throw ArgumentError('Invalid Hub Network protocol');
  }
  final target = share['target'];
  if (target is! Map) {
    throw ArgumentError('Invalid Hub Network target');
  }
  _string(target['host'], 'target host');
  _port(target['port']);
  if (share['policy'] != null) {
    validatePolicy(share['policy']);
  }
}

Map<String, Object?> _validatePublication(Object? value, Map<String, Object?> share, int index) {
  if (value is! Map) {
    throw StateError('Invalid Hub publication at share index $index');
  }
  if (value['version'] != networkWireVersion) {
    throw StateError('Invalid Hub publication version at share index $index');
  }
  final resource = value['resourceId'];
  if (resource is! String || !resource.startsWith('hnr1_') || resource == 'hnr1_') {
    throw StateError('Invalid Hub publication resourceId at share index $index');
  }
  _string(value['authority'], 'publication authority at share index $index');
  _string(value['providerId'], 'publication providerId at share index $index');
  _string(value['overlayAddress'], 'publication overlayAddress at share index $index');
  if (value['protocol'] != share['protocol']) {
    throw StateError('Hub publication protocol mismatch at share index $index');
  }
  _port(value['port'], 'publication port at share index $index');
  return Map<String, Object?>.from(value);
}

/// Declared shares, their agent attestations and hub publications.
class NetworkPublisher {
  NetworkPublisher({
    this.agentSocket = defaultAgentSocket,
    this.agentTimeout = const Duration(seconds: 5),
    this.attestationProvider,
  });

  String agentSocket;
  Duration agentTimeout;
  AttestationProvider? attestationProvider;

  final Map<String, Map<String, Object?>> _shares = <String, Map<String, Object?>>{};
  Map<String, Map<String, Object?>> _publications = <String, Map<String, Object?>>{};

  List<Map<String, Object?>> get declaredShares =>
      (_shares.keys.toList()..sort()).map((String name) => _shares[name]!).toList();

  bool get hasShares => _shares.isNotEmpty;

  List<Map<String, Object?>> get publications => _publications.values.toList();

  Map<String, Object?>? publication(String name) => _publications[name];

  /// Declares a share; the next connect publishes the whole set.
  void declareShare(Map<String, Object?> share) {
    validateShare(share);
    _shares[share['name']! as String] = share;
  }

  /// Proves the service key to the local agent; returns its attestation.
  Future<Map<String, Object?>> requestAttestation(
    Map<String, Object?> share,
    String serviceKey,
    ChallengeSigner sign,
  ) async {
    validateShare(share);
    final body = <String, Object?>{
      'serviceKey': serviceKey,
      'shareName': share['name'],
      'protocol': share['protocol'],
      'target': share['target'],
    };
    final challenge = await _agent('/challenge', body, 'challenge');
    final nonce = challenge is Map ? challenge['nonce'] : null;
    if (nonce is! String || nonce.isEmpty) {
      throw LocalAgentError('invalid-agent-response', 'Hub Network agent returned an invalid challenge');
    }
    final attestation = await _agent(
      '/attest',
      <String, Object?>{...body, 'signature': await sign(nonce)},
      'attestation',
    );
    _validateAttestation(attestation, share, serviceKey);
    return Map<String, Object?>.from(attestation as Map);
  }

  Future<List<Map<String, Object?>>> publishShare(
    Map<String, Object?> share,
    String serviceKey,
    ChallengeSigner sign,
    Sender<Object?> sender,
  ) async {
    validateShare(share);
    final name = share['name']! as String;
    final previous = _shares[name];
    _shares[name] = share;
    try {
      return await _synchronize(serviceKey, sign, sender);
    } catch (_) {
      if (previous != null) {
        _shares[name] = previous;
      } else {
        _shares.remove(name);
      }
      rethrow;
    }
  }

  Future<List<Map<String, Object?>>> republishAll(
    String serviceKey,
    ChallengeSigner sign,
    Sender<Object?> sender,
  ) =>
      _synchronize(serviceKey, sign, sender);

  Future<List<Map<String, Object?>>> removeShare(
    String name,
    String serviceKey,
    ChallengeSigner sign,
    Sender<Object?> sender,
  ) async {
    _string(name, 'share name', _maxShareNameLength);
    final removed = _shares.remove(name);
    if (removed == null) {
      throw StateError("Share '$name' not found");
    }
    try {
      return await _synchronize(serviceKey, sign, sender);
    } catch (_) {
      _shares[name] = removed;
      rethrow;
    }
  }

  Future<List<Map<String, Object?>>> _synchronize(
    String serviceKey,
    ChallengeSigner sign,
    Sender<Object?> sender,
  ) async {
    final shares = declaredShares;
    final wire = <Map<String, Object?>>[];
    for (final share in shares) {
      final provider = attestationProvider;
      final attestation = provider != null
          ? await provider(share, serviceKey, sign)
          : await requestAttestation(share, serviceKey, sign);
      _validateAttestation(attestation, share, serviceKey);
      wire.add(<String, Object?>{...share, 'version': networkWireVersion, 'attestation': attestation});
    }
    final response = await sender.send<Object?>(
      'network/shares/replace',
      body: <String, Object?>{'shares': wire},
    );
    if (response is! Map || response['shares'] is! List) {
      throw StateError('Hub returned an invalid shares/replace response');
    }
    final publications = response['shares'] as List;
    if (publications.length != shares.length) {
      throw StateError('Hub returned ${publications.length} publications for ${shares.length} shares');
    }
    // v1 publications carry no share name: the hub keeps request order.
    final correlated = <String, Map<String, Object?>>{};
    final resources = <String>{};
    for (var index = 0; index < shares.length; index++) {
      final validated = _validatePublication(publications[index], shares[index], index);
      if (!resources.add(validated['resourceId']! as String)) {
        throw StateError('Hub returned duplicate resourceId at share index $index');
      }
      correlated[shares[index]['name']! as String] = validated;
    }
    _publications = correlated;
    return correlated.values.toList();
  }

  static void _validateAttestation(Object? attestation, Map<String, Object?> share, String serviceKey) {
    final target = attestation is Map ? attestation['target'] : null;
    final shareTarget = share['target']! as Map;
    if (attestation is! Map ||
        attestation['version'] != networkWireVersion ||
        attestation['serviceKey'] != serviceKey ||
        attestation['shareName'] != share['name'] ||
        attestation['protocol'] != share['protocol'] ||
        target is! Map ||
        target['host'] != shareTarget['host'] ||
        target['port'] != shareTarget['port']) {
      throw LocalAgentError('attestation-mismatch', 'Local-agent attestation does not match the share');
    }
    final issued = DateTime.tryParse('${attestation['issuedAt']}');
    final expires = DateTime.tryParse('${attestation['expiresAt']}');
    final now = DateTime.now();
    if (issued == null ||
        expires == null ||
        !expires.isAfter(issued) ||
        issued.isAfter(now.add(const Duration(seconds: 30))) ||
        !expires.isAfter(now)) {
      throw LocalAgentError('attestation-expired', 'Local-agent attestation is expired');
    }
  }

  /// POSTs JSON to the agent over its Unix socket and decodes the reply.
  Future<Object?> _agent(String path, Map<String, Object?> body, String operation) async {
    final (int status, String payload) response;
    try {
      response = await _post(path, body).timeout(agentTimeout);
    } on TimeoutException {
      throw LocalAgentError(
        'agent-timeout',
        'Hub Network agent timed out after ${agentTimeout.inMilliseconds} ms',
      );
    } on SocketException {
      throw LocalAgentError('agent-unavailable', 'Hub Network agent is unavailable at $agentSocket');
    }
    final (status, payload) = response;
    if (status < 200 || status > 299) {
      final detail = payload.trim();
      throw LocalAgentError(
        'agent-rejected',
        'Hub Network agent rejected $operation ($status)${detail.isEmpty ? '' : ': $detail'}',
        status,
      );
    }
    try {
      return jsonDecode(payload);
    } on FormatException {
      throw LocalAgentError('invalid-agent-response', 'Hub Network agent returned invalid JSON', status);
    }
  }

  Future<(int, String)> _post(String path, Map<String, Object?> body) async {
    final socket = await Socket.connect(InternetAddress(agentSocket, type: InternetAddressType.unix), 0);
    try {
      final data = utf8.encode(jsonEncode(body));
      socket.add(utf8.encode(
        'POST $path HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n'
        'Content-Length: ${data.length}\r\nConnection: close\r\n\r\n',
      ));
      socket.add(data);
      await socket.flush();
      final raw = <int>[];
      await socket.forEach(raw.addAll);
      return _parseResponse(raw);
    } finally {
      socket.destroy();
    }
  }

  static (int, String) _parseResponse(List<int> raw) {
    final text = utf8.decode(raw, allowMalformed: true);
    final split = text.indexOf('\r\n\r\n');
    final head = split < 0 ? text : text.substring(0, split);
    var body = split < 0 ? '' : text.substring(split + 4);
    final lines = head.split('\r\n');
    final match = RegExp(r'^HTTP/1\.[01] (\d{3})').firstMatch(lines.first);
    if (match == null) {
      throw LocalAgentError('invalid-agent-response', 'Hub Network agent returned an invalid HTTP response');
    }
    final headers = <String, String>{
      for (final line in lines.skip(1))
        if (line.contains(':'))
          line.substring(0, line.indexOf(':')).trim().toLowerCase(): line.substring(line.indexOf(':') + 1).trim(),
    };
    if (headers['transfer-encoding']?.toLowerCase() == 'chunked') {
      final decoded = StringBuffer();
      while (body.isNotEmpty) {
        final end = body.indexOf('\r\n');
        final size = int.parse(body.substring(0, end).split(';').first, radix: 16);
        if (size == 0) break;
        decoded.write(body.substring(end + 2, end + 2 + size));
        body = body.substring(end + 4 + size);
      }
      body = decoded.toString();
    }
    return (int.parse(match.group(1)!), body);
  }
}
