/// Core hub-service types (TS service.ts parity).
///
/// Lite port of hub-service: no auth, no keychain, no crypto. The wire
/// contract matches the TS/Go reference — hub/profile/update and
/// hub/service/update are re-sent on every (re)connect (the hub drops
/// services on disconnect).
library;

import 'dart:async';
import 'dart:io';

import 'package:channel_dart/channel.dart';

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
  Service({Object? address, String? name, Object? icon}) {
    this.address = address ?? (Platform.environment['HUB'] ?? 1997);
    if (name != null || icon != null) {
      profile = Profile(name: name, icon: icon);
    }
  }

  /// Underlying channel; post/stream handlers are registered on it.
  final Channel<Object?> channel = Channel<Object?>();

  /// Hub address: a port (int) or a ws:// URL (String).
  late Object? address;

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
}
