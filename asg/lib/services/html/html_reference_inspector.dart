// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:csslib/parser.dart' as css;
import 'package:csslib/visitor.dart' as css;
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
  void inspectReference(String value, String label, {required bool inline}) {
    references++;
    final uri = Uri.tryParse(value.trim());
    if (uri == null || value.contains('\\')) {
      report('Invalid or unsupported reference: $label');
      return;
    }
    if (uri.hasScheme || uri.hasAuthority) {
      report('External or scheme reference needs separate review: $label');
      return;
    }
    if (inline && hasBase) return;
    try {
      final origin = inline ? base : base.resolve('styles.css');
      final resolved = origin.resolveUri(uri);
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

  void inspectCss(String source, String location, {required bool inline}) {
    final errors = <css.Message>[];
    final tree = css.parse(source, errors: errors);
    if (errors.isNotEmpty) {
      report(
        'CSS parser reported ${errors.length} diagnostics in $location; '
        'inspect the source. Recovered references may be incomplete.',
      );
    }
    tree.visit(
      _CssReferences(
        (value) {
          inspectReference(value, '$location ${_label(value)}', inline: inline);
        },
        () => report(
          'CSS filter declaration in $location is not inspected by this parser.',
        ),
      ),
    );
  }

  for (final element in elements) {
    for (final attribute in ['href', 'src', 'action', 'poster', 'data']) {
      final value = element.attributes[attribute];
      if (value == null) continue;
      inspectReference(
        value,
        '${element.localName}[$attribute] ${_label(value)}',
        inline: true,
      );
    }
    if (element.localName == 'style') {
      inspectCss(element.text, 'style element', inline: true);
    }
    final style = element.attributes['style'];
    if (style != null) {
      // Parse declarations in a rule wrapper; recovery is advisory only.
      inspectCss('x{$style}', '${element.localName}[style]', inline: true);
    }
  }
  inspectCss(proposal.files['styles.css']!, 'styles.css', inline: false);
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

/// Comments and ordinary quoted strings are not URL references.
class _CssReferences extends css.Visitor {
  _CssReferences(this.onReference, this.onFilter);
  final void Function(String) onReference;
  final void Function() onFilter;

  @override
  void visitDeclaration(css.Declaration node) {
    if (node.property.toLowerCase().replaceFirst('*', '') == 'filter') {
      onFilter();
    }
    super.visitDeclaration(node);
  }

  @override
  void visitUriTerm(css.UriTerm node) => onReference(node.text);

  @override
  void visitImportDirective(css.ImportDirective node) {
    final value = node.import;
    final quoted =
        value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")));
    onReference(quoted ? value.substring(1, value.length - 1) : value);
    super.visitImportDirective(node);
  }
}
