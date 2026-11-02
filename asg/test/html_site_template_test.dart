// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:asg/models/html/html_site_input.dart';
import 'package:asg/services/html/html_site_template.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'independent deterministic immutable sources have no Flutter bundle',
    () {
      final input = HtmlSiteInput(
        title: 'Community garden',
        description: 'Grow together.',
      );
      final files = HtmlSiteTemplate().generate(input);
      expect(files, HtmlSiteTemplate().generate(input));
      expect(files.keys, [
        'index.html',
        'styles.css',
        'app.js',
        'assets/mark.svg',
        'README.md',
      ]);
      expect(
        files['index.html'],
        contains('<h1 id="site-title">Community garden</h1>'),
      );
      expect(files.values.join(), isNot(contains('flutter_bootstrap')));
      expect(() => files['index.html'] = '', throwsUnsupportedError);
      expect(files['README.md'], contains(HtmlSiteTemplate.adapterId));
    },
  );

  test(
    'hostile plain text cannot become markup, script or remote references',
    () {
      final input = HtmlSiteInput(
        title: '</title><script>alert(1)</script>',
        description: '<img src="https://example.invalid/x" onerror="alert(1)"> & text\nnext',
      );
      final files = HtmlSiteTemplate().generate(input);
      expect(files['index.html'], contains('&lt;script&gt;'));
      expect(files['index.html'], contains('&lt;img src='));
      expect(files['index.html'], isNot(contains('<script>alert')));
      expect(
        files['app.js'],
        HtmlSiteTemplate().generate(
          HtmlSiteInput(title: 'Other', description: 'Other'),
        )['app.js'],
      );
      expect(files['styles.css'], isNot(contains(input.description)));
      expect(files['README.md'], isNot(contains(input.title)));
    },
  );

  test(
    'rejects empty, oversized and control input before producing sources',
    () {
      for (final value in ['', '  ', 'x' * 121, 'bad\u0000', 'bad\u007f']) {
        expect(
          () => HtmlSiteInput(title: value, description: 'Valid'),
          throwsFormatException,
        );
      }
      for (final value in ['', 'x' * 2001, 'bad\u0001']) {
        expect(
          () => HtmlSiteInput(title: 'Valid', description: value),
          throwsFormatException,
        );
      }
      expect(
        HtmlSiteInput(title: ' A ', description: ' B\nC ').description,
        'B\nC',
      );
      expect(
        HtmlSiteInput(title: 'x' * 120, description: 'x' * 2000).title.length,
        120,
      );
    },
  );
}
