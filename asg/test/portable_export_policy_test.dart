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
      '---- BEGIN SSH2 ENCRYPTED PRIVATE KEY ----',
      '-----BEGIN PGP PRIVATE KEY BLOCK-----',
      'PuTTY-User-Key-File-2: ssh-rsa',
      'PuTTY-User-Key-File-3: ssh-ed25519',
      '-----BEGIN PRIVATE KEY-----\nfixture',
      '-----BEGIN RSA PRIVATE KEY-----',
      '-----BEGIN ENCRYPTED PRIVATE KEY-----',
      '-----BEGIN OPENSSH PRIVATE KEY-----',
      'ghp_${'a' * 36}',
      'github_pat_${'b' * 30}',
      'sk-proj-${'c' * 30}',
      'AKIA${'D' * 16}',
      'Authorization: bEaReR abcdefgh.ijklmnop',
      for (var length = 1; length < 8; length++)
        'Authorization: Bearer ${'x' * length}',
      'bEaReR\tx=',
      'Bearer .',
      'Bearer _',
      'Bearer ~',
      'Bearer +/==',
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
      'token=fixture-value',
      'DB_PASSWORD=fixture-value',
      'dbPassword=fixture-value',
      'notpassword=dbPassword=fixture-value',
      'db2Password=fixture-value',
      '"serviceApiKey": " fixture-value"',
      "'appDatabasePwd' = '\tfixture-value'",
      'serviceToken=fixture-value',
      'appClientSecret=fixture-value',
      'servicePrivateKey=fixture-value',
      'dbPASSWORD=fixture-value',
      'serviceAPI_KEY=fixture-value',
      '"SERVICE_API_KEY": " fixture-value"',
      "'APP_DATABASE_PWD' = '\tfixture-value'",
      'SERVICE_TOKEN=fixture-value',
      'APP_CLIENT_SECRET=fixture-value',
      'SERVICE_PRIVATE_KEY=fixture-value',
      '"SECRET": " fixture-value"',
      "'Credential' = '\tfixture-value'",
      'private_key: fixture-value',
      '"Private-Key": " "',
      'privateKey=fixture-value',
      'private key=fixture-value',
      'api_token=fixture-value',
      '"AUTH_TOKEN": " fixture-value"',
      "'Api-Token' = '\tfixture-value'",
      'authToken: fixture-value',
      'api token: " "',
      'auth token=fixture-value',
      'id_token=fixture-value',
      '"ID_TOKEN": " fixture-value"',
      "'Id-Token' = '\tfixture-value'",
      'idToken: fixture-value',
      'id token: " "',
      'Server=localhost;UID=user;PWD=fixture-value;',
      '"passphrase": " fixture-value"',
      "'PwD' = '\tfixture-value'",
      'PASSPHRASE: fixture-value',
      'aws_secret_access_key=fixture-value',
      'AWS_SESSION_TOKEN=fixture-value',
      '"awsSecretAccessKey": " fixture-value"',
      "'Aws-Session-Token' = '\tfixture-value'",
      'aws secret access key: fixture-value',
      'aws session token: " "',
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
      'https://fixture-token@example.test/repository',
      'HTTP://fixture-token@example.test',
      'hTtPs://%66ixture-token@example.test',
      'https://fixture-token:@example.test',
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

  test(
    'XML credential values refuse while empty and ordinary tags stay exact',
    () {
      for (final name in [
        'password',
        'passwd',
        'pwd',
        'passphrase',
        'token',
        'secret',
        'credential',
        'privateKey',
        'api_key',
        'auth-token',
        'accessToken',
        'id_token',
        'refreshToken',
        'client-secret',
        'secret_key',
        'awsSecretAccessKey',
        'aws_session_token',
      ]) {
        for (final tag in [name, name.toUpperCase()]) {
          for (final text in [
            '<$tag>fixture-value</$tag>',
            '<$tag >\r\nfixture-value\r\n</$tag>',
            '<$tag> </$tag>',
            Uri.encodeComponent('<$tag>fixture-value</$tag>'),
          ]) {
            expect(
              () => PortableExportPolicy.requireExportable(withText(text)),
              throwsA(isA<PortableExportRefused>()),
            );
          }
          for (final text in ['<$tag></$tag>', '<$tag />', '<$tag/>']) {
            final archive = withText(text);
            final before = archive.encode();
            PortableExportPolicy.requireExportable(archive);
            expect(archive.encode(), before);
          }
        }
      }
      for (final text in [
        '<username>fixture-value</username>',
        '<passwordPolicy>strong</passwordPolicy>',
        'Use the password element for configuration',
        '&lt;password&gt;example&lt;/password&gt;',
      ]) {
        final archive = withText(text);
        final before = archive.encode();
        PortableExportPolicy.requireExportable(archive);
        expect(archive.encode(), before);
      }
    },
  );

  test(
    'nested XML credential content refuses while empty siblings stay exact',
    () {
      for (final text in [
        '<password><![CDATA[fixture-value]]></password>',
        '<cfg:token><value>fixture-value</value></cfg:token>',
        '<password><!--comment-->fixture-value</password>',
        '<password><value /></password>',
        '<password></token>fixture-value',
        '<cfg:password></other:password>fixture-value',
        '<password></PASSWORD>fixture-value',
        '<cfg:password hint="a>b"><![CDATA[fixture-value]]></cfg:password>',
        Uri.encodeComponent('<password><![CDATA[fixture-value]]></password>'),
      ]) {
        expect(
          () => PortableExportPolicy.requireExportable(withText(text)),
          throwsA(isA<PortableExportRefused>()),
        );
      }
      for (final text in [
        '<password></password><value>ordinary</value>',
        '<cfg:password hint="a>b"></cfg:password   >ordinary',
        '<password/><value>ordinary</value>',
        '<value><![CDATA[ordinary]]></value>',
        '<password></password>' * 4000,
      ]) {
        final archive = withText(text);
        final before = archive.encode();
        PortableExportPolicy.requireExportable(archive);
        expect(archive.encode(), before);
      }
    },
  );

  test('XML prefixes and quoted attributes cannot hide credential text', () {
    for (final text in [
      '<cfg:password>fixture-value</cfg:password>',
      '<password type="text">fixture-value</password>',
      '<cfg:API_KEY hint="a>b">fixture-value</cfg:API_KEY>',
      "<cfg:token note='a>b'>fixture-value</cfg:token>",
      '<ns:client-secret\n type="text" > fixture-value</ns:client-secret>',
      Uri.encodeComponent(
        '<cfg:password type="text">fixture-value</cfg:password>',
      ),
    ]) {
      expect(
        () => PortableExportPolicy.requireExportable(withText(text)),
        throwsA(isA<PortableExportRefused>()),
      );
    }
    for (final text in [
      '<cfg:password></cfg:password>',
      '<password type="text"></password>',
      '<cfg:password hint="a>b" />',
      '<password hint="a>b"/>',
      '<cfg:passwordPolicy type="text">strong</cfg:passwordPolicy>',
      '<cfg:username type="text">ordinary</cfg:username>',
      '<cfg:password',
      '<password hint="unterminated',
    ]) {
      final archive = withText(text);
      final before = archive.encode();
      PortableExportPolicy.requireExportable(archive);
      expect(archive.encode(), before);
    }
    final watch = Stopwatch()..start();
    PortableExportPolicy.requireExportable(withText('<password ' * 9000));
    PortableExportPolicy.requireExportable(
      withText('<cfg:password a="${'x' * 98000}'),
    );
    watch.stop();
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('one percent-encoded ASCII layer cannot hide credentials', () {
    for (final text in [
      'https://example.test?api%5Fkey=fixture-value',
      'https://example.test?%74oken%3Dfixture-value',
      '%41uthorization%3a%20Basic%20dTo=',
      '%41uthorization%3A%20Bearer%20fixture-value',
      'db%50assword%3Dfixture-value',
      'https%3a%2f%2ffixture-token%40example.test',
      '%ZZ % private%5Fkey%3Dfixture-value',
      'password=%22%20%22',
    ]) {
      expect(
        () => PortableExportPolicy.requireExportable(withText(text)),
        throwsA(isA<PortableExportRefused>()),
      );
    }
    for (final text in [
      'https://example.test?q=hello%20world&name=%E4%B8%AD',
      'An encoded percentage: 100%25 and malformed %ZZ',
      'api%5Fkey=',
      'token%3D%22%22',
      'Use the password%20input',
    ]) {
      final archive = withText(text);
      final before = archive.encode();
      PortableExportPolicy.requireExportable(archive);
      expect(archive.encode(), before);
    }
  });

  test('clean prose, Unicode and separate fields remain exact', () {
    for (final text in [
      'Use SSH2 encrypted private key files',
      '---- BEGIN SSH2 PUBLIC KEY ----\nZml4dHVyZQ==\n---- END SSH2 PUBLIC KEY ----',
      'Use PGP private key blocks for secret keys',
      '-----BEGIN PGP PUBLIC KEY BLOCK-----\nZml4dHVyZQ==',
      '-----BEGIN PGP SIGNATURE-----',
      '-----BEGIN PGP MESSAGE-----',
      '-----BEGIN PGP SIGNED MESSAGE-----',
      'Use PuTTY PPK version 2 or 3 for private key files',
      'PuTTY-User-Key-File-3',
      'ssh-ed25519 Zml4dHVyZQ== public-key@example.test',
      '---- BEGIN SSH2 PUBLIC KEY ----',
      'Add a password input and API key settings',
      'https://example.test/docs and user@example.test',
      '-----BEGIN PUBLIC KEY-----',
      'An access token is needed. 中文 😀',
      'Bearer',
      'Use token, secret, credential and private_key fields',
      'token=',
      'DB_PASSWORD=',
      'dbPassword=',
      'serviceApiKey: ""',
      "appDatabasePwd = ''",
      'Use dbPassword and serviceApiKey fields',
      'SERVICE_API_KEY: ""',
      "APP_DATABASE_PWD = ''",
      'Use DB_PASSWORD and SERVICE_API_KEY fields',
      'notpassword=ordinary',
      'SECRET: ""',
      "credential = ''",
      'private_key:',
      'Private-Key: ""',
      "privateKey = ''",
      'Basic application settings and basic authentication',
      'Authorization: Basic',
      'Authorization: " Basic"',
      "Proxy-Authorization: ' \t '",
      'Basic dXNlcjpwYXNz',
      'AWS configuration uses aws_secret_access_key and aws_session_token',
      'aws_secret_access_key=',
      'aws_session_token: ""',
      "awsSecretAccessKey = ''",
      'Use pwd and passphrase fields for credentials',
      'Use id_token for the identity token',
      'Use api_token and auth_token for authentication',
      'api_token=',
      'authToken: ""',
      "API-TOKEN = ''",
      'id_token=',
      'idToken: ""',
      "ID-TOKEN = ''",
      'pwd=',
      'passphrase: ""',
      "PWD = ''",
      'password:',
      'password: ""',
      "api_key = ''",
      'redis://:@localhost/0',
      'redis://user:@localhost/0',
      'redis://localhost:6379/0',
      'https://example.test/path/:fixture-value@host',
      'https://@example.test',
      'https://example.test?next=user:label@destination',
      'https://example.test#user:label@destination',
      'https://example.test/path/token@destination',
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
