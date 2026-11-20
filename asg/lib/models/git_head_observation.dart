// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'structured_proposal_json.dart';

enum GitHeadStatus {
  observed,
  unresolved,
  notPresent,
  unsupported,
  invalid,
  changed,
  unavailable,
}

enum GitHeadForm { symbolic, directOid }

enum GitOidSource { head, looseRef }

/// Literal helper declarations only; never repository state or action authority.
class GitHeadObservation {
  const GitHeadObservation._(
    this.status,
    this.headForm,
    this.declaredRef,
    this.declaredOid,
    this.oidSource,
    this.reason,
  );
  final GitHeadStatus status;
  final GitHeadForm? headForm;
  final String? declaredRef, declaredOid, reason;
  final GitOidSource? oidSource;
  bool get gitStateVerified => false;
  String get workingTree => 'unknown';
  String get aheadBehind => 'unknown';
  String get conflict => 'unknown';

  static const _keys = {
    'version',
    'layout',
    'scope',
    'status',
    'head_form',
    'declared_ref',
    'declared_oid',
    'oid_source',
    'reason',
    'git_state_verified',
    'working_tree',
    'ahead_behind',
    'conflict',
  };
  static const _reasons = {
    GitHeadStatus.notPresent: {'no_direct_git_directory'},
    GitHeadStatus.unsupported: {
      'posix_nofollow_unavailable',
      'directory_indirection',
      'root_path_subset',
      'commondir_present',
      'gitdir_present',
      'reftable_present',
      'packed_refs_present',
      'unsafe_metadata',
    },
    GitHeadStatus.invalid: {
      'head_missing',
      'invalid_head',
      'invalid_ref',
      'metadata_too_large',
    },
    GitHeadStatus.changed: {
      'metadata_changed',
      'directory_changed',
      'missing_metadata_appeared',
      'layout_changed',
    },
    GitHeadStatus.unavailable: {
      'invalid_root',
      'read_unavailable',
      'invalid_request',
    },
  };

  static bool _oid(String? value) =>
      value != null &&
      (value.length == 40 || value.length == 64) &&
      value.codeUnits.every(
        (c) => (c >= 48 && c <= 57) || (c >= 97 && c <= 102),
      ) &&
      value.codeUnits.any((c) => c != 48);

  static bool _ref(String? value) {
    if (value == null ||
        !value.startsWith('refs/heads/') ||
        value.length > 256 ||
        value.contains('..') ||
        value.contains('@{') ||
        value.codeUnits.any(
          (c) =>
              c <= 32 ||
              c >= 127 ||
              '~^:?*[]\\'.contains(String.fromCharCode(c)),
        )) {
      return false;
    }
    final parts = value.split('/');
    return parts.length <= 16 &&
        parts.every(
          (p) =>
              p.isNotEmpty &&
              !p.startsWith('.') &&
              !p.endsWith('.') &&
              !p.endsWith('.lock'),
        );
  }

  static GitHeadObservation parse(String raw) {
    try {
      if (utf8.encode(raw).length > 4096) throw const FormatException();
      final value = jsonDecode(raw);
      rejectDuplicateJsonMembers(raw);
      if (value is! Map<String, dynamic> ||
          value.length != _keys.length ||
          !_keys.every(value.containsKey) ||
          value['version'] is! int ||
          value['version'] != 1 ||
          value['layout'] != 'direct-dotgit-files' ||
          value['scope'] != 'literal-file-declarations' ||
          value['git_state_verified'] != false ||
          value['working_tree'] != 'unknown' ||
          value['ahead_behind'] != 'unknown' ||
          value['conflict'] != 'unknown') {
        throw const FormatException();
      }
      final status = switch (value['status']) {
        'observed' => GitHeadStatus.observed,
        'unresolved' => GitHeadStatus.unresolved,
        'not_present' => GitHeadStatus.notPresent,
        'unsupported' => GitHeadStatus.unsupported,
        'invalid' => GitHeadStatus.invalid,
        'changed' => GitHeadStatus.changed,
        'unavailable' => GitHeadStatus.unavailable,
        _ => throw const FormatException(),
      };
      final form = switch (value['head_form']) {
        null => null,
        'symbolic' => GitHeadForm.symbolic,
        'direct_oid' => GitHeadForm.directOid,
        _ => throw const FormatException(),
      };
      final source = switch (value['oid_source']) {
        null => null,
        'head' => GitOidSource.head,
        'loose_ref' => GitOidSource.looseRef,
        _ => throw const FormatException(),
      };
      final ref = value['declared_ref'] as String?,
          oid = value['declared_oid'] as String?,
          reason = value['reason'] as String?;
      final valid = switch (status) {
        GitHeadStatus.observed =>
          reason == null &&
              _oid(oid) &&
              ((form == GitHeadForm.symbolic &&
                      _ref(ref) &&
                      source == GitOidSource.looseRef) ||
                  (form == GitHeadForm.directOid &&
                      ref == null &&
                      source == GitOidSource.head)),
        GitHeadStatus.unresolved =>
          reason == 'loose_ref_missing' &&
              form == GitHeadForm.symbolic &&
              _ref(ref) &&
              oid == null &&
              source == null,
        _ =>
          _reasons[status]!.contains(reason) &&
              form == null &&
              ref == null &&
              oid == null &&
              source == null,
      };
      if (!valid) throw const FormatException();
      return GitHeadObservation._(status, form, ref, oid, source, reason);
    } catch (_) {
      throw const FormatException('Git metadata response is invalid.');
    }
  }
}

/// A controller-issued, one-action snapshot, never repository execution consent.
class GitMetadataReadRequest {
  const GitMetadataReadRequest({required this.root, required this.python});
  final String root, python;
}
