/// Core hub-service types (TS service.ts parity).
///
/// Port of hub-service (TS reference). Connects with hub-pro auth (a fresh
/// ed25519 keychain token as the `auth` header + `v: '0'`) on every
/// (re)connect; hub-lite ignores the auth header entirely. The wire contract
/// matches the TS/Go reference — hub/profile/update and hub/service/update
/// are re-sent on every (re)connect (the hub drops services on disconnect).
library;

import 'dart:async';
import 'dart:io';

import 'package:channel_dart/client.dart';

import 'app.dart';
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
  Service({
    Object? address,
    String? name,
    Object? icon,
    FutureOr<String> Function()? sign,
  }) {
    final env = Platform.environment['HUB'];
    final envAddress = (env != null && env.isNotEmpty) ? (int.tryParse(env) ?? env) : null;
    this.address = address ?? envAddress ?? 1997;
    this.sign = sign ?? keychain.sign;
    if (name != null || icon != null) {
      profile = Profile(name: name, icon: icon);
    }
  }

  /// Underlying channel; post/stream handlers are registered on it.
  final Channel<Object?> channel = Channel<Object?>();

  /// Hub address: a port (int) or a ws:// URL (String).
  late Object? address;

  /// Token factory for hub-pro auth: called fresh on every (re)connect and
  /// attached as the `auth` header (with `v: '0'`). Defaults to the keychain
  /// `auth` file in the cwd (TS parity). hub-lite ignores the header.
  late final FutureOr<String> Function() sign;

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
        headers: _authHeaders,
        onConnect: _sendUpdates,
      ),
    );
    return this;
  }

  /// Auth headers for hub-pro: a fresh signed token + protocol version.
  Future<Map<String, String>> _authHeaders() async {
    final token = await sign();
    return <String, String>{'auth': token, 'v': '0'};
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
  /// [handler] receives the request body (may be sync or async) and returns
  /// the response body.
  Service post(
    String path,
    FutureOr<Object?> Function(Object? body) handler, {
    ApiSettings? settings,
  }) {
    _addPath(path, settings);
    channel.post(path, (ChannelBody<Object?> body) => handler(body.body));
    return this;
  }

  /// Registers a streaming API endpoint.
  ///
  /// [handler] receives the request body and returns the stream of values
  /// to stream back (an async generator works too).
  Service stream(
    String path,
    FutureOr<Stream<Object?>> Function(Object? body) handler, {
    ApiSettings? settings,
  }) {
    _addPath(path, settings);
    channel.stream(
      path,
      (ChannelBody<Object?> body) => handler(body.body),
    );
    return this;
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
  /// never be sent. The socket write happens synchronously in send(), so
  /// scheduling both sends as unawaited futures is safe.
  void _sendUpdates(Sender<Object?> sender) {
    try {
      final profile = this.profile;
      if (profile != null) {
        unawaited(_quietSend(sender, 'hub/profile/update', profile.toJson()));
      }
    } catch (_) {}
    try {
      unawaited(_quietSend(sender, 'hub/service/update', update()));
    } catch (_) {}
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
