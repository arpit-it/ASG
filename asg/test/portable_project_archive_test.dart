import 'dart:convert';

import 'package:asg/models/chat_message.dart';
import 'package:asg/models/portable_project_archive.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:flutter_test/flutter_test.dart';

RequirementsBoard board() => RequirementsBoard(
  revision: 7,
  requirements: const [
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
        (j) => j['version'] = 1.0,
        (j) => j['requirements']['revision'] = 0.0,
        (j) => j['requirements']['version'] = 1.0,
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
