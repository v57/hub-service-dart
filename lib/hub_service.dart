/// hub-service for Dart: connect to a hub, host post/stream API endpoints,
/// register apps, and call API through the hub.
///
/// Port of [hub-service](https://github.com/v57/hub-service) (TS reference).
/// Connects with hub-pro auth (fresh ed25519 keychain token as the `auth`
/// header + `v: '0'`) on every (re)connect; hub-lite ignores the auth header.
/// The wire contract matches the TS/Go reference — hub/profile/update and
/// hub/service/update are re-sent on every (re)connect (the hub drops
/// services on disconnect).
library;

export 'src/device.dart' hide truncateUtf8;
export 'src/keychain.dart';
export 'src/request.dart';
export 'src/service.dart';
export 'src/app.dart';
