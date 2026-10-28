// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:asg/models/app_definition.dart';

import 'package:asg/models/chat_message.dart';
import 'package:asg/models/portable_project_archive.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:flutter_test/flutter_test.dart';

RequirementsBoard board() => RequirementsBoard(
  revision: 7,
  requirements: [
    ProjectRequirement(id: 'R1', title: 'Résumé', acceptance: 'Keep 中文 text'),
  ],
  tasks: [
    DevelopmentTask(
      id: 'T1',
      requirementId: 'R1',
      title: 'First',
      status: TaskStatus.done,
    ),
    DevelopmentTask(
      id: 'T2',
      requirementId: 'R1',
      title: 'Next',
      dependencies: ['T1'],
      status: TaskStatus.inProgress,
    ),
  ],
);
PortableProjectArchive archive() => PortableProjectArchive(
  requirements: board(),
  messages: const [
    ChatMessage(role: 'user', content: 'Keep exact\ntext 😀'),
    ChatMessage(
      role: 'assistant',
      content: 'Plan',
      planContext: '/private/path secret-execution-context',
    ),
  ],
);

void main() {
  test(
    'portable requirements revisions stay within exact browser integer range',
    () {
      for (final revision in [0, 1, 9007199254740991]) {
        final value = PortableProjectArchive(
          requirements: RequirementsBoard(revision: revision),
          messages: [],
        );
        expect(
          PortableProjectArchive.decode(value.encode()).requirements.revision,
          revision,
        );
      }
      for (final revision in [9007199254740992, 9007199254740994]) {
        expect(
          () => PortableProjectArchive(
            requirements: RequirementsBoard(revision: revision),
            messages: [],
          ),
          throwsFormatException,
        );
        final raw = jsonDecode(archive().encode()) as Map<String, dynamic>;
        raw['requirements']['revision'] = revision;
        expect(
          () => PortableProjectArchive.decode(jsonEncode(raw)),
          throwsFormatException,
        );
      }
    },
  );

  test('v6 prototype text round trip excludes context and refuses malformed conversations', () {
    final messages = [
      const ChatMessage(
        role: 'assistant',
        content: 'Exact\nedit 😀',
        planContext: 'private-context',
      ),
    ];
    final value = PortableProjectArchive(
      requirements: board(),
      messages: [],
      prototype: PortablePrototype(
        revision: 3,
        messages: messages,
        definition: const AppDefinition(
          title: 'Title',
          theme: 'green',
          elements: [
            AppElement(id: 'title', kind: ElementKind.heading, label: 'Title'),
          ],
        ),
      ),
    );
    messages.clear();
    final encoded = value.encode();
    expect(jsonDecode(encoded)['version'], 6);
    expect(encoded, isNot(contains('private-context')));
    expect(encoded, isNot(contains('planContext')));
    final decoded = PortableProjectArchive.decode(encoded);
    expect(decoded.encode(), encoded);
    expect(decoded.prototype!.messages.single.content, 'Exact\nedit 😀');
    expect(() => decoded.prototype!.messages.clear(), throwsUnsupportedError);
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (j) => j['version'] = 5,
      (j) => j['prototype'].remove('messages'),
      (j) => j['prototype']['messages'] = null,
      (j) => j['prototype']['messages'][0]['planContext'] = 'credential',
      (j) => j['prototype']['messages'][0]['role'] = 'system',
      (j) => j['prototype']['messages'][0]['content'] = 7,
      (j) => j['prototype']['messages'][0]['content'] = 'x' * 100001,
      (j) => j['prototype']['messages'] = List.filled(1001, {
        'role': 'user',
        'content': 'text',
      }),
    ]) {
      final json = jsonDecode(encoded) as Map<String, dynamic>;
      mutate(json);
      expect(
        () => PortableProjectArchive.decode(jsonEncode(json)),
        throwsFormatException,
      );
    }
    expect(
      () => PortableProjectArchive.decode(
        encoded.replaceFirst('"content":', '"content":"lost","content":'),
      ),
      throwsFormatException,
    );
    final oversized = PortableProjectArchive(
      requirements: board(),
      messages: [],
      prototype: PortablePrototype(
        definition: value.prototype!.definition,
        revision: 3,
        messages: List.filled(
          4,
          ChatMessage(role: 'user', content: '界' * 100000),
        ),
      ),
    );
    expect(oversized.encode, throwsFormatException);
    final legacy = jsonDecode(encoded) as Map<String, dynamic>;
    legacy['version'] = 5;
    (legacy['prototype'] as Map).remove('messages');
    expect(
      PortableProjectArchive.decode(jsonEncode(legacy)).prototype!.messages,
      isEmpty,
    );
  });
  test('v5 immutable prototype round trip and strict malformed rejection', () {
    final items = ['Résumé 😀'];
    final original = PortableProjectArchive(
      requirements: board(),
      messages: [],
      prototype: PortablePrototype(
        revision: 12,
        definition: AppDefinition(
          title: 'Saved 中文',
          theme: 'green',
          elements: [
            AppElement(
              id: 'items',
              kind: ElementKind.taskList,
              label: 'Tasks',
              items: items,
              completed: const [0],
            ),
          ],
        ),
      ),
    );
    items.clear();
    final restored = PortableProjectArchive.decode(original.encode());
    expect(restored.encode(), original.encode());
    expect(restored.prototype!.definition.elements.single.items, ['Résumé 😀']);
    expect(jsonDecode(original.encode())['version'], 5);
    expect(
      () => restored.prototype!.definition.elements.clear(),
      throwsUnsupportedError,
    );
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (j) => j['prototype'] = null,
      (j) => j['prototype']['revision'] = 0,
      // JavaScript JSON serialization erases the integral-double distinction.
      if (!kIsWeb) (j) => j['prototype']['revision'] = 1.0,
      (j) => j['prototype']['revision'] = 1.5,
      (j) => j['prototype']['revision'] = 9007199254740992,
      (j) => j['prototype']['messages'] = [],
      (j) => j['prototype']['definition']['path'] = '/private',
      (j) => j['prototype']['definition']['theme'] = 'invalid',
      (j) => j['prototype']['definition']['elements'][0]['action'] = null,
      (j) => j['prototype']['definition']['elements'][0]['items'] = null,
      (j) => j['prototype']['definition']['elements'][0]['completed'] = [1],
      (j) =>
          j['prototype']['definition']['elements'][0]['context'] = 'credential',
      (j) => j['version'] = 4,
    ]) {
      final json = jsonDecode(original.encode()) as Map<String, dynamic>;
      mutate(json);
      expect(
        () => PortableProjectArchive.decode(jsonEncode(json)),
        throwsFormatException,
      );
    }
    expect(
      () => PortableProjectArchive.decode(
        original.encode().replaceFirst(
          '"theme":"green"',
          '"theme":"pink","theme":"green"',
        ),
      ),
      throwsFormatException,
    );
    expect(PortableProjectArchive.decode(archive().encode()).prototype, isNull);
  });
  test('v4 preserves paired historical input revisions and rejects invalid metadata', () {
    final a = PortableProjectArchive(
      requirements: board(),
      messages: [],
      revisions: [
        PortableRevisionSummary(
          recordedAt: null,
          outcome: 'failed',
          passedChecks: 0,
          totalChecks: 0,
          requirementsRevision: 0,
          prototypeRevision: 12,
        ),
        PortableRevisionSummary(
          recordedAt: null,
          outcome: 'failed',
          passedChecks: 0,
          totalChecks: 0,
        ),
      ],
    );
    expect(jsonDecode(a.encode())['version'], 4);
    final restored = PortableProjectArchive.decode(a.encode());
    expect(restored.encode(), a.encode());
    expect(restored.revisions.first.prototypeRevision, 12);
    expect(restored.revisions.last.requirementsRevision, isNull);
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (j) => j['revisions'][0]['requirementsRevision'] = -1,
      (j) => j['revisions'][0]['prototypeRevision'] = 0,
      (j) => j['revisions'][0]['prototypeRevision'] = null,
      // JavaScript JSON serialization erases the integral-double distinction.
      if (!kIsWeb) (j) => j['revisions'][0]['requirementsRevision'] = 1.0,
      (j) => j['revisions'][0]['requirementsRevision'] = 1.5,
      (j) => j['revisions'][0]['prototypeRevision'] = 9007199254740992,
      (j) => j['revisions'][0].remove('prototypeRevision'),
      (j) => j['version'] = 3,
    ]) {
      final json = jsonDecode(a.encode()) as Map<String, dynamic>;
      mutate(json);
      expect(
        () => PortableProjectArchive.decode(jsonEncode(json)),
        throwsFormatException,
      );
    }
  });

  test(
    'revision summaries preserve bounded historical evidence and old versions',
    () {
      final original = PortableProjectArchive(
        requirements: board(),
        messages: archive().messages,
        revisions: [
          PortableRevisionSummary(
            recordedAt: DateTime.utc(2026),
            outcome: 'ready',
            passedChecks: 4,
            totalChecks: 4,
          ),
          PortableRevisionSummary(
            recordedAt: null,
            outcome: 'failed',
            passedChecks: 1,
            totalChecks: 2,
          ),
        ],
      );
      expect(
        PortableProjectArchive.decode(original.encode()).encode(),
        original.encode(),
      );
      expect(jsonDecode(original.encode())['version'], 3);
      final withDecision = PortableProjectArchive(
        requirements: board(),
        messages: [],
        revisions: original.revisions,
        decision: PortablePlanDecision(
          content: 'Historical only',
          approved: false,
          recordedAt: DateTime.utc(2026),
        ),
      );
      expect(
        PortableProjectArchive.decode(withDecision.encode()).encode(),
        withDecision.encode(),
      );

      expect(() => original.revisions.clear(), throwsUnsupportedError);
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (j) => j['revisions'][0]['outcome'] = 'verifying',
        (j) => j['revisions'][0]['passedChecks'] = 3,
        (j) => j['revisions'][0]['totalChecks'] = 5,
        // JavaScript JSON serialization erases the integral-double distinction.
        if (!kIsWeb) (j) => j['revisions'][0]['passedChecks'] = 4.0,
        (j) => j['revisions'][0]['passedChecks'] = 3.5,
        (j) => j['revisions'][0]['recordedAt'] = '2026-02-31T00:00:00.000Z',
        (j) => j['revisions'][0]['recordedAt'] = true,
        (j) => j['revisions'][0]['directory'] = '/private',
        (j) => j['revisions'] = List.filled(1001, j['revisions'][0]),
        (j) => j['revisions'] = null,
        (j) => j['version'] = 2,
      ]) {
        final json = jsonDecode(original.encode()) as Map<String, dynamic>;
        mutate(json);
        expect(
          () => PortableProjectArchive.decode(jsonEncode(json)),
          throwsFormatException,
        );
      }
      expect(
        () => PortableProjectArchive.decode(
          original.encode().replaceFirst(
            '"outcome":',
            '"outcome":"failed","outcome":',
          ),
        ),
        throwsFormatException,
      );
      expect(
        PortableProjectArchive.decode(archive().encode()).revisions,
        isEmpty,
      );
    },
  );

  test('historical decisions round trip without execution credentials', () {
    for (final approved in [false, true]) {
      final value = PortableProjectArchive(
        requirements: board(),
        messages: archive().messages,
        decision: PortablePlanDecision(
          content: 'Exact decision 😀\ntext',
          approved: approved,
          recordedAt: DateTime.utc(2026, 10, 26),
        ),
      );
      final decoded = PortableProjectArchive.decode(value.encode());
      expect(decoded.decision!.toJson(), value.decision!.toJson());
      expect(decoded.encode(), value.encode());
      expect(jsonDecode(value.encode())['version'], 2);
      expect(value.encode(), isNot(contains('planContext')));
      final mutations = <void Function(Map<String, dynamic>)>[
        (j) => j['decision']['context'] = 'credential',
        (j) => j['decision']['messageIndex'] = 0,
        (j) => j['decision']['approved'] = 'true',
        (j) => j['decision']['content'] = '',
        (j) => j['decision']['content'] = 'x' * 100001,
        (j) => j['decision']['recordedAt'] = '2026-02-31T00:00:00.000Z',
        (j) => j['decision']['recordedAt'] = '2026-10-26T00:00:00',
        (j) => j['decision'] = null,
        (j) => j['version'] = 1,
      ];
      for (final mutate in mutations) {
        final json = jsonDecode(value.encode()) as Map<String, dynamic>;
        mutate(json);
        expect(
          () => PortableProjectArchive.decode(jsonEncode(json)),
          throwsFormatException,
        );
      }
      expect(
        () => PortableProjectArchive.decode(
          value.encode().replaceFirst(
            '"approved":',
            '"approved":false,"approved":',
          ),
        ),
        throwsFormatException,
      );
    }
    expect(PortableProjectArchive.decode(archive().encode()).decision, isNull);
    expect(jsonDecode(archive().encode())['version'], 1);
  });

  test('round trip preserves exact board revision, dependencies, statuses and text', () {
    final original = archive();
    final decoded = PortableProjectArchive.decode(original.encode());
    expect(decoded.requirements.toJson(), original.requirements.toJson());
    expect(decoded.messages.map((m) => m.toJson()).toList(), [
      {'role': 'user', 'content': 'Keep exact\ntext 😀'},
      {'role': 'assistant', 'content': 'Plan'},
    ]);
    expect(decoded.encode(), original.encode());
    expect(() => decoded.messages.clear(), throwsUnsupportedError);
    expect(original.encode(), isNot(contains('secret-execution-context')));
    expect(original.encode(), isNot(contains('/private/path')));
  });

  test(
    'empty never-saved and empty saved boards retain distinct revisions',
    () {
      for (final revision in [0, 1, 12]) {
        final value = PortableProjectArchive(
          requirements: RequirementsBoard(revision: revision),
          messages: [],
        );
        expect(
          PortableProjectArchive.decode(value.encode()).requirements.revision,
          revision,
        );
      }
      expect(
        () => PortableProjectArchive(
          requirements: RequirementsBoard(requirements: board().requirements),
          messages: [],
        ),
        throwsFormatException,
      );
    },
  );

  test('unknown fields including settings and executable context refuse at every level', () {
    for (final field in [
      'project',
      'location',
      'settings',
      'approval',
      'buildPlan',
    ]) {
      final json = jsonDecode(archive().encode()) as Map<String, dynamic>;
      json[field] = 'unexpected';
      expect(
        () => PortableProjectArchive.decode(jsonEncode(json)),
        throwsFormatException,
      );
    }
    for (final location in ['board', 'requirement', 'task', 'message']) {
      final json = jsonDecode(archive().encode()) as Map<String, dynamic>;
      final requirements = json['requirements'] as Map<String, dynamic>;
      final target = switch (location) {
        'board' => requirements,
        'requirement' =>
          (requirements['requirements'] as List).first as Map<String, dynamic>,
        'task' => (requirements['tasks'] as List).first as Map<String, dynamic>,
        _ => (json['messages'] as List).first as Map<String, dynamic>,
      };
      target['planContext'] = 'credential';
      expect(
        () => PortableProjectArchive.decode(jsonEncode(json)),
        throwsFormatException,
      );
    }
  });

  test(
    'invalid versions, shapes, roles, graph and missing fields fail uniformly',
    () {
      for (final raw in ['[]', 'null', '{', '{}']) {
        expect(() => PortableProjectArchive.decode(raw), throwsFormatException);
      }
      final mutations = <void Function(Map<String, dynamic>)>[
        (j) => j['version'] = 2,
        // JavaScript JSON serialization erases the integral-double distinction.
        if (!kIsWeb) (j) => j['version'] = 1.0,
        (j) => j['version'] = 1.5,
        // JavaScript JSON serialization erases the integral-double distinction.
        if (!kIsWeb) (j) => j['requirements']['revision'] = 0.0,
        (j) => j['requirements']['revision'] = 0.5,
        // JavaScript JSON serialization erases the integral-double distinction.
        if (!kIsWeb) (j) => j['requirements']['version'] = 1.0,
        (j) => j['requirements']['version'] = 1.5,
        (j) => j['format'] = 'other',
        (j) => j.remove('messages'),
        (j) => j['messages'] = {},
        (j) => j['messages'] = [
          {'role': 'system', 'content': 'Instruction'},
        ],
        (j) => j['messages'] = [
          {'role': 'user', 'content': 1},
        ],
        (j) => j['requirements']['revision'] = -1,
        (j) => j['requirements']['version'] = 9,
        (j) => j['requirements']['requirements'][0]['acceptance'] = '',
        (j) => j['requirements']['tasks'][1]['dependencies'] = ['missing'],
        (j) => j['requirements']['tasks'][0]['dependencies'] = ['T2'],
        (j) => j['requirements']['tasks'][1]['status'] = 'unknown',
      ];
      for (final mutate in mutations) {
        final json = jsonDecode(archive().encode()) as Map<String, dynamic>;
        mutate(json);
        expect(
          () => PortableProjectArchive.decode(jsonEncode(json)),
          throwsFormatException,
        );
      }
    },
  );

  test('ambiguous members refuse at every depth including escaped keys', () {
    final encoded = archive().encode();
    final duplicates = [
      encoded.replaceFirst('"version":1', '"version":2,"version":1'),
      encoded.replaceFirst('"revision":7', '"revision":8,"revision":7'),
      encoded.replaceFirst(
        '"title":"Résumé"',
        '"title":"Other","title":"Résumé"',
      ),
      encoded.replaceFirst(
        '"status":"done"',
        '"status":"pending","status":"done"',
      ),
      encoded.replaceFirst('"role":"user"', '"role":"assistant","role":"user"'),
      encoded.replaceFirst('"content":', r'"co\u006etent":"lost","content":'),
      encoded.replaceFirst(
        '"format":',
        '"format":"asg-portable-records","format":',
      ),
    ];
    for (final raw in duplicates) {
      expect(raw, isNot(encoded));
      expect(() => PortableProjectArchive.decode(raw), throwsFormatException);
    }
  });

  test('separate objects and JSON-looking conversation text remain valid', () {
    final original = PortableProjectArchive(
      requirements: board(),
      messages: const [
        ChatMessage(
          role: 'user',
          content: r'{"version":1,"version":2}: \" quoted',
        ),
        ChatMessage(role: 'assistant', content: r'"content": { } [ ] \u0061'),
      ],
    );
    expect(
      PortableProjectArchive.decode(original.encode()).encode(),
      original.encode(),
    );
  });

  test('message and UTF8 aggregate limits apply on import and export', () {
    expect(
      () => PortableProjectArchive(
        requirements: RequirementsBoard(),
        messages: List.filled(
          1001,
          const ChatMessage(role: 'user', content: 'a'),
        ),
      ),
      throwsFormatException,
    );
    expect(
      () => PortableProjectArchive(
        requirements: RequirementsBoard(),
        messages: [ChatMessage(role: 'user', content: 'a' * 100001)],
      ),
      throwsFormatException,
    );
    final oversized = PortableProjectArchive(
      requirements: RequirementsBoard(),
      messages: List.filled(
        4,
        ChatMessage(role: 'assistant', content: '界' * 100000),
      ),
    );
    expect(oversized.encode, throwsFormatException);
    final json = jsonDecode(archive().encode()) as Map<String, dynamic>;
    json['messages'] = List.filled(4, {
      'role': 'user',
      'content': '界' * 100000,
    });
    expect(
      () => PortableProjectArchive.decode(jsonEncode(json)),
      throwsFormatException,
    );
    expect(
      () => PortableProjectArchive.decode(
        ' ' * (PortableProjectArchive.maxBytes + 1),
      ),
      throwsFormatException,
    );
  });
}
