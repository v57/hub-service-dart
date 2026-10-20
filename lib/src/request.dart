/// Caller identity from `context.hub.caller` (Docs/Devices/protocol.md §4).
library;

/// The caller's device, when its connection is device-attached.
class CallerDevice {
  const CallerDevice({required this.id, required this.name});

  final String id;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is CallerDevice && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// Who is calling, as the hub saw it. [key] is null for anonymous callers,
/// [device] null for clients without one; [via] and [claimed] are set for
/// calls through a merged hub ([claimed] is unverified).
class Caller {
  const Caller({
    this.key,
    this.device,
    this.groups = const <String>[],
    this.owner = false,
    this.via,
    this.claimed,
  });

  final String? key;
  final CallerDevice? device;

  /// Every group the key or its device belongs to.
  final List<String> groups;
  final bool owner;
  final String? via;
  final Caller? claimed;

  static Caller? parse(Object? value) {
    if (value is! Map) {
      return null;
    }
    final device = value['device'];
    final groups = value['groups'];
    final key = value['key'];
    final via = value['via'];
    return Caller(
      key: key is String ? key : null,
      device: device is Map
          ? CallerDevice(id: '${device['id'] ?? ''}', name: '${device['name'] ?? ''}')
          : null,
      groups: groups is List ? groups.whereType<String>().toList() : const <String>[],
      owner: value['owner'] == true,
      via: via is String ? via : null,
      claimed: parse(value['claimed']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Caller &&
      other.key == key &&
      other.device == device &&
      _sameList(other.groups, groups) &&
      other.owner == owner &&
      other.via == via &&
      other.claimed == claimed;

  @override
  int get hashCode => Object.hash(key, device, Object.hashAll(groups), owner, via, claimed);

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// What a two-argument handler gets next to the body: the caller (null when
/// the hub sent none, e.g. hub-lite), the forwarding hub's key, the full
/// request context and the called path.
class Request {
  const Request({required this.caller, required this.hubKey, required this.context, required this.path});

  factory Request.fromContext(Object? context, String path) {
    final map = context is Map ? context : const <Object?, Object?>{};
    final hub = map['hub'];
    final hubKey = hub is Map ? hub['hubKey'] : null;
    return Request(
      caller: hub is Map ? Caller.parse(hub['caller']) : null,
      hubKey: hubKey is String ? hubKey : null,
      context: map,
      path: path,
    );
  }

  final Caller? caller;
  final String? hubKey;
  final Map<Object?, Object?> context;
  final String path;
}
