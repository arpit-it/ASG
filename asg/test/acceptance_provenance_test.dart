// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/models/requirement_check_report.dart';
import 'package:asg/services/requirement_check_report_store.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'requirement_check_report_test.dart' show Records, prepare, project;
import 'support/acceptance_provenance.dart';

void main() {
  test(
    'exports exact production F10 digests without raw saved content',
    () async {
      final records = Records();
      final saved = await prepare(records);
      await SourceGenerationStore(records).save(project.id, saved);
      final report = RequirementCheckReportStore(records).load(project);
      final value = acceptanceProvenance(
        report,
        scenario: 'reviewed-candidate',
        sourceRevision: 'a' * 40,
      );
      final raw = jsonDecode(report.evidenceJson) as Map<String, dynamic>;
      expect(value['requirementSha256'], raw['requirementsBoardSha256']);
      expect(value['inputSha256'], report.revisionIdentity!.savedInputSha256);
      expect(
        value['generatedSourceSha256'],
        report.revisionIdentity!.sourceSha256,
      );
      expect(value['savedRunSha256'], report.revisionIdentity!.savedRunSha256);
      expect(value['approvalSha256'], report.revisionIdentity!.approvalSha256);
      expect(value.length, 9);
      expect(jsonEncode(value), isNot(contains('PRIVATE')));
      expect(jsonEncode(value), isNot(contains('requirementsBoard')));
      expect(
        acceptanceProvenanceLine(report, scenario: 'bounded-repair'),
        isNull,
      );
      final line = acceptanceProvenanceLine(
        report,
        scenario: 'bounded-repair',
        enabled: true,
        sourceRevision: 'a' * 40,
      )!;
      expect(jsonDecode(line.split('=').last)['scenarioId'], 'bounded-repair');
    },
  );

  test(
    'refuses absent and stale F10 evidence and invalid source/scenario',
    () async {
      final records = Records();
      void reject(
        RequirementCheckReport report, {
        String? scenario,
        String? revision,
      }) {
        expect(
          () => acceptanceProvenance(
            report,
            scenario: scenario ?? 'reviewed-candidate',
            sourceRevision: revision ?? 'a' * 40,
          ),
          throwsFormatException,
        );
      }

      reject(RequirementCheckReportStore(records).load(project));
      final saved = await prepare(records);
      await SourceGenerationStore(records).save(project.id, saved);
      final current = RequirementCheckReportStore(records).load(project);
      reject(
        RequirementCheckReport(
          current.requirementsRevision,
          current.results,
          current.evidenceJson,
          revisionIdentity: RequirementRunIdentity(
            sources: saved.sources,
            currentInputs: {
              for (final path in RequirementRunIdentity.inputPaths)
                path: 'f' * 64,
            },
            approvalSha256: current.revisionIdentity!.approvalSha256,
          ),
          savedInputsCurrent: true,
        ),
      );
      reject(current, scenario: 'PRIVATE');
      reject(current, revision: 'main');
      for (final field in ['requirementsBoardSha256']) {
        final raw = jsonDecode(current.evidenceJson) as Map<String, dynamic>;
        raw[field] = null;
        reject(
          RequirementCheckReport(
            current.requirementsRevision,
            current.results,
            jsonEncode(raw),
            revisionIdentity: current.revisionIdentity,
            savedInputsCurrent: true,
          ),
        );
      }
      reject(
        RequirementCheckReport(
          current.requirementsRevision,
          current.results,
          current.evidenceJson,
          revisionIdentity: RequirementRunIdentity(
            sources: const {},
            currentInputs: const {},
            approvalSha256: null,
          ),
          savedInputsCurrent: true,
        ),
      );
      reject(
        RequirementCheckReport(
          current.requirementsRevision,
          current.results,
          current.evidenceJson,
          revisionIdentity: current.revisionIdentity,
          savedInputsCurrent: false,
        ),
      );
    },
  );
}
