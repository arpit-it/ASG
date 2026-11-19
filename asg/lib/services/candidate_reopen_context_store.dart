// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/agent_session.dart';
import '../models/candidate_reopen_context.dart';
import '../models/candidate_verification_run.dart';
import '../models/project.dart';
import '../models/source_generation.dart';
import 'agent_session_admission.dart';
import 'agent_session_run_status_store.dart';
import 'agent_session_store.dart';
import 'candidate_verification_store.dart';
import 'record_storage.dart';
import 'source_generation_store.dart';

/// Validates retained context only. No load reconciles, writes or starts a host.
class CandidateReopenContextStore {
  CandidateReopenContextStore(this.records, this.project);
  final ConditionalRecordStorage records;
  final StudioProject project;
  static const prefix = CandidateReopenContext.prefix;
  static String keyFor(String projectId, int runNumber) =>
      '$prefix$projectId.$runNumber';

  static CandidateReopenContext decode(String key, String raw) {
    try {
      final context = CandidateReopenContext.decode(raw);
      if (context.storageKey != key) throw const FormatException();
      return context;
    } catch (_) {
      throw const FormatException(
        'Saved candidate reopen context is unavailable.',
      );
    }
  }

  CandidateReopenContext loadLatest(AgentSession selected, int runNumber) {
    try {
      final saved = AgentSessionStore(
        records,
        project,
      ).load(selected.sessionId);
      if (saved == null ||
          saved.cancellationRequested ||
          saved.projectId != project.id ||
          jsonEncode(saved.toJson()) != jsonEncode(selected.toJson()) ||
          saved.dispatches.isEmpty ||
          saved.dispatches.last.runNumber != runNumber) {
        throw const FormatException();
      }
      AgentSessionAdmission(records, project).requireApproval(saved);
      final journal = CandidateVerificationStore(records, project.id);
      final savedJournal = journal.load();
      if (records.getString(journal.key) != jsonEncode(savedJournal.toJson())) {
        throw const FormatException();
      }
      final run = savedJournal.runs.last;
      if (run.number != runNumber ||
          run.dispatchId != saved.dispatches.last.dispatchId) {
        throw const FormatException();
      }
      final raw = records.getString(keyFor(project.id, runNumber));
      if (raw == null) throw const FormatException();
      final context = decode(keyFor(project.id, runNumber), raw);
      context.requireRun(run);
      if (jsonEncode(context.session.toJson()) != jsonEncode(saved.toJson())) {
        throw const FormatException();
      }
      final candidateRaw = records.getString(journal.candidateKey);
      if (candidateRaw == null) throw const FormatException();
      final candidate = GeneratedProject.fromJson(jsonDecode(candidateRaw));
      if (candidateRaw != jsonEncode(candidate.toJson())) {
        throw const FormatException();
      }
      if (jsonEncode(candidate.toJson()) != jsonEncode(run.snapshot.toJson())) {
        // Explicit acknowledgment changes the journal's phase, not the saved
        // candidate. Only its exact before/after fingerprints justify this gap.
        final acknowledgement = journal.acknowledgementFor(run);
        final before = CandidateVerificationRun(
          number: run.number,
          startedAt: run.startedAt,
          snapshot: candidate,
          finished: false,
          dispatchId: run.dispatchId,
        );
        if (acknowledgement == null ||
            acknowledgement.beforeFingerprint !=
                sha256
                    .convert(utf8.encode(jsonEncode(before.toJson())))
                    .toString()) {
          throw const FormatException();
        }
      }
      final working = records.getString('studio.generation.v1.${project.id}');
      if (working == null ||
          !context.basis.matchesWorkingRecord(working) ||
          jsonEncode(
                SourceGenerationStore(records).load(project.id)?.toJson(),
              ) !=
              jsonEncode(context.basis.working.toJson())) {
        throw const FormatException();
      }
      final status = AgentSessionRunStatusStore(records, project.id)
          .load(saved)
          .singleWhere((item) => item.reference.runNumber == runNumber);
      if (!status.available || status.taskHistory == null) {
        throw const FormatException();
      }
      return context;
    } catch (_) {
      throw const FormatException(
        'This saved candidate cannot be reopened. Existing history is retained.',
      );
    }
  }

  void requireUnchanged(CandidateReopenContext expected) {
    final current = loadLatest(expected.session, expected.runNumber);
    if (jsonEncode(current.toJson()) != jsonEncode(expected.toJson())) {
      throw const FormatException('Saved candidate context changed.');
    }
  }
}
