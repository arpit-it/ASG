// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

/// Implemented operation paths, not a toolchain probe or successful execution.
class GenerationCapabilities {
  const GenerationCapabilities.macOS() : host = 'macOS', implemented = true;
  const GenerationCapabilities.unavailable(this.host) : implemented = false;
  const GenerationCapabilities.unknown()
    : host = 'Uninspected host',
      implemented = false;

  final String host;
  final bool implemented;

  List<GenerationCapability> get operations => List.unmodifiable([
    GenerationCapability(
      'Starter creation',
      implemented,
      implemented
          ? 'Fixed Flutter web starter in a new folder. Requires a readable Flutter SDK, Python, current Plan approval and explicit consent.'
          : 'Use the macOS app with a Flutter SDK and Python. This host has no enabled starter-generation path.',
    ),
    GenerationCapability(
      'Starter verification',
      implemented,
      implemented
          ? 'Fixed resolve, analyze, test and web-build operations. SDK, dependencies and saved input integrity are checked when running.'
          : 'Local starter verification is unavailable. In-app prototypes and advisory chat remain separate.',
    ),
    GenerationCapability(
      'Candidate confinement',
      implemented,
      implemented
          ? 'Reviewed Flutter candidates use macOS confinement and offline checks. A reviewed diff and explicit verification consent are required.'
          : 'No verified candidate confinement on this host. Candidate execution must remain unavailable.',
    ),
    GenerationCapability(
      'Web preview',
      implemented,
      implemented
          ? 'Loopback serving of verified web output. Starting preview validates saved artifacts; browser launch and a free port are still required.'
          : 'Independent generated-output serving is unavailable. Use the in-app prototype preview.',
    ),
    GenerationCapability(
      'Process cleanup',
      implemented,
      implemented
          ? 'Stop requests termination of owned verification; the preview server is closed on Stop or disposal. Completion is reported by the operation, not this report.'
          : 'No enabled generation-process lifecycle on this host. This report does not establish that any external process has stopped.',
    ),
  ]);

  static const limits =
      'Implementation availability only. No SDK, Python, sandbox, browser, model or device probe has run for this report. It does not grant execution permission or establish successful checks, cleanup or inference. Project type, saved history, approval and per-operation validation still apply.';
}

class GenerationCapability {
  const GenerationCapability(this.name, this.implemented, this.detail);
  final String name;
  final bool implemented;
  final String detail;
}
