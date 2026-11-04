<h1>
  <img alt="Hub Service logo" src="./icon.png" width="70" valign="middle">
  &nbsp;hub-service-dart
</h1>

Dart port of [hub-service](https://github.com/v57/hub-service) — connect to a
[hub](https://github.com/v57/hub-lite) (default `ws://127.0.0.1:1997`), host
your own post/stream API endpoints, register apps, and call API through the hub.

Connects with **hub-server auth**: every (re)connect asks the hub to prove its
key, then sends a fresh ed25519 keychain token as the `auth` header. The wire
contract matches the TS reference (`hub/profile/update`, `hub/service/update`,
AppInterface + element DSL). Auth and devices follow
[`Docs/Devices/protocol.md`](../../Docs/Devices/protocol.md).

## hub-server auth (keychain)

The keychain (`lib/src/keychain.dart`, TS `keychain.ts` parity) loads or
generates the `auth` key file in the working directory — the base64 of the
48-byte PKCS8 DER ed25519 private key followed by the 44-byte SPKI DER public
key. `sign()` returns a fresh `key.<pub>.<sig>.<expiry>.<nonce>` token, attached
as the `auth` header on every connect. Override the key path with the `HUBKEY`
env var or `setKeyPath(...)`.

- **Hub key:** before every connect the service asks `hub/info` with a fresh
  nonce on a short anonymous connection. Only an answer with a valid proof of
  the key it claims gets a token, signing `hub1:<hub key>:<challenge>:<expiry>`
  with `v: 1`. The first proven key is pinned in `hubs.json` beside the `auth`
  file. A hub that doesn't prove its key, or answers with another than the
  pinned one, gets nothing and is reported (`lastError`) while the service keeps
  trying, so calls made right after `start()` wait instead of being lost.
  `hubKey:` supplies it up front and `forgetHubKey()` clears the pin.
- **Transport:** plain `ws://` beyond loopback, the overlay and the LAN isn't
  dialed unless `allowPlaintext: true` or `HUB_ALLOW_PLAINTEXT=1` says so;
  `hubTransportOf(address)` classifies an address.
- **Device:** a certificate signed by `~/.hub/device.key` (`HUB_DEVICE_KEY`
  overrides it) goes in the `device` header and is renewed with less than a
  day left. `instance:` sets the instance name and `device: false` turns
  device mode off; `Device(path:, key:, name:, platform:, parent:)` overrides
  the defaults.

## Install

```bash
dart pub get   # path dependency on ../../Channel/channel-dart (see pubspec.yaml)
```

## Usage

Start a hub first (hub-server, listens on 1997), then:

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

- `Service({address, name, icon, sign, hubKey, allowPlaintext, instance, device})` —
  address is a port (int) or ws:// URL; default `1997` or `HUB` env; `sign`
  overrides the auth token factory with one given the proven hub key and the
  challenge (default: keychain `auth` file in the cwd)
- `sign(hubKey, nonce, [expires])` / `publicKey()` — keychain: fresh
  `key.<pub>.<sig>.<expiry>.<nonce>` token / the service's SPKI public key
  (base64)
- `setKeyPath(path)` — override the auth key file location (`HUBKEY` env also
  works; default `auth` in the cwd)
- `post(path, handler, {settings})` / `stream(path, handler, {settings})` — fluent;
  a handler is `(Object? body)` or `(Object? body, Request request)`:
  `request.caller` (`Caller`: `key`, `device` (`id`, `name`), `groups`,
  `owner`, `via`, `claimed`), `request.context` (without `hub`),
  `request.path`. The caller is null unless `context.hub.hubKey` is the
  pinned hub key: a hub that predates caller identity may pass a client's
  `context.hub` through.
- `app(App)` — register app header + `AppInterface` stream at `header.path`
- `send(path, {body, context})` — client call through the hub
- `values(path, {body, context})` — stream call through the hub
- `start()` — connect with a fresh `auth` header; re-sends
  `hub/profile/update` then `hub/service/update` on every (re)connect
- `stop()` — disconnect and stop reconnecting

`ApiSettings` carries `Permissions` (group auto-filled from the first path
segment, TS parity) and `Limit` — wire-parity fields that hub-lite ignores.

## Hub Network shares

A share makes a local TCP/UDP port reachable through Hub Network (TS
`publishShare` parity). The local hub-net agent attests each share over its
Unix socket (`/var/run/hub-net/agent.sock`, `service.network.agentSocket`),
then the declared set goes to the hub in one `network/shares/replace`, and it
is republished after every reconnect.

```dart
service.share('s3', 'tcp', '127.0.0.1', 9001, {'mode': 'hub'}); // before start()
await service.publishShare('ssh', 'tcp', '127.0.0.1', 22);     // after start()
await service.updateShare('ssh', port: 2222);
await service.removeShare('ssh');
service.sharePublication('s3'); // resourceId, authority, overlayAddress, port, ...
```

The default policy is `{'mode': 'private'}`; others are `hub`, `group`
(`group`), `keys` (`keys`) and `disabled`.

## Test

```bash
./scripts/test             # dart analyze + dart test
dart run example/echo.dart # example service (needs a hub on 1997)
# cross-language check (TS):
bun ../hub-service/tests/verify.ts echo echo/upper '"hello"' '"HELLO"'
```
