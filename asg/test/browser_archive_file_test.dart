@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:asg/controllers/portable_archive_controller.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/models/chat_message.dart';
import 'package:asg/models/portable_project_archive.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/services/archive_file_service.dart';
import 'package:flutter_test/flutter_test.dart';

@JS('document.querySelector')
external JSObject? querySelector(JSString selector);

@JS('fetch')
external JSPromise<JSObject> fetchBlob(JSString url);

class BrowserRecords implements ConditionalRecordStorage {
  final values = <String, String>{};
  @override
  String? getString(String key) => values[key];
  @override
  Future<bool> setString(String key, String value) async {
    values[key] = value;
    return true;
  }

  @override
  Future<void> commitRecords({
    required Map<String, String?> expected,
    required Map<String, String> updates,
    required void Function() authorize,
  }) async => throw StateError('Export must not write');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('browser download contains exact validated portable bytes', () async {
    final files = ArchiveFileService();
    expect(files.canExport, isTrue);
    expect(files.exportButtonLabel, 'Download archive file');
    expect(files.exportSuccessMessage, contains('Download requested'));
    expect(files.exportSuccessMessage, contains('confirm'));
    final encoded = PortableProjectArchive(
      requirements: RequirementsBoard(),
      messages: const [ChatMessage(role: 'user', content: 'Backup 中文 😀')],
    ).encode();
    expect(await files.export(encoded), isTrue);
    final anchor = querySelector('#__x_file_dom_element a'.toJS)!;
    expect(
      anchor.getProperty<JSString>('download'.toJS).toDart,
      'asg-records.json',
    );
    final href = anchor.getProperty<JSString>('href'.toJS);
    expect(href.toDart, startsWith('blob:'));
    final response = await fetchBlob(href).toDart;
    final text = await response
        .callMethod<JSPromise<JSString>>('text'.toJS)
        .toDart;
    expect(text.toDart, encoded);
    expect(
      PortableProjectArchive.decode(text.toDart).messages.single.content,
      'Backup 中文 😀',
    );
    final records = BrowserRecords();
    final controller = PortableArchiveController('web', records);
    addTearDown(controller.dispose);
    await ConversationStore(
      records,
    ).save('web', const [ChatMessage(role: 'user', content: 'Backup 中文 😀')]);
    await controller.prepareExport();
    await controller.exportFile();
    expect(controller.error, isNull);
    expect(controller.status, files.exportSuccessMessage);
    expect(controller.exportContents, encoded);
    final previousHref = querySelector('#__x_file_dom_element a'.toJS)!
        .getProperty<JSString>('href'.toJS)
        .toDart;
    await ConversationStore(records).save('web', const [
      ChatMessage(role: 'user', content: 'password=fixture-value'),
    ]);
    final before = Map.of(records.values);
    await controller.prepareExport();
    expect(controller.exportPreview, isNull);
    expect(controller.error, contains('Export blocked'));
    await controller.exportFile();
    expect(
      querySelector('#__x_file_dom_element a'.toJS)!
          .getProperty<JSString>('href'.toJS)
          .toDart,
      previousHref,
    );
    expect(records.values, before);
    await expectLater(files.export('{broken'), throwsFormatException);
    expect(
      querySelector('#__x_file_dom_element a'.toJS)!
          .getProperty<JSString>('href'.toJS)
          .toDart,
      previousHref,
    );
    await controller.redactExport('password=fixture-value');
    expect(controller.error, isNull);
    expect(controller.exportReviewContents, isNot(contains('fixture-value')));
    await controller.exportFile();
    final redactedHref = querySelector('#__x_file_dom_element a'.toJS)!
        .getProperty<JSString>('href'.toJS);
    final redactedResponse = await fetchBlob(redactedHref).toDart;
    final redactedText = await redactedResponse
        .callMethod<JSPromise<JSString>>('text'.toJS)
        .toDart;
    expect(redactedText.toDart, controller.exportReviewContents);
    expect(
      PortableProjectArchive.decode(redactedText.toDart)
          .messages
          .single
          .content,
      '[redacted]',
    );
    expect(records.values, before);
  });
}
