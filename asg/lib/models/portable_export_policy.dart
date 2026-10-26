import 'dart:convert';

import 'portable_project_archive.dart';

/// Refuses recognizable credential patterns without rewriting portable data.
/// This bounded guard is not proof that arbitrary free text contains no secrets.
class PortableExportPolicy {
  static final _patterns = <RegExp>[
    RegExp(r'-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----'),
    // OpenPGP secret-key armor includes BLOCK after PRIVATE KEY (RFC 9580).
    RegExp(r'-----BEGIN PGP PRIVATE KEY BLOCK-----'),
    // ssh.com SSH2 private-key armor uses four dashes and separating spaces.
    RegExp(r'---- BEGIN SSH2 ENCRYPTED PRIVATE KEY ----'),
    // PuTTY PPK keys use a versioned signature rather than PEM delimiters.
    RegExp(r'\bPuTTY-User-Key-File-[23]:'),
    // XML settings use element content rather than assignment delimiters.
    // Inspect text after a credential tag; this is not a general XML parser.
    RegExp(
      r'<(?:aws[_ -]?(?:secret[_ -]?access[_ -]?key|session[_ -]?token)|password|passwd|pwd|passphrase|token|secret|credential|private[_ -]?key|api[_ -]?(?:key|token)|auth[_ -]?token|access[_ -]?token|id[_ -]?token|refresh[_ -]?token|client[_ -]?secret|secret[_ -]?key)\s*>[^<]',
      caseSensitive: false,
    ),
    RegExp(
      r'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|(?:AKIA|ASIA)[A-Z0-9]{16})\b',
    ),
    RegExp(
      r'''\b(?:proxy-)?authorization["']?\s*[:=]\s*(?:["']\s*)?basic\s+[A-Za-z0-9+/]{2,}={0,2}''',
      caseSensitive: false,
    ),
    RegExp(r'\bBearer\s+[A-Za-z0-9._~+/-]+=*', caseSensitive: false),
    RegExp(
      r'''(?:\b|_)(?:aws[_ -]?(?:secret[_ -]?access[_ -]?key|session[_ -]?token)|password|passwd|pwd|passphrase|token|secret|credential|private[_ -]?key|api[_ -]?(?:key|token)|auth[_ -]?token|access[_ -]?token|id[_ -]?token|refresh[_ -]?token|client[_ -]?secret|secret[_ -]?key)["']?\s*[:=]\s*(?:"[^"]|'[^']|[^\s"',;}{<>]+)''',
      caseSensitive: false,
    ),
  ];

  // Camel-case prefixes have no word boundary. Require a lower-case/digit
  // to upper-case transition in the original text, preserving ordinary words.
  static final _camelAssignment = RegExp(
    r'''[a-z0-9](?:aws[_ -]?(?:secret[_ -]?access[_ -]?key|session[_ -]?token)|password|passwd|pwd|passphrase|token|secret|credential|private[_ -]?key|api[_ -]?(?:key|token)|auth[_ -]?token|access[_ -]?token|id[_ -]?token|refresh[_ -]?token|client[_ -]?secret|secret[_ -]?key)["']?\s*[:=]\s*(?=(?:"[^"]|'[^']|[^\s"',;}{<>]+))''',
    caseSensitive: false,
  );

  static bool _hasCamelAssignment(String text) =>
      _camelAssignment.allMatches(text).any((match) {
        final prefix = text.codeUnitAt(match.start);
        final initial = text.codeUnitAt(match.start + 1);
        return ((prefix >= 97 && prefix <= 122) ||
                (prefix >= 48 && prefix <= 57)) &&
            initial >= 65 &&
            initial <= 90;
      });

  static final _schemeCharacter = RegExp(r'[A-Za-z0-9+.-]');
  static final _schemeStart = RegExp(r'[A-Za-z]');
  static final _space = RegExp(r'\s');

  static bool _hasCredentialUrl(String text) {
    // Locate separators first. Scheme and authority scans cannot cross another
    // separator, so dotted schemes and repeated colons are scanned only once.
    for (final separator in '://'.allMatches(text)) {
      var start = separator.start;
      while (start > 0 && _schemeCharacter.hasMatch(text[start - 1])) {
        start--;
      }
      if (start == separator.start || !_schemeStart.hasMatch(text[start])) {
        continue;
      }
      final scheme = text.substring(start, separator.start).toLowerCase();
      final http = scheme == 'http' || scheme == 'https';
      final authorityStart = separator.end;
      var colon = -1;
      for (var i = authorityStart; i < text.length; i++) {
        final char = text[i];
        if (char == '/' ||
            char == '?' ||
            char == '#' ||
            _space.hasMatch(char)) {
          break;
        }
        if (char == '@') {
          // HTTP user-info may itself be a Git access token, even without
          // a password delimiter. Other schemes retain password-only support.
          if (http && i > authorityStart) return true;
          if (colon >= authorityStart && i > colon + 1) return true;
          break;
        }
        if (char == ':' && colon < 0) colon = i;
      }
    }
    return false;
  }

  static final _asciiEscape = RegExp(r'%([0-7][0-9A-Fa-f])');

  static bool _hasCredential(String text) =>
      _patterns.any((pattern) => pattern.hasMatch(text)) ||
      _hasCredentialUrl(text) ||
      _hasCamelAssignment(text);

  static bool _hasEncodedCredential(String text) {
    // Inspect exactly one encoding layer; retain the original archive verbatim.
    // Decode ASCII individually so malformed escapes and encoded Unicode do
    // not mask adjacent credential syntax or cause a decoding exception.
    final decoded = text.replaceAllMapped(
      _asciiEscape,
      (match) => String.fromCharCode(int.parse(match[1]!, radix: 16)),
    );
    return decoded != text && _hasCredential(decoded);
  }

  static void requireExportable(PortableProjectArchive archive) {
    // Scan decoded values rather than JSON syntax: escaped whitespace/quotes
    // must not hide credentials, and field boundaries must remain separate.
    _inspect(jsonDecode(archive.encode()));
  }

  static void _inspect(Object? value) {
    if (value is String) {
      if (_hasCredential(value) || _hasEncodedCredential(value)) {
        throw const PortableExportRefused();
      }
    } else if (value is List) {
      for (final item in value) {
        _inspect(item);
      }
    } else if (value is Map) {
      for (final item in value.values) {
        _inspect(item);
      }
    }
  }
}

/// Carries no matching text, field values or original exception details.
class PortableExportRefused implements Exception {
  const PortableExportRefused();

  static const message =
      'Export blocked: saved text matches a credential pattern. '
      'Review credentials in conversations, requirements, tasks, prototype '
      'and historical Plan text before retrying. Saved records are unchanged.';

  @override
  String toString() => message;
}
