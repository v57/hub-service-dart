/// Core hub-service types (TS service.ts parity).
///
/// Lite port of hub-service: no auth, no keychain, no crypto. The wire
/// contract matches the TS/Go reference — hub/profile/update and
/// hub/service/update are re-sent on every (re)connect (the hub drops
/// services on disconnect).
library;

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
