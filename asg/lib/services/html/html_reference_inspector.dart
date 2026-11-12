// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:csslib/parser.dart' as css;
import 'package:csslib/visitor.dart' as css;
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import '../../models/html/html_reference_report.dart';
import '../../models/html/html_source_proposal.dart';
import 'html_srcset_references.dart';

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
  final navigationNames = <String>{};
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
  final hasBase = elements.any(
    (element) =>
        element.namespaceUri == 'http://www.w3.org/1999/xhtml' &&
        element.localName == 'base' &&
        element.attributes.containsKey('href') &&
        !_insideTemplate(element),
  );
  if (hasBase) {
    report(
      'A base element changes URL resolution; local targets were not resolved.',
    );
  }
  for (final element in elements) {
    // The parser exposes template contents in this traversal, but those nodes
    // belong to an inert fragment, outside the document's target/ID inventory.
    // The template element itself can still be a live target.
    if (_insideTemplate(element)) continue;
    if (element.namespaceUri == 'http://www.w3.org/1999/xhtml' &&
        element.localName == 'a') {
      final name = element.attributes['name'];
      if (name != null && name.isNotEmpty) navigationNames.add(name);
    }
    final id = element.attributes['id'];
    if (id != null && id.isNotEmpty && !ids.add(id)) {
      report('Duplicate HTML ID: ${_label(id)}');
    }
  }
  final base = Uri.parse('https://proposal.invalid/');
  void inspectReference(
    String value,
    String label, {
    required bool inline,
    bool navigation = false,
  }) {
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
        } else if (!ids.contains(Uri.decodeComponent(resolved.fragment)) &&
            !(navigation &&
                (navigationNames.contains(
                      Uri.decodeComponent(resolved.fragment),
                    ) ||
                    Uri.decodeComponent(resolved.fragment).toLowerCase() ==
                        'top'))) {
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

  void inspectSvgPresentation(String value, String location) {
    // The CSS parser recurses into functions and rules. Count possible
    // openings conservatively, including ones in malformed values.
    if (RegExp(r'[({\[]').allMatches(value).take(65).length > 64) {
      report('SVG presentation value is too complex to inspect: $location');
      return;
    }
    // Parse a single value with a neutral property so csslib does not treat
    // SVG filter values as legacy CSS filter declarations.
    final errors = <css.Message>[];
    final tree = css.parse('x{svg-presentation:$value}', errors: errors);
    final rule = tree.topLevels.singleOrNull;
    final declaration = rule is css.RuleSet
        ? rule.declarationGroup.declarations.singleOrNull
        : null;
    if (errors.isNotEmpty ||
        declaration is! css.Declaration ||
        declaration.property != 'svg-presentation' ||
        declaration.important) {
      report('SVG presentation value could not be inspected: $location');
      return;
    }
    declaration.expression?.visit(
      _CssReferences(
        (reference) => inspectReference(
          reference,
          '$location ${_label(reference)}',
          inline: true,
        ),
      ),
    );
  }

  final idSeparators = RegExp(r'[\t\n\f\r ]+');
  for (final element in elements) {
    if (element.namespaceUri == 'http://www.w3.org/1999/xhtml' &&
        element.localName == 'label' &&
        !_insideTemplate(element)) {
      final target = element.attributes['for'];
      if (target != null) {
        references++;
        if (!ids.contains(target)) {
          final label = target.isEmpty ? '(empty)' : _label(target);
          report('Missing HTML label target: label[for] $label');
        }
      }
    }
    if (element.namespaceUri == 'http://www.w3.org/1999/xhtml' &&
        element.localName == 'input' &&
        !_insideTemplate(element)) {
      final target = element.attributes['list'];
      if (target != null) {
        references++;
        if (!ids.contains(target)) {
          final label = target.isEmpty ? '(empty)' : _label(target);
          report('Missing HTML datalist target: input[list] $label');
        }
      }
    }
    if (!_insideTemplate(element) &&
        element.namespaceUri == 'http://www.w3.org/1999/xhtml' &&
        (element.localName == 'td' || element.localName == 'th')) {
      final value = element.attributes['headers'];
      if (value != null) {
        for (final target in value.split(idSeparators)) {
          if (target.isEmpty) continue;
          references++;
          if (!ids.contains(target)) {
            report(
              'Missing HTML table header target: headers ${_label(target)}',
            );
          }
        }
      }
    }
    if (!_insideTemplate(element)) {
      for (final attribute in const [
        'aria-labelledby',
        'aria-describedby',
        'aria-controls',
        'aria-errormessage',
        'aria-owns',
        'aria-details',
        'aria-flowto',
      ]) {
        final value = element.attributes[attribute];
        if (value == null) continue;
        for (final target in value.split(idSeparators)) {
          if (target.isEmpty) continue;
          references++;
          if (!ids.contains(target)) {
            report('Missing ARIA target: $attribute ${_label(target)}');
          }
        }
      }
    }
    final attributes = [
      'href', 'src', 'action', 'poster', 'data',
      // Inventory declarations even on currently inactive control types. This
      // does not establish form ownership or effective submission behavior.
      if (element.localName == 'button' || element.localName == 'input')
        'formaction',
    ];
    for (final attribute in attributes) {
      final value = element.attributes[attribute];
      if (value == null) continue;
      inspectReference(
        value,
        '${element.localName}[$attribute] ${_label(value)}',
        inline: true,
        navigation:
            attribute == 'href' &&
            element.namespaceUri == 'http://www.w3.org/1999/xhtml' &&
            (element.localName == 'a' || element.localName == 'area'),
      );
    }
    // Foreign SVG attributes have typed namespace keys, unlike HTML/string
    // attributes. Inventory both href declarations, without inferring which
    // one wins or whether the element can render or navigate.
    if (element.namespaceUri == 'http://www.w3.org/2000/svg') {
      for (final attribute in _svgUrlPresentationAttributes) {
        final value = element.attributes[attribute];
        if (value != null && value.trim().isNotEmpty) {
          inspectSvgPresentation(value, '${element.localName}[$attribute]');
        }
      }
      for (final attribute in element.attributes.entries) {
        final name = attribute.key;
        if (name is dom.AttributeName &&
            name.namespace == 'http://www.w3.org/1999/xlink' &&
            name.name == 'href') {
          inspectReference(
            attribute.value,
            '${element.localName}[xlink:href] ${_label(attribute.value)}',
            inline: true,
          );
        }
      }
    }
    final responsiveAttribute = switch (element.localName) {
      'img' || 'source' => 'srcset',
      'link' => 'imagesrcset',
      _ => null,
    };
    final responsive = responsiveAttribute == null
        ? null
        : element.attributes[responsiveAttribute];
    if (responsive != null) {
      final location = '${element.localName}[$responsiveAttribute]';
      inspectSrcsetReferences(
        responsive,
        onReference: (value) =>
            inspectReference(value, '$location ${_label(value)}', inline: true),
        onDiagnostic: (message) => report('$location $message'),
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

const _svgUrlPresentationAttributes = [
  'fill',
  'stroke',
  'clip-path',
  'mask',
  'filter',
  'marker-start',
  'marker-mid',
  'marker-end',
];

bool _insideTemplate(dom.Element element) {
  for (var parent = element.parent; parent != null; parent = parent.parent) {
    if (parent.namespaceUri == 'http://www.w3.org/1999/xhtml' &&
        parent.localName == 'template') {
      return true;
    }
  }
  return false;
}

String _label(String value) {
  // Bound display size and suppress controls, while keeping source as plain text.
  final text = value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ');
  return text.length > 120 ? '${text.substring(0, 120)}…' : text;
}

/// Comments and ordinary quoted strings are not URL references.
class _CssReferences extends css.Visitor {
  _CssReferences(this.onReference, [this.onFilter]);
  final void Function(String) onReference;
  final void Function()? onFilter;

  @override
  void visitDeclaration(css.Declaration node) {
    if (node.property.toLowerCase().replaceFirst('*', '') == 'filter') {
      onFilter?.call();
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
