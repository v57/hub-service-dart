/// Core hub-service types (TS service.ts parity).
///
/// Port of hub-service (TS reference). The wire contract matches the TS/Go
/// reference — hub/profile/update and hub/service/update are re-sent on every
/// (re)connect (the hub drops services on disconnect). Auth follows
/// Docs/Devices/protocol.md section 2: every (re)connect asks the hub to prove
/// its key and sends a fresh token for that answer alone (see hub_proof.dart).
library;

import 'dart:async';
import 'dart:io';

import 'package:channel_dart/client.dart';

import 'app.dart';
import 'device.dart';
import 'hub_proof.dart';
import 'network.dart';
import 'request.dart';
import 'keychain.dart' as keychain;

/// First wait for a hub that doesn't prove its key, or can't be reached.
const Duration _handshakeRetry = Duration(seconds: 1);

/// Longest such wait.
const Duration _handshakeMaxRetry = Duration(seconds: 30);

/// Profile sent to the hub as hub/profile/update on connect (only if set).
class Profile {
  Profile({this.name, this.icon});

  /// Profile name shown in the hub.
  final String? name;

  /// Profile icon: a plain string or a `{"symbol": ..., "text": ...}` map.
  final Object? icon;

  Map<String, Object?> toJson() => <String, Object?>{
        if (name != null) 'name': name,
        if (icon != null) 'icon': icon,
      };
}

/// Identifies an app in the hub apps list.
class AppHeader {
  AppHeader({this.type = 'app', required this.name, required this.path});

  final String type;
  final String name;
  final String path;

  Map<String, Object?> toJson() => <String, Object?>{
        'type': type,
        'name': name,
        'path': path,
      };
}

/// Pro-only wire-parity field; hub-lite ignores it.
///
/// `group` is mutable: it is auto-filled from the first path segment at
/// registration time when missing (TS parity).
class ServicePermissions {
  ServicePermissions({this.group, this.name, this.allows});

  String? group;
  String? name;
  bool? allows;

  Map<String, Object?> toJson() => <String, Object?>{
        if (group != null && group!.isNotEmpty) 'group': group,
        'name': name,
        if (allows != null) 'allows': allows,
      };
}

/// Settings for a registered API path (pro-only fields, wire parity).
class ApiSettings {
  ApiSettings({this.permissions, this.limit});

  final ServicePermissions? permissions;
  final int? limit;
}

/// Registers API endpoints on a hub and serves calls forwarded by it.
///
/// Usage:
///
/// ```dart
/// final service = Service(
///   name: 'Echo',
///   icon: const {'symbol': 'speaker.wave.2', 'text': 'E'},
/// )
///   ..post('echo', (body) => body)
///   ..start();
/// ```
class Service {
  /// [sign] is a custom token factory: it gets the key the hub proved and the
  /// challenge of this connect, and runs only after the proof. Without it, the
  /// keychain `auth` file signs. [hubKey] is the hub's key when known up front;
  /// otherwise the first key a hub proves is pinned. [allowPlaintext] dials
  /// plain ws:// beyond loopback, the overlay and the LAN, which would carry
  /// the key unencrypted: for private networks the SDK can't recognize, such as
  /// a container's ws://hub:1997 (also `HUB_ALLOW_PLAINTEXT=1`). [instance] is this service's name on its device, unique per
  /// device (default: `HUB_INSTANCE`, else [name], else the cwd name, else
  /// `service`). [signChallenge] signs Hub Network agent challenges with the
  /// service key (default: the keychain `auth` file). [device] is `true` (the default: certify the
  /// service with this device's key when it can be read or created), `false`
  /// (no `device` header) or a [Device].
  Service({
    Object? address,
    String? name,
    Object? icon,
    FutureOr<String> Function(String hubKey, String challenge)? sign,
    String? hubKey,
    bool allowPlaintext = false,
    String? instance,
    Object device = true,
    ChallengeSigner? signChallenge,
  }) {
    final env = Platform.environment['HUB'];
    final envAddress = (env != null && env.isNotEmpty) ? (int.tryParse(env) ?? env) : null;
    this.address = address ?? envAddress ?? 1997;
    this.sign = sign ?? keychain.sign;
    _hubKey = hubKey;
    _allowPlaintext = allowPlaintext || Platform.environment['HUB_ALLOW_PLAINTEXT'] == '1';
    _instance = instance;
    this.device = device is Device ? device : (device == true ? Device() : null);
    this.signChallenge = signChallenge ?? keychain.signChallenge;
    if (name != null || icon != null) {
      profile = Profile(name: name, icon: icon);
    }
  }

