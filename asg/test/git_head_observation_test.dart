// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/models/git_head_observation.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> observation() => {
  'version': 1,
  'layout': 'direct-dotgit-files',
  'scope': 'literal-file-declarations',
  'status': 'observed',
  'head_form': 'symbolic',
  'declared_ref': 'refs/heads/main',
  'declared_oid': 'a' * 40,
  'oid_source': 'loose_ref',
  'reason': null,
  'git_state_verified': false,
  'working_tree': 'unknown',
  'ahead_behind': 'unknown',
  'conflict': 'unknown',
};

void main() {
  test('literal symbolic and direct declarations never verify Git state', () {
    for (final width in [40, 64]) {
      final symbolic = observation()..['declared_oid'] = 'b' * width;
      final value = GitHeadObservation.parse(jsonEncode(symbolic));
      expect(value.status, GitHeadStatus.observed);
      expect(value.declaredRef, 'refs/heads/main');
      expect(value.gitStateVerified, isFalse);
      expect([
        value.workingTree,
        value.aheadBehind,
        value.conflict,
      ], everyElement('unknown'));
      final direct = {
        ...symbolic,
        'head_form': 'direct_oid',
        'declared_ref': null,
        'oid_source': 'head',
      };
      expect(
        GitHeadObservation.parse(jsonEncode(direct)).headForm,
        GitHeadForm.directOid,
      );
    }
  });
  test('missing loose target remains unresolved, never unborn', () {
    final map = {
      ...observation(),
      'status': 'unresolved',
      'reason': 'loose_ref_missing',
      'declared_oid': null,
      'oid_source': null,
    };
    final value = GitHeadObservation.parse(jsonEncode(map));
    expect(value.status, GitHeadStatus.unresolved);
    expect(value.declaredRef, 'refs/heads/main');
    expect(value.declaredOid, isNull);
  });
  test('fixed refusal states contain no declarations', () {
    for (final pair in [
      ('not_present', 'no_direct_git_directory'),
      ('unsupported', 'packed_refs_present'),
      ('invalid', 'invalid_head'),
      ('changed', 'metadata_changed'),
      ('unavailable', 'read_unavailable'),
    ]) {
      final map = {
        ...observation(),
        'status': pair.$1,
        'reason': pair.$2,
        'head_form': null,
        'declared_ref': null,
        'declared_oid': null,
        'oid_source': null,
      };
      expect(GitHeadObservation.parse(jsonEncode(map)).declaredOid, isNull);
      expect(
        () => GitHeadObservation.parse(
          jsonEncode({...map, 'declared_oid': 'a' * 40}),
        ),
        throwsFormatException,
      );
    }
  });
  test('verified or known working state is rejected', () {
    for (final change in [
      {'git_state_verified': true},
      {'working_tree': 'clean'},
      {'ahead_behind': 0},
      {'conflict': 'none'},
      {'extra': 'private-sentinel'},
    ]) {
      expect(
        () =>
            GitHeadObservation.parse(jsonEncode({...observation(), ...change})),
        throwsFormatException,
      );
    }
  });
  test('duplicate and escaped keys cannot override protocol policy', () {
    final raw = jsonEncode(observation());
    for (final key in [
      '"version":1,"version":1',
      r'"version":1,"\u0076ersion":1',
    ]) {
      expect(
        () => GitHeadObservation.parse(raw.replaceFirst('"version":1', key)),
        throwsFormatException,
      );
    }
  });
  test('invalid input has fixed private diagnostics and size limit', () {
    for (final raw in [
      'private-sentinel',
      '{"version":',
      '[]',
      'x' * 4097,
      jsonEncode({...observation(), 'version': true}),
      jsonEncode({...observation(), 'reason': 'private-sentinel'}),
    ]) {
      expect(
        () => GitHeadObservation.parse(raw),
        throwsA(
          isA<FormatException>()
              .having(
                (e) => e.message,
                'fixed message',
                'Git metadata response is invalid.',
              )
              .having((e) => e.source, 'no raw source', isNull),
        ),
      );
    }
  });
  test('contradictory and unsupported declarations are rejected', () {
    for (final change in [
      {'declared_ref': 'refs/heads/../secret'},
      {'declared_ref': 'refs/heads/a.lock'},
      {'declared_ref': 'refs/heads/a@{b'},
      {'declared_oid': 'a' * 40 + '\n'},
      {'declared_oid': '0' * 40},
      {'oid_source': 'head'},
      {'head_form': 'direct_oid'},
      {'status': 'unborn'},
    ]) {
      expect(
        () =>
            GitHeadObservation.parse(jsonEncode({...observation(), ...change})),
        throwsFormatException,
      );
    }
  });
}
