// Echo example service: registers echo/echo/upper posts and an app on the hub.
//
// Run (needs a hub on 127.0.0.1:1997):
//     dart run example/echo.dart
import 'dart:async';

import 'package:hub_service/hub_service.dart';

Future<void> main() async {
  final service = Service(
    name: 'Echo',
    icon: const <String, Object?>{'symbol': 'speaker.wave.2', 'text': 'E'},
  )
    ..post('echo', (Object? body) => body)
    ..post('echo/upper', (Object? body) => '$body'.toUpperCase())
    ..app(
      App(
        header: AppHeader(name: 'Echo', path: 'echo/ui'),
        body: <Object?>[
          'Hello from Dart',
          textField(
            'echo',
            placeholder: 'Text to echo',
            action: Action(path: 'echo/upper', body: 'value', output: 'value'),
          ),
          cell(title: '\$Echo', subtitle: 'value'),
          button(
            'Upper',
            Action(path: 'echo/upper', body: 'value', output: 'value'),
          ),
        ],
        data: const <String, Object?>{'hello': 'world'},
      ),
    )
    ..start();

  print('echo service started (hub-lite :1997)');
  // Keep the process alive; the hub connection stays open.
  await Completer<void>().future;
}
