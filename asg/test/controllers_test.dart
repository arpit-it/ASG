import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asg/controllers/chat_controller.dart';
import 'package:asg/controllers/dashboard_controller.dart';
import 'package:asg/controllers/project_wizard_controller.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/model_provider.dart';
import 'package:asg/services/studio_store.dart';
import 'package:asg/models/project.dart';

const project = StudioProject(
  id: 'mvc',
  name: 'Planner',
  description: 'Tasks',
  type: 'Flutter',
  platforms: ['macOS'],
  location: '',
);

class FakeProvider implements ModelProvider {
  FakeProvider(this.reply);
  final Future<String> reply;
  bool cancelled = false;
  @override
  Stream<String> generate(String prompt) async* {
    yield await reply;
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
  }
}

class FailingStore extends StudioStore {
  FailingStore(super.preferences) : super.fromPreferences();
  @override
  Future<void> save(List<StudioProject> projects) async =>
      throw StateError('Disk unavailable');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('dashboard publishes a project only after successful save', () async {
    final controller = DashboardController(
      FailingStore(await SharedPreferences.getInstance()),
      [],
    );
    expect(await controller.add(project), false);
    expect(controller.projects, isEmpty);
    expect(controller.error, contains('Disk unavailable'));
    expect(controller.busy, false);
    controller.dispose();
  });
  test('wizard validates names and requires platforms', () {
    final controller = ProjectWizardController();
    expect(ProjectWizardController.validateName('example'), isNull);
    expect(controller.create('../escape', ''), isNull);
    expect(controller.create('folder\\escape', ''), isNull);
    controller.selectPlatform('macOS', false);
    expect(controller.create('Planner', ''), isNull);
    controller.selectPlatform('Web', true);
    expect(controller.create(' Planner ', '')!.name, 'Planner');
    controller.dispose();
  });
  test('chat controller saves both messages through repository', () async {
    final store = ConversationStore.fromPreferences(
      await SharedPreferences.getInstance(),
    );
    final provider = FakeProvider(Future.value('Let us define requirements.'));
    final controller = ChatController(
      project,
      openStore: () async => store,
      createProvider: (_) => provider,
    );
    await controller.load();
    expect(await controller.send('Build a planner'), true);
    expect(store.load(project.id).map((m) => m.role), ['user', 'assistant']);
    expect(controller.messages.last.content, 'Let us define requirements.');
    expect(provider.cancelled, true);
    controller.dispose();
  });
  test(
    'failed inference preserves user message and releases busy state',
    () async {
      final store = ConversationStore.fromPreferences(
        await SharedPreferences.getInstance(),
      );
      final controller = ChatController(
        project,
        openStore: () async => store,
        createProvider: (_) => FakeProvider(
          Future<String>.delayed(
            Duration.zero,
            () => throw StateError('Offline'),
          ),
        ),
      );
      await controller.load();
      await controller.send('Hello');
      expect(store.load(project.id).single.content, 'Hello');
      expect(controller.error, contains('model request failed'));
      expect(controller.error, isNot(contains('Offline')));
      expect(controller.busy, false);
      controller.dispose();
    },
  );
  test('disposing during inference prevents reply persistence', () async {
    final store = ConversationStore.fromPreferences(
      await SharedPreferences.getInstance(),
    );
    final reply = Completer<String>();
    final provider = FakeProvider(reply.future);
    final controller = ChatController(
      project,
      openStore: () async => store,
      createProvider: (_) => provider,
    );
    await controller.load();
    final sending = controller.send('Hello');
    await Future<void>.delayed(Duration.zero);
    controller.dispose();
    reply.complete('Late response');
    await sending;
    expect(store.load(project.id), hasLength(1));
    expect(provider.cancelled, true);
  });
}
