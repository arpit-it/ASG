// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../models/app_definition.dart';
import '../models/local_model_config.dart';
import 'local_model.dart';
import 'model_provider.dart';
import 'local_application_actions.dart';
import '../models/generation_event.dart';
import 'streamed_summary.dart';

class ApplicationUpdate {
  const ApplicationUpdate(this.definition, this.summary);
  final AppDefinition definition;
  final String summary;
}

class ApplicationEditor {
  ApplicationEditor({
    ProviderFactory? createProvider,
    this.allowBuiltInEdits = true,
  }) : _createProvider =
           createProvider ??
           ((config) => LocalModelProvider(config, maxTokens: 2048));
  final ProviderFactory _createProvider;
  final bool allowBuiltInEdits;
  ModelProvider? _provider;
  Future<ApplicationUpdate> apply(
    LocalModelConfig config,
    AppDefinition current,
    String instruction, {
    void Function(GenerationEvent)? onProgress,
  }) async {
    final direct = allowBuiltInEdits
        ? LocalApplicationActions().apply(current, instruction)
        : null;
    if (direct != null) {
      onProgress?.call(const GenerationEvent.phase(GenerationPhase.applying));
      return ApplicationUpdate(direct.definition, direct.summary);
    }
    _provider = _createProvider(config);
    try {
      final compact = current.toJson();
      compact['elements'] = current.elements
          .map(
            (e) => e.toJson()
              ..removeWhere(
                (key, value) =>
                    value == '' ||
                    value is List && value.isEmpty ||
                    key == 'action' && e.kind != ElementKind.button,
              ),
          )
          .toList();
      final prompt =
          'Edit this app. Put summary FIRST. Return JSON only: {"summary":"brief description","edits":[...]}. '
          'Edits: {"op":"setTitle","value":"title"}, {"op":"setTheme","value":"indigo|green|orange|pink"}, '
          '{"op":"addElement","element":{"id":"unique_id","type":"heading|text|taskList|counter|notes|button","label":"text"}}, '
          '{"op":"removeElement","id":"existing_id"}, or {"op":"replaceElement","element":{...}}. '
          'Optional element fields: items (strings), value (string), action (message|increment|clear|addItem), target (element id). '
          'Current: ${jsonEncode(compact)}. Instruction: $instruction';
      final buffer = StringBuffer();
      final activeProvider = _provider!;
      if (activeProvider is StreamingModelProvider) {
        await for (final event in activeProvider.generateEvents(prompt)) {
          if (event.text.isEmpty) {
            onProgress?.call(event);
          } else {
            buffer.write(event.text);
            onProgress?.call(
              GenerationEvent.text(streamedSummary(buffer.toString())),
            );
          }
        }
      } else {
        onProgress?.call(const GenerationEvent.phase(GenerationPhase.thinking));
        await for (final chunk in activeProvider.generate(prompt)) {
          buffer.write(chunk);
          onProgress?.call(
            GenerationEvent.text(streamedSummary(buffer.toString())),
          );
        }
      }
      onProgress?.call(const GenerationEvent.phase(GenerationPhase.validating));
      var jsonText = buffer.toString().trim();
      if (jsonText.startsWith('```') && jsonText.endsWith('```')) {
        jsonText = jsonText
            .substring(jsonText.indexOf('\n') + 1, jsonText.lastIndexOf('```'))
            .trim();
      }
      final data = jsonDecode(jsonText) as Map<String, dynamic>;
      final definition = data.containsKey('edits')
          ? applyEdits(current, data['edits'])
          : AppDefinition.fromJson(data['app'] as Map<String, dynamic>);
      final summary = data['summary'];
      if (summary is! String ||
          summary.trim().isEmpty ||
          summary.length > 1000) {
        throw const FormatException(
          'Model did not return a valid update summary.',
        );
      }
      return ApplicationUpdate(definition, summary);
    } finally {
      await _provider?.cancel();
      _provider = null;
    }
  }

  AppDefinition applyEdits(AppDefinition current, Object? raw) {
    if (raw is! List || raw.isEmpty || raw.length > 24) {
      throw const FormatException('Invalid edit list.');
    }
    final data = current.toJson();
    final elements = List<Map<String, dynamic>>.from(
      current.elements.map((e) => e.toJson()),
    );
    for (final entry in raw) {
      final edit = Map<String, dynamic>.from(entry as Map);
      switch (edit['op']) {
        case 'setTitle':
          data['title'] = edit['value'];
        case 'setTheme':
          data['theme'] = edit['value'];
        case 'addElement':
          elements.add(Map<String, dynamic>.from(edit['element'] as Map));
        case 'replaceElement':
          final element = Map<String, dynamic>.from(edit['element'] as Map);
          final index = elements.indexWhere((e) => e['id'] == element['id']);
          if (index < 0) {
            throw const FormatException('Cannot replace a missing element.');
          }
          elements[index] = element;
        case 'removeElement':
          final index = elements.indexWhere((e) => e['id'] == edit['id']);
          if (index < 0) {
            throw const FormatException('Cannot remove a missing element.');
          }
          elements.removeAt(index);
        default:
          throw const FormatException('Unsupported application edit.');
      }
    }
    data['elements'] = elements;
    return AppDefinition.fromJson(data);
  }

  void cancel() {
    _provider?.cancel();
  }
}
