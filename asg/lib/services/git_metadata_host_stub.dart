// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/git_head_observation.dart';
import 'git_metadata_host.dart';

GitMetadataHost createGitMetadataHost() => UnsupportedGitMetadataHost();

class UnsupportedGitMetadataHost implements GitMetadataHost {
  @override
  bool get supported => false;
  @override
  Future<GitHeadObservation> inspect(GitMetadataReadRequest request) async =>
      throw StateError(
        'Local Git metadata inspection is unavailable on this platform.',
      );
  @override
  Future<void> cancel() async {}
  @override
  Future<void> dispose() async {}
}
