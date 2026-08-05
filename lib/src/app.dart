/// App interface and element DSL (TS app.ts parity).
///
/// Element helpers produce maps matching the TS wire shapes. Optional keys are
/// omitted (never null). The App interface map always carries all five keys:
/// header, body, top, bottom, data.
library;

import 'service.dart';

/// References an API call from a UI element: {path, body?, output?}.
class Action {
  Action({required this.path, this.body, this.output});

  final String path;
  final Object? body;
  final Object? output;

  Map<String, Object?> toJson() => <String, Object?>{
        'path': path,
        if (body != null) 'body': body,
        if (output != null) 'output': output,
      };
}

/// A hub app: a header plus a UI body of elements.
///
/// [body] is a list of element maps built with the helpers below; plain
/// strings are allowed as shorthand text.
class App {
  App({
    required this.header,
    required this.body,
    this.data = const <String, Object?>{},
    this.top,
    this.bottom,
  });

  final AppHeader header;
  final List<Object?> body;
  final Map<String, Object?> data;
  final Object? top;
  final Object? bottom;

  /// The AppInterface streamed at the app path (all 5 keys present).
  Map<String, Object?> interface() => <String, Object?>{
        'header': header.toJson(),
        'body': body,
        'top': top,
        'bottom': bottom,
        'data': data,
      };
}

/// Element helpers (TS app.ts parity). Optional keys are omitted.

Map<String, Object?> text(String value, {bool? secondary}) =>
    <String, Object?>{
      'type': 'text',
      'value': value,
      if (secondary != null) 'secondary': secondary,
    };

Map<String, Object?> progress(String value, {Object? min, Object? max}) =>
    <String, Object?>{
      'type': 'progress',
      'value': value,
      if (min != null) 'min': min,
      if (max != null) 'max': max,
    };

Map<String, Object?> textField(
  String value, {
  String? placeholder,
  Action? action,
}) =>
    <String, Object?>{
      'type': 'textField',
      'value': value,
      if (placeholder != null) 'placeholder': placeholder,
      if (action != null) 'action': action.toJson(),
    };

Map<String, Object?> button(String title, Action action) => <String, Object?>{
      'type': 'button',
      'title': title,
      'action': action.toJson(),
    };

Map<String, Object?> slider(
  String value, {
  Object? defaultValue,
  Object? min,
  Object? max,
  Object? step,
  Action? action,
}) =>
    <String, Object?>{
      'type': 'slider',
      'value': value,
      if (defaultValue != null) 'defaultValue': defaultValue,
      if (min != null) 'min': min,
      if (max != null) 'max': max,
      if (step != null) 'step': step,
      if (action != null) 'action': action.toJson(),
    };

Map<String, Object?> list(Object? data, Object? content) => <String, Object?>{
      'type': 'list',
      'data': data,
      'content': content,
    };

Map<String, Object?> picker(List<String> options, String selected) =>
    <String, Object?>{
      'type': 'picker',
      'options': options,
      'selected': selected,
    };

Map<String, Object?> cell({Object? title, Object? subtitle}) =>
    <String, Object?>{
      'type': 'cell',
      if (title != null) 'title': title,
      if (subtitle != null) 'subtitle': subtitle,
    };

Map<String, Object?> files(
  String value, {
  Object? title,
  Action? action,
}) =>
    <String, Object?>{
      'type': 'files',
      'value': value,
      if (title != null) 'title': title,
      if (action != null) 'action': action.toJson(),
    };

Map<String, Object?> fileOperation({
  String? format,
  Object? title,
  Action? action,
}) =>
    <String, Object?>{
      'type': 'fileOperation',
      if (format != null) 'format': format,
      if (title != null) 'title': title,
      if (action != null) 'action': action.toJson(),
    };

Map<String, Object?> hstack(List<Object?> content, {Object? spacing}) =>
    <String, Object?>{
      'type': 'hstack',
      'content': content,
      if (spacing != null) 'spacing': spacing,
    };

Map<String, Object?> vstack(List<Object?> content, {Object? spacing}) =>
    <String, Object?>{
      'type': 'vstack',
      'content': content,
      if (spacing != null) 'spacing': spacing,
    };

Map<String, Object?> zstack(List<Object?> content) => <String, Object?>{
      'type': 'zstack',
      'content': content,
    };

Map<String, Object?> spacer() => <String, Object?>{'type': 'spacer'};
