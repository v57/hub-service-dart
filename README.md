<h1>
  <img alt="Hub Service logo" src="./icon.png" width="70" valign="middle">
  &nbsp;hub-service-dart
</h1>

Dart port of [hub-service](https://github.com/v57/hub-service) — connect to a
[hub](https://github.com/v57/hub-lite) (default `ws://127.0.0.1:1997`), host
your own post/stream API endpoints, register apps, and call API through the hub.

Connects with **hub-pro auth** (a fresh ed25519 keychain token as the `auth`
header + `v: 0`) on every (re)connect; hub-lite ignores the auth header. The
wire contract matches the TS reference (`hub/profile/update`,
`hub/service/update`, AppInterface + element DSL).

## hub-pro auth (keychain)

The keychain (`lib/src/keychain.dart`, TS `keychain.ts` parity) loads or
generates the `auth` key file in the working directory — the base64 of the
48-byte PKCS8 DER ed25519 private key followed by the 44-byte SPKI DER public
key. `sign()` returns a fresh `key.<pub>.<sig>.<expiry>` token (signature over
the decimal expiry string), attached as the `auth` header on every connect.
Override the key path with the `HUBKEY` env var or `setKeyPath(...)`.

## Install

```bash
dart pub get   # path dependency on ../../Channel/channel-dart (see pubspec.yaml)
```

## Usage

Start a hub first (`new Hub()` from hub-lite, listens on 1997), then:

```dart
import 'package:hub_service/hub_service.dart';

Future<void> main() async {
  final service = Service(
    name: 'Echo',
    icon: const {'symbol': 'speaker.wave.2', 'text': 'E'},
  )
    ..post('echo', (body) => body)
    ..post('echo/upper', (body) => '$body'.toUpperCase())
    ..app(App(
      header: AppHeader(name: 'Echo', path: 'echo/ui'),
      body: [
        'Hello from Dart',
        textField('echo', placeholder: 'Text to echo',
          action: Action(path: 'echo/upper', body: 'value', output: 'value')),
        cell(title: '\$Echo', subtitle: 'value'),
      ],
    ))
    ..start();

  // Keep the process alive; the hub connection stays open.
  await Completer<void>().future;
}
```

Call it through the hub (any language):

```dart
final response = await service.send('echo/upper', body: 'hello'); // "HELLO"
```

## API

- `Service({address, name, icon, sign})` — address is a port (int) or ws://
  URL; default `1997` or `HUB` env; `sign` overrides the auth token factory
  (default: keychain `auth` file in the cwd)
- `sign([expires])` / `publicKey()` — keychain: fresh `key.<pub>.<sig>.<expiry>`
  token / the service's SPKI public key (base64)
- `setKeyPath(path)` — override the auth key file location (`HUBKEY` env also
  works; default `auth` in the cwd)
- `post(path, handler, {settings})` / `stream(path, handler, {settings})` — fluent
- `app(App)` — register app header + `AppInterface` stream at `header.path`
- `send(path, {body, context})` — client call through the hub
- `values(path, {body, context})` — stream call through the hub
- `start()` — connect with a fresh `auth` header; re-sends
  `hub/profile/update` then `hub/service/update` on every (re)connect

`ApiSettings` carries `Permissions` (group auto-filled from the first path
segment, TS parity) and `Limit` — wire-parity fields that hub-lite ignores.

## Test

```bash
./scripts/test             # dart analyze + dart test
dart run example/echo.dart # example service (needs a hub on 1997)
# cross-language check (TS):
bun ../hub-service/tests/verify.ts echo echo/upper '"hello"' '"HELLO"'
```
