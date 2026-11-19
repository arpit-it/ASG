// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/agent_session.dart';
import '../models/project.dart';
import '../models/published_task_evidence.dart';
import '../models/requirement_check_report.dart';
import 'agent_session_admission.dart';
import 'agent_session_publication_store.dart';
import '../models/agent_execution_checkpoint.dart';
import 'application_store.dart';
import '../models/candidate_verification_run.dart';
import 'generation_input.dart';
import 'manual_check_observation_store.dart';
import 'named_check_observation_store.dart';
import 'record_storage.dart';
import 'requirement_check_report_store.dart';
import 'requirements_store.dart';

/// No command, file inspection, host, test runner or write service is created.
class PublishedTaskEvidenceStore {
  PublishedTaskEvidenceStore(this.records, this.project);
  final RecordStorage records;
  final StudioProject project;
  PublishedTaskEvidence load(AgentSession selected, int runNumber) {
    try {
      if (selected.projectId != project.id) throw const FormatException();
      final reference = selected.dispatches.singleWhere(
        (ref) => ref.runNumber == runNumber,
      );
      final keys = [
        selected.storageKey,
        'studio.candidateChecks.v1.${project.id}',
        'studio.agentExecution.v1.${reference.dispatchId.split(':').first}',
        '${AgentSessionPublicationStore.prefix}${project.id}.$runNumber',
        'studio.generation.v1.${project.id}',
        'studio.projects.v1',
        RequirementsStore.key(project.id),
        'studio.application.v1.${project.id}',
        'studio.chat.v1.${project.id}',
        'studio.planApproval.v1.${project.id}',
        NamedCheckObservationStore.key(project.id),
        ManualCheckObservationStore.key(project.id),
      ];
      final before = {for (final key in keys) key: records.getString(key)};
      if (before[selected.storageKey] != jsonEncode(selected.toJson())) {
        throw const FormatException();
      }
      final run = CandidateVerificationJournal.fromJson(
        jsonDecode(before['studio.candidateChecks.v1.${project.id}']!)
            as Map<String, dynamic>,
      ).runs.singleWhere((run) => run.number == runNumber);
      final execution = AgentExecutionCheckpoint.fromJson(
        jsonDecode(
          before['studio.agentExecution.v1.${reference.dispatchId.split(':').first}']!,
        ),
      );
      final publication = AgentSessionPublicationStore(
        records,
        project.id,
      ).load(session: selected, run: run, execution: execution);
      if (publication == null ||
          publication.dispatchId != reference.dispatchId) {
        throw const FormatException();
      }
      publication.requireRun(run);
      final rawWorking = before['studio.generation.v1.${project.id}'];
      if (rawWorking == null ||
          sha256.convert(utf8.encode(rawWorking)).toString() !=
              publication.publishedWorkingSha256) {
        throw const FormatException();
      }
      AgentSessionAdmission(records, project).requireApproval(selected);
      final report = RequirementCheckReportStore(records).load(project);
      final identity = RequirementRunIdentity(
        sources: run.snapshot.sources,
        currentInputs: GenerationInput(
          project,
          ApplicationStore(records).load(project).definition,
        ).fingerprints,
        approvalSha256: sha256
            .convert(utf8.encode(jsonEncode(run.snapshot.approval!.toJson())))
            .toString(),
      );
      if (!report.savedInputsCurrent ||
          identity.savedRunSha256 == null ||
          jsonEncode(report.revisionIdentity?.toJson()) !=
              jsonEncode(identity.toJson()) ||
          jsonEncode(report.savedProject?.toJson()) !=
              jsonEncode(run.snapshot.toJson())) {
        throw const FormatException();
      }
      final task = selected.tasks.items.singleWhere(
        (task) => task.id == reference.boardTaskId,
      );
      final requirement = report.results
          .singleWhere((result) => result.requirement.id == task.requirementId)
          .requirement;
      final value = PublishedTaskEvidence.fromReport(
        publication: publication,
        requirement: requirement,
        report: report,
        withdrawn: selected.cancellationRequested,
      );
      if (before.entries.any(
        (entry) => records.getString(entry.key) != entry.value,
      )) {
        throw const FormatException();
      }
      return value;
    } catch (_) {
      throw const FormatException(
        'Published task evidence is unavailable for this saved selection. Publication, working output, session, Plan or saved inputs changed, or required evidence is missing. Existing history is retained.',
      );
    }
  }
}
