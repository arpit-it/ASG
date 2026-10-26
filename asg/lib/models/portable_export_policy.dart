import 'dart:convert';

import 'portable_project_archive.dart';

/// Refuses recognizable credential patterns without rewriting portable data.
/// This bounded guard is not proof that arbitrary free text contains no secrets.
class PortableExportPolicy {
  static final _patterns = <RegExp>[
    RegExp(r'-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----'),
    RegExp(
      r'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|(?:AKIA|ASIA)[A-Z0-9]{16})\b',
    ),
    RegExp(r'\bBearer\s+[A-Za-z0-9._~+/-]{8,}=*', caseSensitive: false),
    RegExp(
      r'''\b(?:password|passwd|api[_ -]?key|access[_ -]?token|refresh[_ -]?token|client[_ -]?secret|secret[_ -]?key)["']?\s*[:=]\s*["']?[^\s"',;}{<>]{1,}''',
      caseSensitive: false,
    ),
    RegExp(r'\b[a-z][a-z0-9+.-]*://[^\s/@]+:[^\s/@]+@', caseSensitive: false),
  ];

  static void requireExportable(PortableProjectArchive archive) {
    // Scan decoded values rather than JSON syntax: escaped whitespace/quotes
    // must not hide credentials, and field boundaries must remain separate.
    _inspect(jsonDecode(archive.encode()));
  }

  static void _inspect(Object? value) {
    if (value is String) {
      if (_patterns.any((pattern) => pattern.hasMatch(value))) {
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
