/// hub-service for Dart: connect to a hub, host post/stream API endpoints,
/// register apps, and call API through the hub.
///
/// Port of [hub-service](https://github.com/v57/hub-service) (TS reference).
/// Every (re)connect asks the hub to prove its key and sends a fresh ed25519
/// keychain token for that answer alone (Docs/Devices/protocol.md section 2).
/// The wire contract matches the TS/Go reference — hub/profile/update and
/// hub/service/update are re-sent on every (re)connect (the hub drops
/// services on disconnect).
library;

export 'src/device.dart' hide truncateUtf8;
export 'src/hub_proof.dart';
export 'src/keychain.dart';
export 'src/network.dart';
export 'src/request.dart';
export 'src/service.dart';
export 'src/app.dart';
