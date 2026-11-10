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
  String? svg,
}) => HtmlSourceProposal.decode(
  jsonEncode({
    'summary': 'References',
    'files': {
      'index.html': source,
      'styles.css': css,
      if (script) 'app.js': 'throw Error("must never run");',
      'image.svg': ?svg,
    },
  }),
);
String page(String body) =>
    '<!doctype html><html><head><title>References</title></head><body>$body</body></html>';

void main() {
  test('HTML navigation recognizes top-of-document fallback', () async {
    final report = await inspectHtmlReferences(
      proposal(
        page(
          '<a href="#top">Top</a><a href="#ToP">Top</a>'
          '<area href="index.html#%74op"><a href="#%54%4f%50">Top</a>',
        ),
      ),
    );
    expect(report.references, 4);
    expect(report.findings, 0);
  });

  test('top fallback preserves resource and near-match diagnostics', () async {
    final report = await inspectHtmlReferences(
      proposal(
        page(
          '<a href="#topper">Missing</a><a href="#top%20">Missing</a>'
          '<img src="#top"><svg><use href="#TOP"></use></svg>'
          '<a href="styles.css#top">CSS</a>',
        ),
        css: 'body{background:url(#top)}',
      ),
    );
    expect(report.references, 6);
    expect(report.findings, 6);
    expect(
      report.messages.where((m) => m.contains('Missing HTML fragment')),
      hasLength(4),
    );
    expect(
      report.messages.where((m) => m.contains('Non-HTML fragment')),
      hasLength(2),
    );
  });

  test('base without href retains local URL diagnostics', () async {
    for (final base in ['<base target="_blank">', '<base>']) {
      final report = await inspectHtmlReferences(
        proposal(page('$base<img src="missing.png"><a href="#absent">Go</a>')),
      );
      expect(report.messages.join('\n'), contains('Missing local target'));
      expect(report.messages.join('\n'), contains('Missing HTML fragment'));
      expect(
        report.messages.join('\n'),
        isNot(contains('local targets were not resolved')),
      );
    }
  });

  test(
    'explicit empty base href keeps conservative resolution warning',
    () async {
      final report = await inspectHtmlReferences(
        proposal(page('<base href=""><img src="missing.png">')),
      );
      expect(
        report.messages.join('\n'),
        contains('local targets were not resolved'),
      );
      expect(
        report.messages.join('\n'),
        isNot(contains('Missing local target')),
      );
    },
  );

  test('inert template IDs cannot satisfy live fragments', () async {
    final report = await inspectHtmlReferences(
      proposal(
        page(
          '<template><p id="inert"></p><svg><g id="shape"></g></svg></template>'
          '<a href="#inert">Go</a><svg><use href="#shape"></use></svg>',
        ),
      ),
    );
    expect(report.references, 2);
    expect(report.findings, 2);
    expect(
      report.messages.every((m) => m.contains('Missing HTML fragment')),
      true,
    );
  });

  test('template IDs do not produce live duplicate ID findings', () async {
    final report = await inspectHtmlReferences(
      proposal(
        page(
          '<p id="same"></p><template><p id="same"></p>'
          '<template><p id="same"></p></template></template>'
          '<a href="#same">Go</a>',
        ),
      ),
    );
    expect(report.references, 1);
    expect(report.findings, 0);
  });

  test('inert base does not suppress missing live references', () async {
    final report = await inspectHtmlReferences(
      proposal(
        page(
          '<template><base href="https://example.invalid/"></template>'
          '<a href="missing.html">Go</a>',
        ),
      ),
    );
    expect(
      report.messages.join('\n'),
      contains('Missing local target: a[href] missing.html'),
    );
    expect(
      report.messages.join('\n'),
      isNot(contains('local targets were not resolved')),
    );
  });

  test('live SVG and template element IDs remain targets', () async {
    final report = await inspectHtmlReferences(
      proposal(
        page(
          '<template id="container"><p id="hidden"></p></template>'
          '<svg><g id="a&amp;b"></g><use href="#a%26b"></use></svg>'
          '<a href="#container">Go</a><p id="duplicate"></p><p id="duplicate"></p>',
        ),
      ),
    );
    expect(report.references, 2);
    expect(report.findings, 1);
    expect(report.messages.single, contains('Duplicate HTML ID: duplicate'));
  });

  test('HTML navigation resolves decoded legacy anchor names', () async {
    final report = await inspectHtmlReferences(
      proposal(
        page(
          '<a name="a&amp;b"></a><a name="Section"></a>'
          '<a href="#a%26b">Go</a><area href="./index.html#Section">'
          '<a href="#section">Wrong case</a>',
        ),
      ),
    );
    expect(report.references, 3);
    expect(report.findings, 1);
    expect(report.messages.single, contains('#section'));
  });
  test('navigation names cannot satisfy resource fragments', () async {
    final report = await inspectHtmlReferences(
      proposal(
        page(
          '<a name="legacy"></a><a href="#legacy">Go</a>'
          '<svg><use href="#legacy"></use></svg><img src="#legacy">'
          '<p style="background:url(#legacy)">Text</p>',
        ),
      ),
    );
    expect(report.references, 4);
    expect(report.findings, 3);
    expect(report.messages.join('\n'), isNot(contains('a[href]')));
  });
  test(
    'foreign, unrelated and inert names are not navigation targets',
    () async {
      final report = await inspectHtmlReferences(
        proposal(
          page(
            '<div name="div"></div><svg><a name="svg"></a></svg>'
            '<template><a name="inert"></a></template>'
            '<!-- <a name="comment"></a> -->'
            '<a href="#div">D</a><a href="#svg">S</a>'
            '<a href="#inert">T</a><a href="#comment">C</a>',
          ),
        ),
      );
      expect(report.references, 4);
      expect(report.findings, 4);
    },
  );
  test('inline SVG XLink declarations expose missing and external targets', () async {
    final report = await inspectHtmlReferences(
      proposal(
        page(
          '<svg><use xlink:href="missing.svg#shape"></use>'
          '<image xlink:href="https://example.invalid/image.svg"></image></svg>',
        ),
      ),
    );
    expect(report.references, 2);
    expect(report.findings, 2);
    expect(
      report.messages.join('\n'),
      contains('Missing local target: use[xlink:href]'),
    );
    expect(
      report.messages.join('\n'),
      contains(
        'External or scheme reference needs separate review: image[xlink:href]',
      ),
    );
  });

  test(
    'SVG href and XLink declarations are inventoried independently',
    () async {
      final report = await inspectHtmlReferences(
        proposal(
          page(
            '<svg><g id="a&amp;b"></g><use href="#a%26b" xlink:href="#absent"></use>'
            '<image xlink:href="image.svg"></image>'
            '<a xlink:href="index.html?x=1&amp;y=2">Link</a></svg>',
          ),
          svg: '<svg xmlns="http://www.w3.org/2000/svg"/>',
        ),
      );
      expect(report.references, 4);
      expect(report.findings, 2);
      expect(
        report.messages.join('\n'),
        contains('Missing HTML fragment: use[xlink:href] #absent'),
      );
      expect(
        report.messages.join('\n'),
        contains(
          'Query behavior needs browser verification: a[xlink:href] index.html?x=1&y=2',
        ),
      );
    },
  );

  test('XLink uses existing invalid encoding and base limitations', () async {
    final invalid = await inspectHtmlReferences(
      proposal(
        page(
          '<svg><use xlink:href="%FF"></use><use xlink:href="bad\\\\path"></use></svg>',
        ),
      ),
    );
    expect(invalid.references, 2);
    expect(invalid.findings, 2);
    expect(
      invalid.messages.join('\n'),
      contains('Invalid encoded reference: use[xlink:href]'),
    );
    expect(
      invalid.messages.join('\n'),
      contains('Invalid or unsupported reference: use[xlink:href]'),
    );
    final based = await inspectHtmlReferences(
      proposal(
        page(
          '<base href="index.html"><svg><use xlink:href="missing.svg"></use>'
          '<a xlink:href="//example.invalid/">Link</a></svg>',
        ),
      ),
    );
    expect(based.references, 3);
    expect(
      based.messages.join('\n'),
      contains('local targets were not resolved'),
    );
    expect(based.messages.join('\n'), contains('External or scheme reference'));
    expect(based.messages.join('\n'), isNot(contains('Missing local target')));
  });

  test('XLink inspection is limited to SVG namespace declarations in HTML', () async {
    final report = await inspectHtmlReferences(
      proposal(
        page(
          '<div xlink:href="missing.html"></div>'
          '<math><mi xlink:href="missing.html">x</mi></math>'
          '<svg><use other:href="missing.svg" xlink:title="missing.svg"></use>'
          '<foreignObject><div xlink:href="missing.html"></div></foreignObject></svg>'
          '<!-- <svg><use xlink:href="comment.svg"></use></svg> -->'
          '<script>const s = \'<svg><use xlink:href="script.svg"></use></svg>\';</script>',
        ),
        svg: '<svg xmlns="http://www.w3.org/2000/svg"><use href="missing.svg"/></svg>',
      ),
    );
    expect(report.references, 0);
    expect(report.findings, 0);
  });

  test('SVG presentation URLs resolve local and external targets', () async {
    final report = await inspectHtmlReferences(
      proposal(
        page('''
          <svg><defs><linearGradient id="a&amp;b"/></defs>
            <rect fill='url("#a%26b") red' stroke="url(#absent)"
              clip-path="url(#missing)" mask="url(mask.svg#m)"
              filter="url(#filter) blur(2px)"/>
            <path marker-start="url(#start)" marker-mid="url(#middle)"
              marker-end="url(https://example.invalid/marker.svg#end)"/>
          </svg>
        '''),
      ),
    );
    expect(report.references, 8);
    expect(report.findings, 7);
    expect(
      report.messages,
      contains('Missing HTML fragment: rect[stroke] #absent'),
    );
    expect(
      report.messages,
      contains('Missing HTML fragment: rect[clip-path] #missing'),
    );
    expect(
      report.messages,
      contains('Missing local target: rect[mask] mask.svg#m'),
    );
    expect(
      report.messages,
      contains('Missing HTML fragment: rect[filter] #filter'),
    );
    expect(
      report.messages,
      contains('Missing HTML fragment: path[marker-start] #start'),
    );
    expect(
      report.messages,
      contains('Missing HTML fragment: path[marker-mid] #middle'),
    );
    expect(
      report.messages,
      contains(
        'External or scheme reference needs separate review: '
        'path[marker-end] https://example.invalid/marker.svg#end',
      ),
    );
  });

  test(
    'SVG presentation inspection ignores ordinary and non-SVG values',
    () async {
      final report = await inspectHtmlReferences(
        proposal(
          page('''
          <div fill="url(#html)"></div>
          <math><mi stroke="url(#math)">x</mi></math>
          <svg><rect fill="rgb(10 20 30)" stroke="currentColor"
            mask="none" filter="blur(2px)"/>
            <rect fill='"url(#literal)"'/>
            <foreignObject><div clip-path="url(#html)"></div></foreignObject>
          </svg>
        '''),
        ),
      );
      expect(report.references, 0);
      expect(report.findings, 0);
    },
  );

  test('SVG presentation URLs respect the live HTML base', () async {
    final report = await inspectHtmlReferences(
      proposal(
        page('''
          <base href="https://example.invalid/">
          <svg><rect fill="url(#absent)" mask="url(mask.svg#m)"
            filter="url(https://example.invalid/filter.svg#f)"/></svg>
        '''),
      ),
    );
    expect(report.references, 4);
    expect(
      report.messages.join('\n'),
      contains('External or scheme reference'),
    );
    expect(
      report.messages.join('\n'),
      isNot(contains('Missing HTML fragment')),
    );
    expect(report.messages.join('\n'), isNot(contains('Missing local target')));
  });

  test('SVG values cannot introduce declarations or imports', () async {
    final report = await inspectHtmlReferences(
      proposal(
        page('''
          <svg><rect fill="red; stroke:url(#unrelated)"
            mask="none} @import url(extra.css);"/></svg>
        '''),
      ),
    );
    expect(report.references, 0);
    expect(report.messages, hasLength(2));
    expect(report.messages.join('\n'), contains('rect[fill]'));
    expect(report.messages.join('\n'), contains('rect[mask]'));
  });

  test('SVG XLink diagnostics use the shared message bound', () async {
    final report = await inspectHtmlReferences(
      proposal(
        page(
          '<svg>${List.filled(150, '<use xlink:href="missing.svg"></use>').join()}</svg>'
          '<a href="missing.html">HTML</a>',
        ),
      ),
    );
    expect(report.references, 151);
    expect(report.findings, 151);
    expect(report.messages, hasLength(100));
    expect(report.truncated, true);
  });

  test('form action and declared overrides are independently inspected', () async {
    final report = await inspectHtmlReferences(
      proposal(
        page(
          '<form action="index.html"><button formaction="missing.html">Send</button>'
          '<input type="image" formaction="https://example.invalid/send"></form>',
        ),
      ),
    );
    expect(report.references, 3);
    expect(report.findings, 2);
    expect(
      report.messages.join('\n'),
      contains('Missing local target: button[formaction] missing.html'),
    );
    expect(
      report.messages.join('\n'),
      contains(
        'External or scheme reference needs separate review: input[formaction]',
      ),
    );
  });

  test('form overrides reuse entity, fragment and query resolution', () async {
    final report = await inspectHtmlReferences(
      proposal(
        page(
          '<p id="a&amp;b"></p><button formaction="index.html#a%26b">Send</button>'
          '<input type="submit" formaction="./index.html?x=1&amp;y=2">'
          '<button formaction="">Current</button><input formaction="%FF">',
        ),
      ),
    );
    expect(report.references, 4);
    expect(report.findings, 2);
    expect(report.messages.join('\n'), contains('Query behavior'));
    expect(report.messages.join('\n'), contains('x=1&y=2'));
    expect(
      report.messages.join('\n'),
      contains('Invalid encoded reference: input[formaction]'),
    );
    expect(
      report.messages.join('\n'),
      isNot(contains('Missing HTML fragment')),
    );
  });

  test('base suppresses local override resolution only', () async {
    final report = await inspectHtmlReferences(
      proposal(
        page(
          '<base href="https://example.invalid/"><button formaction="missing.html">Send</button>'
          '<input type="submit" formaction="//example.invalid/send">',
        ),
      ),
    );
    expect(report.references, 3);
    expect(
      report.messages.join('\n'),
      contains('local targets were not resolved'),
    );
    expect(report.messages.join('\n'), contains('input[formaction]'));
    expect(report.messages.join('\n'), isNot(contains('Missing local target')));
  });

  test('formaction inventories button and input declarations only', () async {
    final report = await inspectHtmlReferences(
      proposal(
        page(
          '<div formaction="missing.html"></div><form formaction="absent.html"></form>'
          '<!-- <button formaction="comment.html">Send</button> -->'
          '<script>const s = \'<input formaction="script.html">\';</script>'
          '<button type="button" formaction="index.html">Inert declaration</button>'
          '<input type="text" formaction="index.html">',
        ),
      ),
    );
    expect(report.references, 2);
    expect(report.findings, 0);
    expect(HtmlReferenceReport.limitations, contains('effective submission'));
  });

  test('form override diagnostics preserve the shared display bound', () async {
    final report = await inspectHtmlReferences(
      proposal(
        page(
          List.filled(
            200,
            '<button formaction="missing.html">Send</button>',
          ).join(),
        ),
      ),
    );
    expect(report.references, 200);
    expect(report.findings, 200);
    expect(report.messages, hasLength(100));
    expect(report.truncated, true);
  });

  test('responsive candidates on img, source and link are observed', () async {
    final report = await inspectHtmlReferences(
      proposal(
        page('''
      <link rel="preload" as="image" imagesrcset="index.html 1x, missing.png 2x">
      <picture><source srcset="styles.css 320w, wide.png 640w">
      <img srcset="index.html, absent.png 1.5x"></picture>
    '''),
      ),
    );
    expect(report.references, 6);
    expect(report.findings, 3);
    expect(
      report.messages.join('\n'),
      contains('link[imagesrcset] missing.png'),
    );
    expect(report.messages.join('\n'), contains('source[srcset] wide.png'));
    expect(report.messages.join('\n'), contains('img[srcset] absent.png'));
  });
  test(
    'responsive commas belong to URLs until whitespace or trailing separator',
    () async {
      final report = await inspectHtmlReferences(
        proposal(
          page('''
      <img srcset="data:image/svg+xml,%3Csvg%3E,%3C/svg%3E 1x, index.html 2x">
      <img srcset="one,two.png 1x, index.html, styles.css">
    '''),
        ),
      );
      expect(report.references, 5);
      expect(report.findings, 2);
      expect(
        report.messages.first,
        contains('data:image/svg+xml,%3Csvg%3E,%3C/svg%3E'),
      );
      expect(report.messages.last, contains('one,two.png'));
      expect(
        report.messages.join('\n'),
        isNot(contains('target: img[srcset] two.png')),
      );
    },
  );
  test(
    'responsive decoding, queries, schemes and base limits match HTML refs',
    () async {
      final report = await inspectHtmlReferences(
        proposal(
          page('''
      <p id="a&amp;b">Site</p>
      <img srcset="index.html#a%26b 1x, index.html?x=1&amp;y=2 2x, #missing 3x">
      <source srcset="//example.invalid/img 1x, https://example.invalid/img 2x">
    '''),
        ),
      );
      expect(report.references, 5);
      expect(report.findings, 4);
      expect(report.messages.join('\n'), contains('Query behavior'));
      expect(report.messages.join('\n'), contains('Missing HTML fragment'));
      expect(
        report.messages.where((m) => m.contains('separate review')),
        hasLength(2),
      );
      final base = await inspectHtmlReferences(
        proposal(
          page('''
      <base href="https://example.invalid/"><img srcset="missing.png 1x">
    '''),
        ),
      );
      expect(base.messages.join('\n'), isNot(contains('Missing local target')));
    },
  );
  test(
    'malformed responsive descriptors recover without claiming URL checks',
    () async {
      final report = await inspectHtmlReferences(
        proposal(
          page('''
      <img srcset="bad.png 0w, bad.png -1x, bad.png 1x 2x, bad.png 1w 1x,
        bad.png calc(1, 2)x, bad.png 10h, bad.png 10w 10h, index.html 2x">
    '''),
        ),
      );
      expect(report.references, 1);
      expect(report.findings, 7);
      expect(
        report.messages.every((m) => m.contains('candidate URL not checked')),
        true,
      );
    },
  );
  test('responsive descriptor numeric grammar and ASCII whitespace', () async {
    final report = await inspectHtmlReferences(
      proposal(
        page('''
      <img srcset="index.html 0001w, index.html .5x, index.html 1e+2x,
        index.html 0x, index.html -0x, index.html 1.x, index.html +1x,
        index.html 1e999x, index.html 1X, index.html 1\u000bx">
    '''),
      ),
    );
    expect(report.references, 5);
    expect(
      report.messages.where((m) => m.contains('candidate URL not checked')),
      hasLength(5),
    );
    expect(report.messages.join('\n'), contains('HTML parser recovered'));
  });
  test(
    'responsive separator recovery and diagnostic display stay bounded',
    () async {
      final recovered = await inspectHtmlReferences(
        proposal(
          page('''
      <img srcset=",, index.html,, styles.css 2x, , index.html 3x">
    '''),
        ),
      );
      expect(recovered.references, 3);
      expect(recovered.findings, 3);
      final report = await inspectHtmlReferences(
        proposal(
          page(
            '<img srcset="${List.filled(200, 'absent.png 1x').join(', ')}">',
          ),
        ),
      );
      expect(report.references, 200);
      expect(report.messages, hasLength(100));
      expect(report.truncated, true);
    },
  );
  test(
    'comments, text and attributes on other elements are not srcset',
    () async {
      final report = await inspectHtmlReferences(
        proposal(
          page('''
      <!-- <img srcset="comment.png 1x"> -->
      <script>const s = '<img srcset="script.png 1x">';</script>
      <div srcset="div.png 1x" imagesrcset="other.png 1x">Site</div>
      <img imagesrcset="wrong.png 1x"><link srcset="wrong.png 1x">
    '''),
        ),
      );
      expect(report.references, 0);
      expect(report.findings, 0);
    },
  );
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
