// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'html_site_input.dart';

/// Exact content and destination displayed for confirmation by the caller.
/// A confirmation is session authority, not persisted execution permission.
class HtmlExportRequest {
  const HtmlExportRequest({
    required this.input,
    required this.parent,
    required this.folderName,
  });

  final HtmlSiteInput input;
  final String parent, folderName;

  bool matches(HtmlExportRequest other) =>
      parent == other.parent &&
      folderName == other.folderName &&
      input.title == other.input.title &&
      input.description == other.input.description;
}

/// Failure after folder creation retains the partial export for inspection.
/// Its existence never means that export, verification or preview succeeded.
class HtmlExportFailure implements Exception {
  const HtmlExportFailure(this.directory);
  final String directory;

  @override
  String toString() =>
      'HTML export did not complete. Partial files may remain in $directory. '
      'Nothing was removed; inspect them and choose a new folder to retry.';
}