  /// Underlying channel; post/stream handlers are registered on it.
  final Channel<Object?> channel = Channel<Object?>();

  /// Hub address: a port (int) or a ws:// URL (String).
  late Object? address;

  /// Token factory for hub-server auth: called fresh on every (re)connect,
  /// with the key the hub proved and the challenge of this connect, and
  /// attached as the `auth` header. Defaults to the keychain `auth` file in the
  /// cwd (TS parity).
  late final FutureOr<String> Function(String hubKey, String challenge) sign;

  String? _hubKey;

  late final bool _allowPlaintext;

  /// Why the service isn't connected, if it knows: a refused address, or a hub
  /// that didn't prove its key or answers with another than the pinned one.
  String? lastError;

  /// Completes on [stop], ending a wait for the hub's proof.
  Completer<void>? _stopped;

  String? _instance;

  /// Signs Hub Network agent challenges with the service key.
  late final ChallengeSigner signChallenge;

  /// Hub Network shares; the agent socket is `network.agentSocket`.
  final NetworkPublisher network = NetworkPublisher();

  String? _serviceKey;

  /// The key this service connects with (the key in its auth token).
  Future<String> serviceKey() async => _serviceKey ?? await keychain.publicKey();

  /// Declares a Hub Network share before [start]: the declared set is
  /// published on connect and after every reconnect. Default policy: private.
  Service share(String name, String protocol, String host, int port, [Map<String, Object?>? policy]) {
    network.declareShare(_share(name, protocol, host, port, policy));
    return this;
  }

  /// Publishes a local TCP/UDP port through Hub Network; returns every
  /// publication (`resourceId`, `authority`, `overlayAddress`, `port`, ...).
  Future<List<Map<String, Object?>>> publishShare(
    String name,
    String protocol,
    String host,
    int port, [
    Map<String, Object?>? policy,
  ]) async =>
      network.publishShare(
        _share(name, protocol, host, port, policy),
        await serviceKey(),
        signChallenge,
        _senderOrError(),
      );

  /// Changes a share's policy or target port and republishes it.
  Future<List<Map<String, Object?>>> updateShare(
    String name, {
    Map<String, Object?>? policy,
    int? port,
  }) async {
    final current = network.declaredShares.where((Map<String, Object?> s) => s['name'] == name);
    if (current.isEmpty) {
      throw StateError("Share '$name' not found");
    }
    final updated = Map<String, Object?>.of(current.first);
    if (policy != null) {
      updated['policy'] = policy;
    }
    if (port != null) {
      updated['target'] = <String, Object?>{...updated['target']! as Map<String, Object?>, 'port': port};
    }
    return network.publishShare(updated, await serviceKey(), signChallenge, _senderOrError());
  }

  /// Removes a share from Hub Network.
  Future<List<Map<String, Object?>>> removeShare(String name) async =>
      network.removeShare(name, await serviceKey(), signChallenge, _senderOrError());

  List<Map<String, Object?>> get sharePublications => network.publications;

  Map<String, Object?>? sharePublication(String name) => network.publication(name);

  static Map<String, Object?> _share(
    String name,
    String protocol,
    String host,
    int port,
    Map<String, Object?>? policy,
  ) =>
      <String, Object?>{
        'name': name,
        'protocol': protocol,
        'target': <String, Object?>{'host': host, 'port': port},
        'policy': policy ?? <String, Object?>{'mode': 'private'},
      };

