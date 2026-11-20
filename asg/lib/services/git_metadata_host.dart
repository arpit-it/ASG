// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/git_head_observation.dart';

/// Owns only a trusted metadata helper. It cannot run Git or project commands.
abstract interface class GitMetadataHost {
  bool get supported;
  Future<GitHeadObservation> inspect(GitMetadataReadRequest request);

  /// Settles owned cleanup, including a late startup, before allowing another job.
  Future<void> cancel();
  Future<void> dispose();
}
