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