  Future<void> _republish(Sender<Object?> sender) async {
    try {
      await network.republishAll(await serviceKey(), signChallenge, sender);
    } catch (error) {
      stderr.writeln('Failed to republish network shares: $error');
    }
  }

  /// The device that certifies this service; null with device mode off.
  late final Device? device;

  /// The instance name sent in the certificate: the option, else
  /// `HUB_INSTANCE` (the launcher sets it), else the name, else the cwd name,
  /// else `service`; at most 128 UTF-8 bytes.
  String get instance {
    final cwd = Directory.current.uri.pathSegments.where((String s) => s.isNotEmpty);
    for (final value in <String?>[
      _instance,
      Platform.environment['HUB_INSTANCE'],
      profile?.name,
      cwd.isEmpty ? null : cwd.last,
    ]) {
      if (value != null && value.isNotEmpty) {
        final name = truncateUtf8(value, 128);
        return name.isEmpty ? 'service' : name;
      }
    }
    return 'service';
  }

  /// The hubs.json pin key for this hub.
  String get target => keychain.pinAddress(address!);

  /// Pinned hub keys: `hubs.json` beside the service key file.
  keychain.HubPins get pins =>
      keychain.HubPins('${File(keychain.keyPath()).parent.path}/hubs.json');

  /// The hub key this service expects: supplied, else pinned, else null until
  /// a hub proved one. The pin is read from hubs.json at each connect and kept
  /// in memory.
  String? get hubKey {
    final supplied = _hubKey;
    if (supplied != null) {
      return supplied;
    }
    if (!_pinLoaded) {
      _pinned = pins.get(target);
      _pinLoaded = true;
    }
    return _pinned;
  }

  String? _pinned;
  bool _pinLoaded = false;

  /// Clears the pinned hub key; the next connect pins what the hub proves.
  void forgetHubKey() {
    _hubKey = null;
    _pinned = null;
    pins.forget(target);
  }

  /// Profile sent on connect (only if name/icon were provided).
  Profile? profile;

  /// App headers registered via [app]; sent in the hub/service/update apps
  /// list (TS app() parity).
  final List<AppHeader> apps = <AppHeader>[];

  /// Settings per registered path (pro-only, wire parity).
  final Map<String, ApiSettings> _settings = <String, ApiSettings>{};

  /// Every registered handler path (post, stream, app) in registration
  /// order; the services list is built from it sorted by path (TS parity).
  final Set<String> _paths = <String>{};

  /// Client sender once [start] has connected; null before.
  ClientSender<Object?>? _sender;

  /// Connects to the hub. On every (re)connect sends hub/profile/update (if a
  /// profile is set) and hub/service/update with the current services+apps —
  /// the hub drops services on disconnect. Every (re)connect first asks the
  /// hub to prove its key (see [authHeaders]). A plain ws:// address beyond
  /// loopback, the overlay and the LAN isn't dialed. No-op if already started.
  Service start() {
    if (_sender != null) {
      return this;
    }
    lastError = null;
    if (!_allowPlaintext && hubTransportOf(address!) == HubTransport.refused) {
      lastError = "$target would carry this service's key unencrypted. Use wss://, "
          'or set allowPlaintext (HUB_ALLOW_PLAINTEXT=1) on a private network';
      stderr.writeln('hub-service: $lastError');
      return this;
    }
    _stopped = Completer<void>();
    _sender = channel.connect(
      address!,
      options: ClientOptions<Object?>(
        headers: authHeaders,
        onConnect: _sendUpdates,
      ),
    );
    return this;
  }

  /// Disconnects from the hub and stops reconnecting, ending a wait for its
  /// proof.
  void stop() {
    final stopped = _stopped;
    if (stopped != null && !stopped.isCompleted) {
      stopped.complete();
    }
    _stopped = null;
    _sender?.stop();
    _sender = null;
  }

