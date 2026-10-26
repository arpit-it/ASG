import 'package:asg/models/chat_message.dart';
import 'package:asg/models/portable_export_policy.dart';
import 'package:asg/models/portable_project_archive.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:flutter_test/flutter_test.dart';

PortableProjectArchive withText(String text) => PortableProjectArchive(
  requirements: RequirementsBoard(),
  messages: [ChatMessage(role: 'user', content: text)],
);

void main() {
  test('recognized credential forms refuse without exposing text', () {
    final fixtures = [
      '-----BEGIN PRIVATE KEY-----\nfixture',
      '-----BEGIN RSA PRIVATE KEY-----',
      '-----BEGIN ENCRYPTED PRIVATE KEY-----',
      '-----BEGIN OPENSSH PRIVATE KEY-----',
      'ghp_${'a' * 36}',
      'github_pat_${'b' * 30}',
      'sk-proj-${'c' * 30}',
      'AKIA${'D' * 16}',
      'Authorization: bEaReR abcdefgh.ijklmnop',
      'Authorization: Basic dXNlcjpwYXNz',
      'Authorization: " Basic dXNlcjpwYXNz"',
      "'Proxy-Authorization' = '\t bAsIc dTo='",
      '"AUTHORIZATION": "\n\tBasic Og=="',
      'proxy-authorization: bAsIc dTo=',
      '"AUTHORIZATION": "Basic Og=="',
      "'Authorization' = 'Basic dXNlcjpwYXNz'",
      'Authorization:\tBasic\tdXNlcjpwYXNz',
      '"password": "fixture-value"',
      "'api_key' = 'fixture-value'",
      'CLIENT_SECRET=fixture-value',
      'password: " fixture-value"',
      "passwd = '\tfixture-value'",
      '"API_KEY": "\nfixture-value"',
      'client-secret: " "',
      "secret_key='\t\n'",
      "password: \"'\"",
      "password: '\"'",
      'refresh-token: fixture-value',
      'https://user:fixture-value@example.test/path',
      'postgres://user:fixture-value@localhost/db',
      'redis://:fixture-value@localhost/0',
      'REDISS://:%70%61%73%73@localhost',
      'custom+scheme://:fixture-value@example.test',
    ];
    for (final text in fixtures) {
      expect(
        () => PortableExportPolicy.requireExportable(withText(text)),
        throwsA(
          isA<PortableExportRefused>().having(
            (error) => error.toString(),
            'safe message',
            isNot(contains(text)),
          ),
        ),
        reason: 'Fixture index ${fixtures.indexOf(text)}',
      );
    }
  });

  test('clean prose, Unicode and separate fields remain exact', () {
    for (final text in [
      'Add a password input and API key settings',
      'https://example.test/docs and user@example.test',
      '-----BEGIN PUBLIC KEY-----',
      'An access token is needed. 中文 😀',
      'Bearer',
      'Basic application settings and basic authentication',
      'Authorization: Basic',
      'Authorization: " Basic"',
      "Proxy-Authorization: ' \t '",
      'Basic dXNlcjpwYXNz',
      'password:',
      'password: ""',
      "api_key = ''",
      'redis://:@localhost/0',
      'redis://user:@localhost/0',
      'redis://localhost:6379/0',
      'https://example.test/path/:fixture-value@host',
      '{"count":1,"count":2}',
    ]) {
      final archive = withText(text);
      final before = archive.encode();
      PortableExportPolicy.requireExportable(archive);
      expect(archive.encode(), before);
    }
    final split = PortableProjectArchive(
      requirements: RequirementsBoard(),
      messages: const [
        ChatMessage(role: 'user', content: 'Bearer'),
        ChatMessage(role: 'assistant', content: 'abcdefghijk'),
      ],
    );
    PortableExportPolicy.requireExportable(split);
  });

  test('long nonmatching URL authority remains responsive', () {
    final archive = withText('https://${'a:' * 49000}');
    final watch = Stopwatch()..start();
    PortableExportPolicy.requireExportable(archive);
    PortableExportPolicy.requireExportable(withText('a.' * 49000));
    PortableExportPolicy.requireExportable(
      withText('Authorization:${' ' * 98000}incomplete'),
    );
    PortableExportPolicy.requireExportable(
      withText('Authorization: "${' ' * 98000}incomplete"'),
    );
    watch.stop();
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    expect(
      () => PortableExportPolicy.requireExportable(
        withText('https://user:${'a:' * 48000}@example.test'),
      ),
      throwsA(isA<PortableExportRefused>()),
    );
  });

  test('JSON escapes are decoded before inspecting credential patterns', () {
    final encoded = withText('password: fixture-value')
        .encode()
        .replaceFirst('password', r'pass\u0077ord')
        .replaceFirst(': fixture', r':\tfixture');
    final archive = PortableProjectArchive.decode(encoded);
    expect(
      () => PortableExportPolicy.requireExportable(archive),
      throwsA(isA<PortableExportRefused>()),
    );
    // Import remains data-only and readable; no irreversible redaction occurs.
    expect(archive.messages.single.content, 'password:\tfixture-value');
  });
}
