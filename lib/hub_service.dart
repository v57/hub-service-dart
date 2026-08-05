/// hub-service for Dart: connect to a hub, host post/stream API endpoints,
/// register apps, and call API through the hub.
///
/// Lite port of [hub-service](https://github.com/v57/hub-service) (TS
/// reference): no auth, no keychain, no crypto. The wire contract matches the
/// TS/Go reference — hub/profile/update and hub/service/update are re-sent on
/// every (re)connect (the hub drops services on disconnect).
library;

export 'src/service.dart';
export 'src/app.dart';
