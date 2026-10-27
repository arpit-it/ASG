// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

enum GenerationPhase {
  idle,
  thinking,
  writing,
  validating,
  applying,
  cancelling,
}

class GenerationEvent {
  const GenerationEvent.phase(this.phase) : text = '';
  const GenerationEvent.text(this.text) : phase = GenerationPhase.writing;
  final GenerationPhase phase;
  final String text;
}
