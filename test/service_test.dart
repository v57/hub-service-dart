import 'dart:convert';

import 'package:hub_service/hub_service.dart';
import 'package:test/test.dart';

void main() {
  test('services list includes registered paths sorted', () {
    final service = Service()
      ..post('echo', (Object? body) => body)
      ..stream('echo/values', (Object? _) => Stream<Object?>.value('x'))
      ..app(App(header: AppHeader(name: 'Echo', path: 'echo/ui'), body: <Object?>['hi']));
    final update = service.update();
    final paths = (update['services'] as List<Object?>)
        .map((e) => (e as Map<Object?, Object?>)['path'])
        .toList();
    expect(paths, <Object?>['echo', 'echo/ui', 'echo/values']);
    expect(update['apps'], <Object?>[
      <String, Object?>{'type': 'app', 'name': 'Echo', 'path': 'echo/ui'},
    ]);
  });

  test('settings group auto-fill and limit', () {
    final service = Service();
    service.post(
      'echo',
      (Object? body) => body,
      settings: ApiSettings(
        permissions: ServicePermissions(name: 'Echo', allows: true),
        limit: 5,
      ),
    );
    final svc = (service.update()['services'] as List<Object?>).first
        as Map<Object?, Object?>;
    expect(svc['permissions'], <Object?, Object?>{
      'group': 'echo',
      'name': 'Echo',
      'allows': true,
    });
    expect(svc['limit'], 5);
  });

  test('update payload matches exact wire JSON', () {
    final service = Service();
    service.post(
      'echo',
      (Object? body) => body,
      settings: ApiSettings(
        permissions: ServicePermissions(name: 'Echo', allows: true),
        limit: 5,
      ),
    );
    expect(
      jsonEncode(service.update()),
      '{"services":[{"path":"echo","permissions":{"group":"echo","name":"Echo","allows":true},"limit":5}],"apps":[]}',
    );
  });

  test('profile only when set', () {
    expect(Service().profile, isNull);
    final service = Service(
      name: 'Echo',
      icon: const <String, Object?>{'symbol': 'speaker.wave.2', 'text': 'E'},
    );
    expect(service.profile, isNotNull);
    expect(service.profile!.name, 'Echo');
    expect(service.profile!.icon, <String, Object?>{
      'symbol': 'speaker.wave.2',
      'text': 'E',
    });
  });

  test('send/values before start throw StateError', () {
    final service = Service();
    expect(() => service.send('echo'), throwsStateError);
    expect(() => service.values('echo'), throwsStateError);
  });

  test('app interface has all five keys', () {
    final app = App(
      header: AppHeader(name: 'Echo', path: 'echo/ui'),
      body: <Object?>[
        'hi',
        textField(
          'echo',
          placeholder: 'Text',
          action: Action(path: 'echo/upper', body: 'value', output: 'value'),
        ),
      ],
      data: const <String, Object?>{'hello': 'world'},
    );
    final interface = app.interface();
    expect(interface.keys.toSet(), <Object?>{'header', 'body', 'top', 'bottom', 'data'});
    expect(interface['header'], <String, Object?>{
      'type': 'app',
      'name': 'Echo',
      'path': 'echo/ui',
    });
  });

  test('element helpers match wire shapes', () {
    expect(
      button('Upper', Action(path: 'echo/upper')),
      <String, Object?>{'type': 'button', 'title': 'Upper', 'action': <String, Object?>{'path': 'echo/upper'}},
    );
    expect(
      cell(title: '\$Echo', subtitle: 'value'),
      <String, Object?>{'type': 'cell', 'title': '\$Echo', 'subtitle': 'value'},
    );
  });
}
