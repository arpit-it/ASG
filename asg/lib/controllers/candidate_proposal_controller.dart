// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:math';

import '../models/candidate_source_proposal.dart';
import '../services/self_snapshot.dart';
import 'base_controller.dart';

typedef ProposalRead = Future<CandidateSourceFile> Function({
  required String snapshot,
  required String file,
  required String python,
  required Future<void> stop,
  required bool Function() stopped,
});
typedef ProposalApply = Future<CandidateProposalResult> Function({
  required CandidateSourceProposal proposal,
  required Future<void> stop,
  required bool Function() stopped,
});

class CandidateProposalController extends BaseController {
  CandidateProposalController({
    required this.snapshot,
    required this.python,
    this.trustedSource = '',
    ProposalRead? read,
    ProposalApply? apply,
    Future<String> Function(String)? canonicalize,
  }) : _read = read ?? readCandidateProposalSource,
       _apply = apply ?? applyCandidateProposal,
       _canonicalize = canonicalize ?? canonicalProposalDirectory;
  final String snapshot, python, trustedSource;
  final ProposalRead _read;
  final ProposalApply _apply;
  final Future<String> Function(String) _canonicalize;
  CandidateSourceFile? _source;
  CandidateSourceProposal? _proposal;
  CandidateProposalResult? _result;
  Completer<void>? _stop;
  int _epoch = 0;
  bool _reviewing = false;
  String? _status;
  CandidateSourceFile? get source => _source;
  CandidateProposalResult? get result => _result;
  String? get status => _status;
  bool get busy => _stop != null || _reviewing;
  bool get stopping => _stop?.isCompleted ?? false;
  bool isCurrent(CandidateSourceProposal proposal) =>
      !isDisposed && identical(_proposal, proposal);

  void invalidate({bool sourceChanged = false}) {
    _epoch++;
    _proposal = null;
    _result = null;
    if (sourceChanged) _source = null;
    _status = null;
    update();
  }

  Future<void> load(String file) async {
    if (busy || isDisposed) return;
    invalidate(sourceChanged: true);
    if (!isCandidateSourcePath(file)) {
      _status = 'Choose an existing Dart file under asg/lib or asg/test.';
      update();
      return;
    }
    final epoch = _epoch;
    final stop = Completer<void>();
    _stop = stop;
    _status = 'Reading candidate source…';
    update();
    try {
      final value = await _read(
        snapshot: snapshot,
        file: file,
        python: python,
        stop: stop.future,
        stopped: () => stop.isCompleted,
      );
      if (stop.isCompleted || isDisposed || epoch != _epoch) return;
      if (value.path != file) {
        throw const FormatException('Source differs from selection.');
      }
      _source = value;
      _status =
          'Source captured. Edit a replacement, then review its destination.';
    } catch (_) {
      if (!isDisposed && epoch == _epoch) {
        _status = 'Could not read bounded candidate source.';
      }
    } finally {
      if (stop.isCompleted && !isDisposed) _status = 'Source read stopped.';
      _stop = null;
      update();
    }
  }

  Future<CandidateSourceProposal?> review({
    required String replacement,
    required String destination,
  }) async {
    if (busy || isDisposed || _source == null) return null;
    _proposal = null;
    _result = null;
    final epoch = ++_epoch;
    final captured = _source!;
    _reviewing = true;
    update();
    try {
      final target = await _canonicalize(destination);
      final trusted = trustedSource.isEmpty
          ? ''
          : await _canonicalize(trustedSource);
      if (isDisposed || epoch != _epoch) return null;
      final proposal = CandidateSourceProposal.create(
        snapshot: snapshot,
        python: python,
        trustedSource: trusted,
        source: captured,
        replacement: replacement,
        destination: target,
        runName:
            'asg-self-candidate-${Random.secure().nextInt(0x100000000).toRadixString(16).padLeft(8, "0")}',
      );
      _proposal = proposal;
      _status = null;
      return proposal;
    } on FormatException catch (error) {
      if (!isDisposed && epoch == _epoch) _status = error.message;
    } catch (_) {
      if (!isDisposed && epoch == _epoch) _status = 'Choose an accessible destination outside the source and candidate.';
    } finally {
      _reviewing = false;
      update();
    }
    return null;
  }

  Future<void> apply(
    CandidateSourceProposal proposal, {
    required bool approved,
  }) async {
    if (!approved || busy || !isCurrent(proposal)) return;
    _proposal = null;
    _result = null;
    _source = null;
    final epoch = ++_epoch;
    final stop = Completer<void>();
    _stop = stop;
    _status = 'Creating a new unverified snapshot…';
    update();
    try {
      final result = await _apply(
        proposal: proposal,
        stop: stop.future,
        stopped: () => stop.isCompleted,
      );
      if (stop.isCompleted || isDisposed || epoch != _epoch) return;
      if (result.sourceDigest != proposal.source.digest ||
          result.file != proposal.source.path ||
          result.afterHash != proposal.afterHash ||
          result.path !=
              '${proposal.destination}/${proposal.runName}/${proposal.snapshot.split('/').last}') {
        throw const FormatException('Proposal result differs from consent.');
      }
      _result = result;
      _status = 'New snapshot is unverified. Use it for a fresh comparison; previous checks and approval do not carry forward.';
    } catch (_) {
      if (!isDisposed && epoch == _epoch) {
        _status =
            'Proposal failed. Inspect the destination run ${proposal.destination}/${proposal.runName}, if present, for incomplete or unverified output before retrying.';
      }
    } finally {
      if (stop.isCompleted && !isDisposed) {
        _status =
            'Proposal stopped. Inspect the destination run ${proposal.destination}/${proposal.runName}, if present, for incomplete or unverified output before retrying.';
      }
      _stop = null;
      update();
    }
  }

  void stop() {
    final current = _stop;
    if (current == null) {
      if (_reviewing) {
        _epoch++;
        _proposal = null;
        _status = 'Proposal review stopped.';
        update();
      }
      return;
    }
    if (current.isCompleted) return;
    _epoch++;
    _proposal = null;
    current.complete();
    update();
  }

  @override
  void dispose() {
    _epoch++;
    _proposal = null;
    final current = _stop;
    if (current != null && !current.isCompleted) current.complete();
    super.dispose();
  }
}
