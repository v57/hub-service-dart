/// Core hub-service types (TS service.ts parity).
///
/// Port of hub-service (TS reference). Connects with hub-pro auth (a fresh
/// ed25519 keychain token as the `auth` header) on every (re)connect;
/// hub-lite ignores the auth header entirely. The wire contract matches the
/// TS/Go reference — hub/profile/update and hub/service/update are re-sent on
/// every (re)connect (the hub drops services on disconnect). Auth follows
/// Docs/Devices/protocol.md: v0 tokens until the hub key is pinned from
/// hub/info, hub-bound v1 tokens after that.
library;

import 'dart:async';
import 'dart:io';

import 'package:channel_dart/client.dart';

import 'app.dart';
import 'device.dart';
import 'request.dart';
import 'keychain.dart' as keychain;

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
  /// [sign] is a v0 token factory (it can't sign for a hub key); [hubSign]
  /// gets the pinned hub key, or null, and must sign v1 when it is set.
  /// Without either, the keychain `auth` file signs. [hubKey] is the hub's
  /// key when known up front; otherwise it is learned from hub/info and
  /// pinned. [instance] is this service's name on its device, unique per
  /// device (default: `HUB_INSTANCE`, else [name], else the cwd name, else
  /// `service`). [device] is `true` (the default: certify the
  /// service with this device's key when it can be read or created), `false`
  /// (no `device` header) or a [Device].
  Service({
    Object? address,
    String? name,
    Object? icon,
    FutureOr<String> Function()? sign,
    FutureOr<String> Function(String? hubKey)? hubSign,
    String? hubKey,
    String? instance,
    Object device = true,
  }) {
    final env = Platform.environment['HUB'];
    final envAddress = (env != null && env.isNotEmpty) ? (int.tryParse(env) ?? env) : null;
    this.address = address ?? envAddress ?? 1997;
    this.sign = sign ?? keychain.sign;
    _hubSign = hubSign ??
        (sign == null ? (String? hubKey) => keychain.sign(60, hubKey) : null);
    _hubKey = hubKey;
    _instance = instance;
    this.device = device is Device ? device : (device == true ? Device() : null);
    if (name != null || icon != null) {
      profile = Profile(name: name, icon: icon);
    }
  }

  /// Underlying channel; post/stream handlers are registered on it.
  final Channel<Object?> channel = Channel<Object?>();

  /// Hub address: a port (int) or a ws:// URL (String).
  late Object? address;

  /// Token factory for hub-pro auth: called fresh on every (re)connect and
  /// attached as the `auth` header (with `v: '0'`) when no hub-aware signer
  /// is set. Defaults to the keychain `auth` file in the cwd (TS parity).
  /// hub-lite ignores the header.
  late final FutureOr<String> Function() sign;

  /// Hub-aware token factory: gets the hub key and signs v1 when it is set.
  FutureOr<String> Function(String? hubKey)? _hubSign;

  String? _hubKey;

  String? _instance;

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

  /// The hub key this service signs for: supplied, else pinned. The pin is
  /// read from hubs.json at each connect and kept in memory.
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

  /// Clears the pinned hub key; the next connect learns it again (v0).
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
  /// the hub drops services on disconnect. Attaches a fresh keychain auth
  /// token as the `auth` header on every (re)connect (hub-pro; hub-lite
  /// ignores it). No-op if already started.
  Service start() {
    if (_sender != null) {
      return this;
    }
    _sender = channel.connect(
      address!,
      options: ClientOptions<Object?>(
        headers: authHeaders,
        onConnect: _sendUpdates,
      ),
    );
    return this;
  }

  /// Disconnects from the hub and stops reconnecting.
  void stop() {
    _sender?.stop();
    _sender = null;
  }

  /// Auth headers for the next connect: a fresh token and `v`. A refused v1
  /// connect (the hub key changed or a different server answers) keeps
  /// retrying with v1; there is no silent v0 fallback.
  Future<Map<String, String>> authHeaders() async {
    _pinLoaded = false; // pick up a pin another process wrote
    final hubSign = _hubSign;
    final hubKey = hubSign != null ? this.hubKey : null;
    final token = hubSign != null ? await hubSign(hubKey) : await sign();
    final headers = <String, String>{'auth': token, 'v': hubKey != null ? '1' : '0'};
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
      throw StateError('Service not started');
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
    if (_hubSign != null && hubKey == null) {
      unawaited(_learnHubKey(sender));
    }
  }

  /// Pins the hub key from hub/info, then reconnects with v1 at once. The
  /// client's socket is private, so the reconnect is a fresh connection; a
  /// call in flight at that moment fails with `disconnected`. hub-lite
  /// doesn't answer hub/info, so the service stays on v0 there.
  Future<void> _learnHubKey(Sender<Object?> sender) async {
    Object? info;
    try {
      info = await sender
          .send<Object?>('hub/info')
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      return;
    }
    final key = info is Map ? info['key'] : null;
    if (key is! String || key.isEmpty || hubKey != null) {
      return;
    }
    pins.set(target, key);
    _pinned = key;
    _pinLoaded = true;
    final old = _sender;
    if (old == null) {
      return;
    }
    _sender = null;
    start();
    old.stop();
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
