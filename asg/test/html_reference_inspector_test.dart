// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/models/html/html_reference_report.dart';
import 'package:asg/models/html/html_source_proposal.dart';
import 'package:asg/services/html/html_reference_inspector.dart';
import 'package:flutter_test/flutter_test.dart';

HtmlSourceProposal proposal(
  String source, {
  bool script = false,
  String css = 'body{}',
}) => HtmlSourceProposal.decode(
  jsonEncode({
    'summary': 'References',
    'files': {
      'index.html': source,
      'styles.css': css,
      if (script) 'app.js': 'throw Error("must never run");',
    },
  }),
);
String page(String body) =>
    '<!doctype html><html><head><title>References</title></head><body>$body</body></html>';

void main() {
  test(
    'CSS URL terms and both import syntaxes traverse nested rules',
    () async {
      final report = await inspectHtmlReferences(
        proposal(
          page('<p>Site</p>'),
          css: r'''
      @import "styles.css";
      @import url('./styles.css') screen;
      @media screen { body { background: url(missing.png); } }
      p { background: url("./index.html"); content: "url(fake.png)"; }
      /* url(comment.png) */
    ''',
        ),
      );
      expect(report.references, 4);
      expect(report.findings, 1);
      expect(
        report.messages.single,
        contains('Missing local target: styles.css missing.png'),
      );
    },
  );
  test('CSS filter parser omissions are explicitly reported', () async {
    final report = await inspectHtmlReferences(
      proposal(page('<p>Site</p>'), css: 'p{filter:url(#mask)}'),
    );
    expect(report.messages.join('\n'), contains('filter declaration'));
  });
  test('inline CSS uses decoded attributes and HTML fragment IDs', () async {
    final report = await inspectHtmlReferences(
      proposal(
        page('''
      <style>p { background: url(#present); background: url(absent.png); }</style>
      <p id="present" style="background:url(&quot;#present&quot;)">Site</p>
    '''),
      ),
    );
    expect(report.references, 3);
    expect(report.findings, 1);
    expect(report.messages.single, contains('style element absent.png'));
  });
  test(
    'base affects inline CSS but not separate stylesheet resolution',
    () async {
      final report = await inspectHtmlReferences(
        proposal(
          page('''
      <base href="https://example.invalid/">
      <style>p{background:url(inline.png)}</style>
      <p style="background:url(attribute.png)">Site</p>
    '''),
          css: 'p{background:url(sheet.png)}',
        ),
      );
      expect(report.messages.join('\n'), contains('styles.css sheet.png'));
      expect(
        report.messages.join('\n'),
        isNot(contains('Missing local target: style element')),
      );
      expect(
        report.messages.join('\n'),
        isNot(contains('Missing local target: p[style]')),
      );
    },
  );
  test(
    'CSS external, data, query and stylesheet fragments stay advisory',
    () async {
      final report = await inspectHtmlReferences(
        proposal(
          page('<p>Site</p>'),
          css: '''
      @import "https://example.invalid/theme.css";
      p{background:url(data:image/png;base64,AAAA);mask:url(#mask)}
      a{background:url(styles.css?v=1)}
    ''',
        ),
      );
      expect(report.references, 4);
      expect(
        report.messages.where((m) => m.contains('separate review')),
        hasLength(2),
      );
      expect(
        report.messages.join('\n'),
        contains('Non-HTML fragment not checked'),
      );
      expect(report.messages.join('\n'), contains('Query behavior'));
      expect(
        report.messages.join('\n'),
        isNot(contains('Missing local target')),
      );
    },
  );
  test('malformed CSS recovery and CSS message bounds are explicit', () async {
    final recovered = await inspectHtmlReferences(
      proposal(page('<p>Site</p>'), css: 'p{color:} }'),
    );
    expect(recovered.messages.join('\n'), contains('CSS parser reported'));
    final report = await inspectHtmlReferences(
      proposal(
        page('<p>Site</p>'),
        css: List.filled(200, 'p{background:url(absent.png)}').join(),
      ),
    );
    expect(report.findings, 200);
    expect(report.messages, hasLength(100));
    expect(report.truncated, true);
  });
  test(
    'decoded entities, encoded fragments and relative local files',
    () async {
      final report = await inspectHtmlReferences(
        proposal(
          page(
            '<h1 id="a&amp;b">Hello</h1><a href="#a%26b">Go</a>'
            '<link href="./styles.css"><script src="app.js"></script>'
            '<a href="./index.html#a%26b">Again</a>',
          ),
          script: true,
        ),
      );
      expect(report.references, 4);
      expect(report.findings, 0);
      expect(report.messages, isEmpty);
      expect(HtmlReferenceReport.limitations, contains('No safety verdict'));
      expect(() => report.messages.add('bad'), throwsUnsupportedError);
    },
  );
  test(
    'missing assets, IDs, duplicate IDs and absent optional script',
    () async {
      final report = await inspectHtmlReferences(
        proposal(
          page(
            '<p id="same"></p><p id="same"></p><a href="#missing">Go</a>'
            '<img src="missing.png"><script src="app.js"></script>'
            '<a href="styles.css#x">CSS fragment</a>',
          ),
        ),
      );
      expect(
        report.messages.where((m) => m.contains('Missing local target')),
        hasLength(2),
      );
      expect(report.messages.join('\n'), contains('Duplicate HTML ID'));
      expect(report.messages.join('\n'), contains('Missing HTML fragment'));
      expect(
        report.messages.join('\n'),
        contains('Non-HTML fragment not checked'),
      );
    },
  );
  test('external schemes, network references, queries and malformed encoding', () async {
    final report = await inspectHtmlReferences(
      proposal(
        page(
          '<a href="https://example.invalid/">External</a>'
          '<img src="//example.invalid/a"><a href="javascript:alert(1)">JS</a>'
          '<form action="/index.html?x=1"></form><img src="%FF">',
        ),
      ),
    );
    expect(
      report.messages.where((m) => m.contains('separate review')),
      hasLength(3),
    );
    expect(report.messages.join('\n'), contains('Query behavior'));
    expect(report.messages.join('\n'), contains('Invalid encoded reference'));
  });
  test('base changes prevent misleading local-resolution results', () async {
    final report = await inspectHtmlReferences(
      proposal(
        page('<base href="https://example.invalid/"><img src="missing.png">'),
      ),
    );
    expect(
      report.messages.join('\n'),
      contains('local targets were not resolved'),
    );
    expect(report.messages.join('\n'), isNot(contains('Missing local target')));
  });
  test('malformed HTML recovers; diagnostic display is bounded', () async {
    final report = await inspectHtmlReferences(
      proposal(
        '<p id="x"><a href="missing">A</a>${List.filled(400, '<img src="absent">').join()}',
      ),
    );
    expect(report.findings, greaterThan(400));
    expect(report.messages, hasLength(100));
    expect(report.truncated, true);
    expect(report.messages.first, contains('parser recovered'));
  });
}
