// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

/// User declarations only. These never establish capability or change budgets.
class ModelProfileNotes {
  const ModelProfileNotes({
    this.revision = '',
    this.license = '',
    this.architecture = '',
    this.quantization = '',
    this.backend = '',
    this.contextTokens,
  });
  final String revision, license, architecture, quantization, backend;
  final int? contextTokens;

  bool get isEmpty =>
      [
        revision,
        license,
        architecture,
        quantization,
        backend,
      ].every((s) => s.isEmpty) &&
      contextTokens == null;

  void validate() {
    for (final text in [
      revision,
      license,
      architecture,
      quantization,
      backend,
    ]) {
      if (text.trim() != text ||
          text.length > 256 ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(text)) {
        throw const FormatException('Invalid model profile notes.');
      }
    }
    if (contextTokens != null &&
        (contextTokens! < 1 || contextTokens! > 1048576)) {
      throw const FormatException('Invalid declared context limit.');
    }
  }

  Map<String, Object?> toJson() {
    validate();
    return {
      'revision': revision,
      'license': license,
      'architecture': architecture,
      'quantization': quantization,
      'backend': backend,
      'contextTokens': contextTokens,
    };
  }

  factory ModelProfileNotes.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.length != 6 ||
        !value.keys.toSet().containsAll([
          'revision',
          'license',
          'architecture',
          'quantization',
          'backend',
          'contextTokens',
        ]) ||
        [
          'revision',
          'license',
          'architecture',
          'quantization',
          'backend',
        ].any((key) => value[key] is! String) ||
        (value['contextTokens'] != null && value['contextTokens'] is! int)) {
      throw const FormatException('Invalid saved model profile notes.');
    }
    final notes = ModelProfileNotes(
      revision: value['revision'] as String,
      license: value['license'] as String,
      architecture: value['architecture'] as String,
      quantization: value['quantization'] as String,
      backend: value['backend'] as String,
      contextTokens: value['contextTokens'] as int?,
    );
    notes.validate();
    return notes;
  }

  static const guidance =
      'User-declared, unverified notes for this preset. Saving or restoring notes does not verify model identity, license, compatibility or context capacity, change request budgets, select a runtime backend or load weights. Verified profiles and token accounting remain unavailable.';
}