  /// Runs before every connection attempt (protocol.md section 2). It comes
  /// back with a token over a fresh challenge from a hub that proved its key;
  /// until one has, it holds the attempt back, so nothing goes out and requests
  /// keep waiting. After a [stop] it throws, which tells the client not to
  /// connect.
  Future<Map<String, String>> authHeaders() async {
    final stopped = _stopped;
    var delay = _handshakeRetry;
    String? reported;
    while (true) {
      Map<String, String>? headers;
      try {
        headers = await _handshake(stopped?.future);
      } catch (error) {
        final message = error is StateError ? error.message : '$error';
        lastError = message;
        if (message != reported) {
          reported = message;
          stderr.writeln('hub-service: $message');
        }
      }
      if (stopped != null && stopped.isCompleted) {
        throw StateError('Service stopped');
      }
      if (headers != null) {
        lastError = null;
        return headers;
      }
      await _waitForRetry(delay, stopped);
      if (stopped != null && stopped.isCompleted) {
        throw StateError('Service stopped');
      }
      delay = delay * 2 < _handshakeMaxRetry ? delay * 2 : _handshakeMaxRetry;
    }
  }

  /// Waits for [delay], or until [stopped].
  Future<void> _waitForRetry(Duration delay, Completer<void>? stopped) {
    final done = Completer<void>();
    final timer = Timer(delay, done.complete);
    unawaited(stopped?.future.then((_) {
      timer.cancel();
      if (!done.isCompleted) {
        done.complete();
      }
    }));
    return done.future;
  }

  /// Asks the hub for its proof and signs for that answer alone.
  Future<Map<String, String>> _handshake(Future<void>? cancelled) async {
    final HubProof proof;
    try {
      proof = await askHub(address!, cancelled: cancelled);
    } catch (error) {
      final message = error is StateError ? error.message : '$error';
      throw StateError('$target: $message, sending it nothing');
    }
    _pinLoaded = false; // pick up a pin another process wrote
    final pinned = hubKey;
    if (pinned == null) {
      pins.set(target, proof.key);
      _pinned = proof.key;
      _pinLoaded = true;
    } else if (pinned != proof.key) {
      throw StateError(
        '$target answers with key ${proof.key}, not the pinned $pinned, sending it nothing. '
        'forgetHubKey() if its key really changed',
      );
    }
    final token = await sign(proof.key, proof.challenge);
    final headers = <String, String>{'auth': token, 'v': keychain.authVersion};
    _serviceKey = token.split('.')[1];
    final device = this.device;
    if (device != null) {
      try {
        // The certificate names the key in the token, whoever signed it.
        headers['device'] = await device.certificate(token.split('.')[1], instance);
      } catch (_) {
        // No readable or creatable device key: a plain key connection.
      }
    }
    return headers;
  }

  /// Calls an API through the hub (client side). Throws a [StateError] if
  /// [start] has not been called.
  Future<Object?> send(String path, {Object? body, Object? context}) {
    return _senderOrError().send<Object?>(path, body: body, context: context);
  }

  /// Opens a stream call through the hub (client side). Throws a [StateError]
  /// if [start] has not been called.
  Stream<Object?> values(String path, {Object? body, Object? context}) {
    return _senderOrError().values<Object?>(
      path,
      body: body,
      context: context,
    );
  }

  /// Registers a request/response API endpoint.
  ///
  /// [handler] is `(Object? body)` or `(Object? body, Request request)`
  /// (`request.caller`: who is calling); it may be sync or async and returns
  /// the response body.
  Service post(
    String path,
    Function handler, {
    ApiSettings? settings,
  }) {
    final call = _adapt<FutureOr<Object?>>(handler, 'post');
    _addPath(path, settings);
    channel.post(path, call);
    return this;
  }

  /// Registers a streaming API endpoint.
  ///
  /// [handler] is `(Object? body)` or `(Object? body, Request request)` and
  /// returns the stream of values to stream back (an async generator works
  /// too).
  Service stream(
    String path,
    Function handler, {
    ApiSettings? settings,
  }) {
    final call = _adapt<FutureOr<Stream<Object?>>>(handler, 'stream');
    _addPath(path, settings);
    channel.stream(path, call);
    return this;
  }

