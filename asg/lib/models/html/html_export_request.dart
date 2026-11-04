// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'html_site_input.dart';
import 'html_source_proposal.dart';

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
  const HtmlExportFailure(this.directory, {this.pendingDirectoryProcessId});
  final String directory;
  final int? pendingDirectoryProcessId;

  @override
  String toString() =>
      'HTML export did not complete. Partial files may remain in $directory. '
      'Nothing was removed. '
      '${pendingDirectoryProcessId == null ? 'Inspect the files and choose a new folder to retry.' : 'Folder process $pendingDirectoryProcessId exit is unconfirmed; wait for reconciliation before retrying.'}';
}

/// Explicit confirmation of untrusted reviewed bytes and a new destination.
/// Export is not verification, registration, promotion or execution authority.
class HtmlReviewedExportRequest {
  const HtmlReviewedExportRequest({
    required this.proposal,
    required this.parent,
    required this.folderName,
  });

  final HtmlSourceProposal proposal;
  final String parent, folderName;

  bool matches(HtmlReviewedExportRequest other) =>
      parent == other.parent &&
      folderName == other.folderName &&
      proposal.summary == other.proposal.summary &&
      proposal.files.length == other.proposal.files.length &&
      proposal.files.entries.every(
        (entry) => other.proposal.files[entry.key] == entry.value,
      );
}
