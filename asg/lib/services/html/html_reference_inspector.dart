// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html;

import '../../models/html/html_reference_report.dart';
import '../../models/html/html_source_proposal.dart';

/// Bounded immutable proposal analysis. Native parsing runs off the UI isolate;
/// web compute runs synchronously on the already size-bounded proposal.
Future<HtmlReferenceReport> inspectHtmlReferences(
  HtmlSourceProposal proposal,
) => compute(_inspect, proposal);

HtmlReferenceReport _inspect(HtmlSourceProposal proposal) {
  final parser = html.HtmlParser(proposal.files['index.html']!);
  final document = parser.parse();
  final elements = document.querySelectorAll('*');
  final ids = <String>{};
  final messages = <String>[];
  var findings = 0, references = 0;
  void report(String message) {
    findings++;
    if (messages.length < 100) messages.add(message);
  }

  if (parser.errors.isNotEmpty) {
    report(
      'HTML parser recovered ${parser.errors.length} parse errors; inspect the source.',
    );
  }
  final hasBase = elements.any((element) => element.localName == 'base');
  if (hasBase) {
    report(
      'A base element changes URL resolution; local targets were not resolved.',
    );
  }
  for (final element in elements) {
    final id = element.attributes['id'];
    if (id != null && id.isNotEmpty && !ids.add(id)) {
      report('Duplicate HTML ID: ${_label(id)}');
    }
  }
  final base = Uri.parse('https://proposal.invalid/');
  for (final element in elements) {
    for (final attribute in ['href', 'src', 'action', 'poster', 'data']) {
      final value = element.attributes[attribute];
      if (value == null) continue;
      references++;
      final label = '${element.localName}[$attribute] ${_label(value)}';
      final uri = Uri.tryParse(value.trim());
      if (uri == null || value.contains('\\')) {
        report('Invalid or unsupported reference: $label');
        continue;
      }
      if (uri.hasScheme || uri.hasAuthority) {
        report('External or scheme reference needs separate review: $label');
        continue;
      }
      if (hasBase) continue;
      try {
        final resolved = base.resolveUri(uri);
        final name = Uri.decodeComponent(resolved.path.substring(1));
        final target = name.isEmpty ? 'index.html' : name;
        if (!proposal.files.containsKey(target)) {
          report('Missing local target: $label');
        } else if (resolved.hasFragment && resolved.fragment.isNotEmpty) {
          if (target != 'index.html') {
            report('Non-HTML fragment not checked: $label');
          } else if (!ids.contains(Uri.decodeComponent(resolved.fragment))) {
            report('Missing HTML fragment: $label');
          }
        }
        if (resolved.hasQuery) {
          report('Query behavior needs browser verification: $label');
        }
      } on FormatException {
        report('Invalid encoded reference: $label');
      }
    }
  }
  return HtmlReferenceReport(
    elements: elements.length,
    references: references,
    findings: findings,
    messages: messages,
  );
}

String _label(String value) {
  // Bound display size and suppress controls, while keeping source as plain text.
  final text = value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ');
  return text.length > 120 ? '${text.substring(0, 120)}…' : text;
}