  /// Adapts a `(body)` or `(body, request)` handler to a channel one.
  R Function(ChannelBody<Object?>) _adapt<R>(Function handler, String kind) {
    if (handler is R Function(Object?, Request)) {
      return (ChannelBody<Object?> body) =>
          handler(body.body, Request.fromContext(body.context, body.path, hubKey));
    }
    if (handler is R Function(Object?)) {
      return (ChannelBody<Object?> body) => handler(body.body);
    }
    throw ArgumentError.value(
      handler,
      'handler',
      'a $kind handler takes (Object? body) or (Object? body, Request request)',
    );
  }

  /// Registers an app: its header goes to the hub apps list and its path
  /// serves the AppInterface as a stream (TS parity: the path is also
  /// callable).
  Service app(App app) {
    apps.add(app.header);
    _addPath(app.header.path, null);
    channel.stream(
      app.header.path,
      (_) => _appInterfaceStream(app),
    );
    return this;
  }

  static Stream<Object?> _appInterfaceStream(App app) {
    // Yield the interface once, then keep the stream open (TS parity: the
    // app stays live until the caller cancels or the connection drops).
    final controller = StreamController<Object?>();
    controller.add(app.interface());
    return controller.stream;
  }

  /// Builds the current hub/service/update payload (services + apps).
  Map<String, Object?> update() {
    final paths = _paths.toList()..sort();
    final services = <Object?>[
      for (final path in paths) _serviceHeader(path, _settings[path]),
    ];
    final appList = <Object?>[
      for (final header in apps) header.toJson(),
    ];
    return <String, Object?>{'services': services, 'apps': appList};
  }

  void _addPath(String path, ApiSettings? settings) {
    if (settings != null) {
      final permissions = settings.permissions;
      if (permissions != null &&
          (permissions.group == null || permissions.group!.isEmpty)) {
        permissions.group = path.split('/').first;
      }
      _settings[path] = settings;
    }
    _paths.add(path);
  }

  static Map<String, Object?> _serviceHeader(
    String path,
    ApiSettings? settings,
  ) {
    final entry = <String, Object?>{'path': path};
    if (settings != null) {
      final permissions = settings.permissions;
      if (permissions != null) {
        entry['permissions'] = permissions.toJson();
      }
      if (settings.limit != null) {
        entry['limit'] = settings.limit;
      }
    }
    return entry;
  }

  ClientSender<Object?> _senderOrError() {
    final sender = _sender;
    if (sender == null) {
      throw StateError(lastError ?? 'Service not started');
    }
    return sender;
  }

  /// Re-announces on every (re)connect.
  ///
  /// Fire-and-forget: the channel-dart WebSocketClient awaits the onOpen
  /// callback before attaching its socket.listen message loop, so awaiting a
  /// send (which waits for the hub's response) inside onConnect would
  /// deadlock — the response could never be read and the service update would
  /// never be sent. The sends also wait for the next event-loop turn: right
  /// after onOpen the client re-sends every pending request, and requests
  /// made inside onConnect would go out twice.
  void _sendUpdates(Sender<Object?> sender) {
    Timer.run(() => _announce(sender));
  }

  void _announce(Sender<Object?> sender) {
    try {
      final profile = this.profile;
      if (profile != null) {
        unawaited(_quietSend(sender, 'hub/profile/update', profile.toJson()));
      }
    } catch (_) {}
    try {
      unawaited(_quietSend(sender, 'hub/service/update', update()));
    } catch (_) {}
    if (network.hasShares) {
      unawaited(_republish(sender));
    }
  }

  /// Sends a request, swallowing errors (the connection may drop mid-send).
  Future<void> _quietSend(
    Sender<Object?> sender,
    String path,
    Object? body,
  ) async {
    try {
      await sender.send<Object?>(path, body: body);
    } catch (_) {}
  }
}
