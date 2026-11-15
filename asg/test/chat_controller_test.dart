// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:asg/controllers/chat_controller.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/model_provider.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_diagnostics_test.dart' show project;
import 'model_request_provenance_test.dart' show Records;

class _Reply implements ModelResponseIdentityProvider {
  @override
  String? completedResponseModel;

  @override
  Stream<String> generate(String prompt) async* {
    yield 'A completed reply';
    completedResponseModel = 'reported-model';
  }

  @override
  Future<void> cancel() async {
    completedResponseModel = null;
  }
}

void main() {
  test(
    'completed project reply saves server identity before cleanup',
    () async {
      final records = Records();
      await ModelSettingsStore(records)
          .save(const LocalModelConfig(model: 'requested-model'));
      final provider = _Reply();
      ChatController openChat() => ChatController(
        project,
        openStore: () async => ConversationStore(records),
        createProvider: (_) => provider,
      );
      final chat = openChat();
      addTearDown(chat.dispose);
      await chat.load();
      await chat.send('A project question');
      expect(provider.completedResponseModel, isNull);

      final reopened = openChat();
      addTearDown(reopened.dispose);
      await reopened.load();
      final provenance = reopened.messages.last.modelRequest!;
      expect(provenance.model, 'requested-model');
      expect(provenance.responseModel, 'reported-model');
      expect(
        provenance.description,
        contains('Server-reported model: reported-model'),
      );
    },
  );
}
