// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

/// Operations are reported independently; reporting never grants execution.
enum GenerationOperation {
  starterCreation,
  starterVerification,
  candidateConfinement,
  webPreview,
  processCleanup,
}

/// Implemented operation paths, not a toolchain probe or successful execution.
class GenerationCapabilities {
  const GenerationCapabilities({
    required this.host,
    this.starterCreation = false,
    this.starterVerification = false,
    this.candidateConfinement = false,
    this.webPreview = false,
    this.processCleanup = false,
  });

  const GenerationCapabilities.macOS()
    : this(
        host: 'macOS',
        starterCreation: true,
        starterVerification: true,
        candidateConfinement: true,
        webPreview: true,
        processCleanup: true,
      );
  const GenerationCapabilities.unavailable(String host) : this(host: host);
  const GenerationCapabilities.unknown() : this(host: 'Uninspected host');

  final String host;
  final bool starterCreation;
  final bool starterVerification;
  final bool candidateConfinement;
  final bool webPreview;
  final bool processCleanup;

  bool implementsOperation(GenerationOperation operation) =>
      switch (operation) {
        GenerationOperation.starterCreation => starterCreation,
        GenerationOperation.starterVerification => starterVerification,
        GenerationOperation.candidateConfinement => candidateConfinement,
        GenerationOperation.webPreview => webPreview,
        GenerationOperation.processCleanup => processCleanup,
      };

  List<GenerationCapability> get operations => List.unmodifiable([
    GenerationCapability(
      GenerationOperation.starterCreation,
      'Starter creation',
      starterCreation,
      starterCreation
          ? 'Fixed Flutter web starter in a new folder. Requires a readable Flutter SDK, Python, current Plan approval and explicit consent.'
          : 'Use the macOS app with a Flutter SDK and Python. This host has no enabled starter-generation path.',
    ),
    GenerationCapability(
      GenerationOperation.starterVerification,
      'Starter verification',
      starterVerification,
      starterVerification
          ? 'Fixed resolve, analyze, test and web-build operations. SDK, dependencies and saved input integrity are checked when running.'
          : 'Local starter verification is unavailable. In-app prototypes and advisory chat remain separate.',
    ),
    GenerationCapability(
      GenerationOperation.candidateConfinement,
      'Candidate confinement',
      candidateConfinement,
      candidateConfinement
          ? 'Reviewed Flutter candidates use host-specific confinement and offline checks. A reviewed diff and explicit verification consent are required.'
          : 'No verified candidate confinement on this host. Candidate execution must remain unavailable.',
    ),
    GenerationCapability(
      GenerationOperation.webPreview,
      'Web preview',
      webPreview,
      webPreview
          ? 'Loopback serving of verified web output. Starting preview validates saved artifacts; browser launch and a free port are still required.'
          : 'Independent generated-output serving is unavailable. Use the in-app prototype preview.',
    ),
    GenerationCapability(
      GenerationOperation.processCleanup,
      'Process cleanup',
      processCleanup,
      processCleanup
          ? 'Stop requests termination of owned verification; the preview server is closed on Stop or disposal. Completion is reported by the operation, not this report.'
          : 'No enabled generation-process lifecycle on this host. This report does not establish that any external process has stopped.',
    ),
  ]);

  static const limits =
      'Implementation availability only. No SDK, Python, sandbox, browser, model or device probe has run for this report. It does not grant execution permission or establish successful checks, cleanup or inference. Project type, saved history, approval and per-operation validation still apply.';
}

class GenerationCapability {
  const GenerationCapability(
    this.operation,
    this.name,
    this.implemented,
    this.detail,
  );
  final GenerationOperation operation;
  final String name;
  final bool implemented;
  final String detail;
}
