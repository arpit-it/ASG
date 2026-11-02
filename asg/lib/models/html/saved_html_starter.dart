// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'html_site_input.dart';

/// A remembered fixed export, not approval to execute arbitrary edited sources.
class SavedHtmlStarter {
  SavedHtmlStarter({required this.directory, required this.input}) {
    if (directory.length > 4096 ||
        !directory.startsWith('/') ||
        directory.contains('\\') ||
        directory.runes.any((r) => r < 32 || r == 127) ||
        directory
            .split('/')
            .skip(1)
            .any((p) => p.isEmpty || p == '.' || p == '..')) {
      throw const FormatException('Invalid saved starter directory.');
    }
  }
  final String directory;
  final HtmlSiteInput input;
  static const adapterId = 'asg-static-html-v1';
  static const runnerVersion = '1.0.0';

  Map<String, Object> toJson() => {
    'schemaVersion': 1,
    'adapterId': adapterId,
    'runnerVersion': runnerVersion,
    'directory': directory,
    'title': input.title,
    'description': input.description,
  };

  factory SavedHtmlStarter.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.length != 6 ||
        value['schemaVersion'] != 1 ||
        value['schemaVersion'] is! int ||
        value['adapterId'] != adapterId ||
        value['runnerVersion'] != runnerVersion ||
        value['directory'] is! String ||
        value['title'] is! String ||
        value['description'] is! String) {
      throw const FormatException('Unknown or damaged saved HTML starter.');
    }
    return SavedHtmlStarter(
      directory: value['directory'] as String,
      input: HtmlSiteInput(
        title: value['title'] as String,
        description: value['description'] as String,
      ),
    );
  }
}
