// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/model_connection_preset.dart';
import 'package:asg/models/model_test_observation.dart';
import 'package:asg/services/local_model.dart';
import 'package:asg/views/model_test_observation_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object?> reply({
  Object? model = 'requested',
  bool include = true,
}) => {
  if (include) 'model': model,
  'choices': [
    {
      'message': {'content': 'Ready'},
      'finish_reason': 'stop',
    },
  ],
};
String event(Object data) => 'data: ${jsonEncode(data)}\n\n';
void main() {
  for (final streaming in [false, true]) {
    for (final include in [false, true]) {
      test(
        'completed identity streaming=$streaming reported=$include',
        () async {
          final provider = LocalModelProvider(
            const LocalModelConfig(model: 'requested'),
            client: MockClient(
              (_) async => http.Response(
                streaming
                    ? [
                        event({
                          if (include) 'model': 'requested',
                          'choices': [
                            {
                              'delta': {'content': 'Ready'},
                            },
                          ],
                        }),
                        event({
                          'choices': [
                            {
                              'delta': <String, Object>{},
                              'finish_reason': 'stop',
                            },
                          ],
                        }),
                        'data: [DONE]\n\n',
                      ].join()
                    : jsonEncode(reply(include: include)),
                200,
                headers: {
                  'content-type': streaming
                      ? 'text/event-stream'
                      : 'application/json',
                },
              ),
            ),
          );
          final stream = provider.generate('private prompt');
          expect(provider.completedResponseModel, isNull);
          expect(await stream.join(), 'Ready');
          expect(provider.completedResponseModel, include ? 'requested' : null);
          await provider.cancel();
          expect(provider.completedResponseModel, isNull);
        },
      );
    }
  }
  for (final suffix in [
    '${event({'model': 'different', 'choices': <Object>[]})}data: [DONE]\n\n',
    '',
    'data: {broken}\n\n',
  ]) {
    test(
      'late failure or incomplete stream cannot publish identity: $suffix',
      () async {
        final provider = LocalModelProvider(
          const LocalModelConfig(model: 'requested'),
          client: MockClient(
            (_) async => http.Response(
              event({
                    'model': 'requested',
                    'choices': [
                      {
                        'delta': {'content': 'partial'},
                      },
                    ],
                  }) +
                  suffix,
              200,
              headers: {'content-type': 'text/event-stream'},
            ),
          ),
        );
        await expectLater(
          provider.generate('private prompt').drain<void>(),
          throwsA(isA<StateError>()),
        );
        expect(provider.completedResponseModel, isNull);
        await provider.cancel();
      },
    );
  }
  final legacy = ModelTestObservation(
    jsonFormat: false,
    observedAt: DateTime.utc(2026),
    firstTextMilliseconds: 1,
    completedMilliseconds: 2,
  ).toJson();
  test(
    'additive schema refuses malformed and contradictory durable identity',
    () {
      expect(ModelTestObservation.fromJson(legacy).responseModel, isNull);
      expect(
        ModelTestObservation.fromJson({...legacy, 'responseModel': 'requested'})
            .responseModel,
        'requested',
      );
      for (final value in [null, 1, '', ' ', 'bad\nvalue', 'x' * 257]) {
        expect(
          () => ModelTestObservation.fromJson({
            ...legacy,
            'responseModel': value,
          }),
          throwsFormatException,
        );
      }
      final preset = const ModelConnectionPreset(
        name: 'Local',
        config: LocalModelConfig(model: 'requested'),
      ).toJson();
      expect(
        () => ModelConnectionPreset.fromJson({
          ...preset,
          'testObservation': {...legacy, 'responseModel': 'different'},
        }),
        throwsFormatException,
      );
      expect(
        () => ModelTestObservation.fromJson({...legacy, 'private': 'debug'}),
        throwsFormatException,
      );
    },
  );
  testWidgets(
    'historical reported and legacy identity stay honest at 320px 2x',
    (tester) async {
      tester.view.physicalSize = const Size(320, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final model in [null, 'requested']) {
        final preset = ModelConnectionPreset.fromJson({
          ...const ModelConnectionPreset(
            name: 'Local',
            config: LocalModelConfig(model: 'requested'),
          ).toJson(),
          'testObservation': {...legacy, 'responseModel': ?model},
        });
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: ModelTestObservationView(preset: preset),
                ),
              ),
            ),
          ),
        );
        expect(
          find.text(
            model == null
                ? 'Historical response model ID: unavailable (not recorded).'
                : 'Historical response model ID: requested',
          ),
          findsOneWidget,
        );
        await tester.ensureVisible(
          find.text(ModelTestObservation.responseModelGuidance),
        );
        expect(tester.takeException(), isNull);
      }
    },
  );
}
