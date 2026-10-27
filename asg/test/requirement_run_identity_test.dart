// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/models/requirement_check_report.dart';
import 'package:asg/models/project.dart';
import 'package:asg/services/requirement_check_report_store.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'requirement_check_report_test.dart' show Records, prepare, project;

void main() {
  final inputs = {'assets/app.json': 'a' * 64, 'asg_project.json': 'b' * 64};
  final sources = {...inputs, 'lib/main.dart': 'c' * 64};
  RequirementRunIdentity identity({
    Map<String, String>? saved,
    Map<String, String>? current,
    String? approval,
  }) => RequirementRunIdentity(
    sources: saved ?? sources,
    currentInputs: current ?? inputs,
    approvalSha256: approval ?? 'd' * 64,
  );

  test(
    'manifest ordering is stable and source/input/approval changes separate',
    () {
      final baseline = identity();
      expect(
        identity(saved: Map.fromEntries(sources.entries.toList().reversed))
            .toJson(),
        baseline.toJson(),
      );
      final sourceChange = identity(
        saved: {...sources, 'lib/main.dart': 'e' * 64},
      );
      expect(sourceChange.sourceSha256, isNot(baseline.sourceSha256));
      expect(sourceChange.savedRunSha256, isNot(baseline.savedRunSha256));
      expect(sourceChange.savedInputSha256, baseline.savedInputSha256);
      final inputChange = identity(
        saved: {...sources, 'assets/app.json': 'f' * 64},
      );
      expect(inputChange.savedInputSha256, isNot(baseline.savedInputSha256));
      expect(inputChange.savedRunSha256, isNot(baseline.savedRunSha256));
      expect(
        identity(approval: 'e' * 64).savedRunSha256,
        isNot(baseline.savedRunSha256),
      );
      final currentChange = identity(
        current: {...inputs, 'assets/app.json': 'f' * 64},
      );
      expect(
        currentChange.currentInputSha256,
        isNot(baseline.currentInputSha256),
      );
      expect(currentChange.savedRunSha256, baseline.savedRunSha256);
    },
  );

  test(
    'missing or invalid recorded inputs cannot create a usable run identity',
    () {
      for (final manifest in [
        <String, String>{},
        {'lib/main.dart': 'a' * 64},
        {'assets/app.json': 'a' * 64},
        {...sources, 'asg_project.json': 'invalid'},
      ]) {
        expect(identity(saved: manifest).savedRunSha256, isNull);
        expect(identity(saved: manifest).savedInputSha256, isNull);
      }
      expect(
        RequirementRunIdentity(
          sources: sources,
          currentInputs: inputs,
          approvalSha256: null,
        ).savedRunSha256,
        isNull,
      );
    },
  );

  test(
    'report identities survive reopen without exposing private execution data',
    () async {
      final records = Records();
      final saved = await prepare(records);
      await SourceGenerationStore(records).save(project.id, saved);
      Map<String, dynamic> report() => jsonDecode(
        RequirementCheckReportStore(records).load(project).evidenceJson,
      ) as Map<String, dynamic>;
      final first = report();
      expect(report()['revisionIdentity'], first['revisionIdentity']);
      final revision = first['revisionIdentity'] as Map;
      expect(revision['savedInputSha256'], revision['currentInputSha256']);
      expect(revision['savedRunSha256'], isNotNull);
      final requirement = (first['requirements'] as List).single as Map;
      expect(
        requirement['bindingContext']['savedRunSha256'],
        revision['savedRunSha256'],
      );
      expect(
        requirement['bindingContext']['requirementSha256'],
        requirement['acceptanceEvidence']['requirementSha256'],
      );
      expect(requirement['acceptanceStatus'], 'unverified');
      expect(jsonEncode(first), isNot(contains('PRIVATE_')));
      final changed = StudioProject(
        id: project.id,
        name: project.name,
        description: 'Changed input',
        type: project.type,
        platforms: project.platforms,
        location: project.location,
      );
      final edited = jsonDecode(
        RequirementCheckReportStore(records).load(changed).evidenceJson,
      ) as Map;
      expect(
        edited['revisionIdentity']['savedRunSha256'],
        revision['savedRunSha256'],
      );
      expect(
        edited['revisionIdentity']['currentInputSha256'],
        isNot(revision['currentInputSha256']),
      );
      expect(edited['savedInputsCurrent'], isFalse);
      final legacy = saved.toJson();
      legacy['sources'] = {'lib/main.dart': 'a' * 64};
      // Existing valid legacy snapshots need not include fixed-adapter inputs.
      records.data['studio.generation.v1.${project.id}'] = jsonEncode(legacy);
      expect(report()['revisionIdentity']['savedRunSha256'], isNull);
      expect(report()['revisionIdentity']['savedInputSha256'], isNull);
      expect(report()['savedInputsCurrent'], isFalse);
    },
  );
}
