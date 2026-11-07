// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:crypto/crypto.dart';

bool isCandidateSourcePath(String value) =>
    RegExp(r'^asg/(lib|test)/[A-Za-z0-9_]+(?:/[A-Za-z0-9_]+)*\.dart$')
        .hasMatch(value) &&
    value.split('/').length <= 16;

String candidateTextHash(String value) =>
    sha256.convert(utf8.encode(value)).toString();

bool isCandidateProposalText(String value) {
  final bytes = utf8.encode(value);
  if (bytes.length > 16384 ||
      utf8.decode(bytes) != value ||
      value.runes.any(
        (r) => (r < 32 && !{9, 10, 13}.contains(r)) || (r >= 127 && r <= 159),
      )) {
    return false;
  }
  final lines = value.isEmpty
      ? 0
      : value.split(RegExp(r'\r\n|[\r\n\u2028\u2029]')).length -
            (RegExp(r'(\r\n|[\r\n\u2028\u2029])$').hasMatch(value) ? 1 : 0);
  return lines <= 500;
}

class CandidateSourceFile {
  const CandidateSourceFile._(
    this.digest,
    this.path,
    this.before,
    this.beforeHash,
  );
  final String digest, path, before, beforeHash;

  factory CandidateSourceFile.decode(String input) {
    const invalid = FormatException('Invalid proposal source.');
    try {
      if (input.length > 131072) throw invalid;
      final data = jsonDecode(input);
      if (data is! Map<String, dynamic> ||
          data.length != 5 ||
          data['schemaVersion'] is! int ||
          data['schemaVersion'] != 1 ||
          data['digest'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(data['digest']) ||
          data['path'] is! String ||
          !isCandidateSourcePath(data['path']) ||
          data['before'] is! String ||
          !isCandidateProposalText(data['before']) ||
          data['beforeHash'] is! String ||
          candidateTextHash(data['before']) != data['beforeHash']) {
        throw invalid;
      }
      return CandidateSourceFile._(
        data['digest'],
        data['path'],
        data['before'],
        data['beforeHash'],
      );
    } on Object {
      throw invalid;
    }
  }
}

/// Immutable consent artifact. It grants no execution or in-place write authority.
class CandidateSourceProposal {
  CandidateSourceProposal._(
    this.snapshot,
    this.python,
    this.trustedSource,
    this.source,
    this.replacement,
    this.destination,
    this.runName,
  );
  final String snapshot,
      python,
      trustedSource,
      replacement,
      destination,
      runName;
  final CandidateSourceFile source;
  String get afterHash => candidateTextHash(replacement);

  factory CandidateSourceProposal.create({
    required String snapshot,
    required String python,
    required String trustedSource,
    required CandidateSourceFile source,
    required String replacement,
    required String destination,
    required String runName,
  }) {
    if (!RegExp(r'^asg-self-candidate-[a-f0-9]{8}$').hasMatch(runName) ||
        snapshot.isEmpty ||
        python.isEmpty ||
        destination.isEmpty ||
        destination
            .split('/')
            .any((part) => part.toLowerCase().endsWith('.app')) ||
        replacement.trim().isEmpty ||
        !isCandidateProposalText(replacement) ||
        source.before == replacement) {
      throw const FormatException(
        'Choose a destination and a changed replacement within 16 KiB and 500 lines.',
      );
    }
    final header = RegExp(r'^(?://[^\n]*\n)+')
        .firstMatch(source.before)
        ?.group(0);
    if ((source.before.contains('SPDX-License-Identifier: MPL-2.0') ||
            source.before.toLowerCase().contains('copyright')) &&
        (header == null ||
            !(header.contains('SPDX-License-Identifier: MPL-2.0') ||
                header.toLowerCase().contains('copyright')) ||
            !replacement.startsWith(header))) {
      throw const FormatException(
        'Preserve the existing leading MPL and copyright header verbatim.',
      );
    }
    return CandidateSourceProposal._(
      snapshot,
      python,
      trustedSource,
      source,
      replacement,
      destination,
      runName,
    );
  }

  Map<String, String> get payload => {
    'snapshot': snapshot,
    'path': source.path,
    'expectedDigest': source.digest,
    'beforeHash': source.beforeHash,
    'afterHash': afterHash,
    'replacement': replacement,
    'destination': destination,
    'trustedSource': trustedSource,
    'runName': runName,
  };
}

class CandidateProposalResult {
  const CandidateProposalResult._(
    this.path,
    this.digest,
    this.sourceDigest,
    this.file,
    this.afterHash,
  );
  final String path, digest, sourceDigest, file, afterHash;
  factory CandidateProposalResult.decode(String input) {
    const invalid = FormatException('Invalid proposal result.');
    try {
      if (input.length > 16384) throw invalid;
      final d = jsonDecode(input);
      if (d is! Map<String, dynamic> ||
          d.length != 6 ||
          d['schemaVersion'] is! int ||
          d['schemaVersion'] != 1 ||
          d['path'] is! String ||
          !(d['path'] as String).startsWith('/') ||
          (d['path'] as String).length > 4096 ||
          d['file'] is! String ||
          !isCandidateSourcePath(d['file']) ||
          ['digest', 'sourceDigest', 'afterHash'].any(
            (k) => d[k] is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(d[k]),
          )) {
        throw invalid;
      }
      return CandidateProposalResult._(
        d['path'],
        d['digest'],
        d['sourceDigest'],
        d['file'],
        d['afterHash'],
      );
    } on Object {
      throw invalid;
    }
  }
}
