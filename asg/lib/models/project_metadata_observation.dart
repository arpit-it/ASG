// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:yaml/yaml.dart';

import 'project_inspection.dart';
import 'structured_proposal_json.dart';

enum ProjectMetadataStatus {
  observed,
  invalid,
  unsupported,
  changed,
  unavailable,
}

/// A bounded transport observation, never source verification or tool approval.
class ProjectMetadataObservation {
  ProjectMetadataObservation._(
    this.status,
    this.reason,
    List<int>? manifestBytes,
    List<String> runners,
  ) : manifestBytes = manifestBytes == null
          ? null
          : List<int>.unmodifiable(manifestBytes),
      includedRunners = List<String>.unmodifiable(runners);

  final ProjectMetadataStatus status;
  final String? reason;
  final List<int>? manifestBytes;
  final List<String> includedRunners;
  bool get sourceVerified => false;
  bool? get mainPresent =>
      status == ProjectMetadataStatus.observed ? true : null;

  static const responseLimit = 128 * 1024;
  static const manifestLimit = 64 * 1024;
  static const _keys = {
    'version',
    'scope',
    'status',
    'reason',
    'manifest_base64',
    'included_runners',
    'main_present',
    'source_verified',
  };
  static const _runners = [
    'android',
    'ios',
    'web',
    'macos',
    'windows',
    'linux',
  ];
  static const _reasons = {
    ProjectMetadataStatus.invalid: {
      'metadata_too_large',
      'manifest_missing',
      'source_entry_missing',
    },
    ProjectMetadataStatus.unsupported: {
      'posix_nofollow_unavailable',
      'directory_indirection',
      'root_path_subset',
      'unsafe_metadata',
    },
    ProjectMetadataStatus.changed: {
      'metadata_changed',
      'directory_changed',
      'missing_metadata_appeared',
    },
    ProjectMetadataStatus.unavailable: {
      'invalid_root',
      'read_unavailable',
      'invalid_request',
      'output_limit',
    },
  };

  static ProjectMetadataObservation parse(String raw) {
    try {
      if (utf8.encode(raw).length > responseLimit) {
        throw const FormatException();
      }
      final value = jsonDecode(raw);
      rejectDuplicateJsonMembers(raw);
      if (value is! Map<String, dynamic> ||
          value.length != _keys.length ||
          !_keys.every(value.containsKey) ||
          value['version'] is! int ||
          value['version'] != 1 ||
          value['scope'] != 'project-metadata-files' ||
          value['source_verified'] != false ||
          value['included_runners'] is! List) {
        throw const FormatException();
      }
      final status = switch (value['status']) {
        'observed' => ProjectMetadataStatus.observed,
        'invalid' => ProjectMetadataStatus.invalid,
        'unsupported' => ProjectMetadataStatus.unsupported,
        'changed' => ProjectMetadataStatus.changed,
        'unavailable' => ProjectMetadataStatus.unavailable,
        _ => throw const FormatException(),
      };
      final reason = value['reason'] as String?;
      final rawRunners = value['included_runners'] as List;
      if (status != ProjectMetadataStatus.observed) {
        if (!_reasons[status]!.contains(reason) ||
            value['manifest_base64'] != null ||
            value['main_present'] != null ||
            rawRunners.isNotEmpty) {
          throw const FormatException();
        }
        return ProjectMetadataObservation._(status, reason, null, const []);
      }
      final encoded = value['manifest_base64'];
      if (reason != null ||
          value['main_present'] != true ||
          encoded is! String ||
          encoded.length > 87384) {
        throw const FormatException();
      }
      final bytes = base64Decode(encoded);
      if (bytes.length > manifestLimit || base64Encode(bytes) != encoded) {
        throw const FormatException();
      }
      var previous = -1;
      final runners = <String>[];
      for (final runner in rawRunners) {
        if (runner is! String) throw const FormatException();
        final index = _runners.indexOf(runner);
        if (index <= previous) throw const FormatException();
        previous = index;
        runners.add(runner);
      }
      return ProjectMetadataObservation._(status, null, bytes, runners);
    } catch (_) {
      throw const FormatException('Project metadata response is invalid.');
    }
  }

  /// Pure manifest projection for the caller's frozen root; performs no IO.
  ProjectInspection toInspection(String root) {
    try {
      final bytes = manifestBytes;
      if (status != ProjectMetadataStatus.observed || bytes == null) {
        throw const FormatException();
      }
      final value = loadYaml(utf8.decode(bytes));
      if (value is! YamlMap) throw const FormatException();
      final name = value['name'];
      if (name is! String || !RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(name)) {
        throw const FormatException();
      }
      final dependencies = value['dependencies'];
      final flutter = dependencies is YamlMap ? dependencies['flutter'] : null;
      final environment = value['environment'];
      final sdk = environment is YamlMap ? environment['sdk'] : null;
      if (flutter is! YamlMap ||
          flutter['sdk'] != 'flutter' ||
          sdk is! String ||
          sdk.trim().isEmpty) {
        throw const FormatException();
      }
      return ProjectInspection(
        root: root,
        packageName: name,
        dartSdk: sdk,
        runners: includedRunners,
      );
    } catch (_) {
      throw const FormatException('Project manifest is invalid.');
    }
  }
}

/// A controller-issued one-action snapshot, not repository execution consent.
class ProjectMetadataReadRequest {
  const ProjectMetadataReadRequest({required this.root, required this.python});
  final String root, python;
}
