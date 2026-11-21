// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:asg/models/imported_commit_edit_request.dart';
import 'package:asg/models/imported_commit_copy_request.dart';
import 'package:asg/models/imported_commit_copy_record.dart';
import 'package:asg/models/imported_commit_copy_recheck.dart';
import 'package:asg/models/imported_commit_proposal_record.dart';

import 'imported_commit_proposal_record_test.dart' show historicalRecord;
import 'imported_commit_copy_record_test.dart' show copyResult;
import 'imported_commit_copy_recheck_test.dart' show recheckResult;

({
  ImportedCommitCopyRecord history,
  ImportedCommitCopyRecheckRequest read,
  ImportedCommitCopyRecheckObservation result,
})
editBasis(ImportedCommitProposalRecord proposal) {
  final original = ImportedCommitCopyRequest.create(
    saved: proposal,
    python: '/trusted/python',
    destination: '/copies',
    attemptId: 'a' * 32,
  );
  final history = ImportedCommitCopyRecord.empty(proposal.root)
      .begin(original, DateTime.utc(2026))
      .settle(original, copyResult(original), DateTime.utc(2026));
  final read = ImportedCommitCopyRecheckRequest.create(
    history: history,
    python: '/fresh/python',
    recheckId: 'b' * 32,
  );
  return (history: history, read: read, result: recheckResult(read));
}

void main() {
  ImportedCommitEditRequest request({
    ImportedCommitProposalRecord? current,
    String status = 'matching',
    String destination = '/new-output',
    String python = '/fresh/python',
    String attempt = 'c',
  }) {
    final saved = historicalRecord(), basis = editBasis(saved);
    return ImportedCommitEditRequest.create(
      copyHistory: basis.history,
      proposal: current ?? saved,
      reviewed: basis.read,
      observation: recheckResult(basis.read, status: status),
      python: python,
      destination: destination,
      attemptId: attempt * 32,
    );
  }

  test('isolated intent binds complete copy, current replacement and literal bytes without execution authority', () {
    final value = request(), saved = historicalRecord();
    final data = jsonDecode(value.requestJson) as Map;
    expect(value.selectedPath, 'lib/main.dart');
    expect(value.replacement, saved.proposal.replacement);
    expect(value.beforeHash, saved.proposal.source.source.digest);
    expect(
      value.afterHash,
      sha256.convert(utf8.encode(value.replacement)).toString(),
    );
    expect(value.mode, '100644');
    expect(data['proposal_history_sha256'], saved.digest);
    expect(data['recheck_request_sha256'], editBasis(saved).read.digest);
    expect(data['copy_history_sha256'], editBasis(saved).history.digest);
    expect(value.sourceVerified, false);
    expect(value.authorizesExecution, false);
    expect(value.requestJson, isNot(contains('before_text')));
  });
  test('changed refused foreign current proposal or runtime cannot borrow matching read', () {
    for (final status in ['changed', 'refused']) {
      expect(() => request(status: status), throwsFormatException);
    }
    expect(
      () => request(current: historicalRecord(after: 'different replacement')),
      throwsFormatException,
    );
    expect(
      () => request(current: historicalRecord(planText: 'different plan')),
      throwsFormatException,
    );
    expect(
      () => request(current: historicalRecord(before: 'different source')),
      throwsFormatException,
    );
    expect(() => request(python: '/other/python'), throwsFormatException);
  });
  test(
    'destination must be canonical outside original and private baseline run',
    () {
      for (final destination in [
        '/project/output',
        '/PROJECT/output',
        '/copies/asg-self-candidate-1234abcd',
        '/copies/asg-self-candidate-1234abcd/other',
        '/fresh',
        '/Stable.app/output',
        'relative',
        '/new/../output',
      ]) {
        expect(() => request(destination: destination), throwsFormatException);
      }
      expect(request(destination: '/copies').destination, '/copies');
    },
  );
  test('fresh attempt identifier is exact bounded nonzero lower hex', () {
    for (final attempt in ['0', 'A', 'z', '']) {
      expect(() => request(attempt: attempt), throwsFormatException);
    }
  });
  test('BOM presence and exact supported legal header are preserved including CRLF', () {
    const header =
        '// SPDX-License-Identifier: MPL-2.0\r\n// Copyright 2026 Example\r\n';
    expect(
      ImportedCommitEditRequest.preservesFormat(
        '\ufeff${header}before\r\n',
        '\ufeff${header}after\r\n',
      ),
      true,
    );
    expect(
      ImportedCommitEditRequest.preservesFormat(
        '\ufeff${header}before\r\n',
        '${header}after\r\n',
      ),
      false,
    );
    expect(
      ImportedCommitEditRequest.preservesFormat(
        '${header}before\r\n',
        '\ufeff${header}after\r\n',
      ),
      false,
    );
    expect(
      ImportedCommitEditRequest.preservesFormat(
        '${header}before\r\n',
        '// Copyright changed\nnew',
      ),
      false,
    );
    expect(
      ImportedCommitEditRequest.preservesFormat(
        '/* Copyright Example */\nold',
        '/* Copyright Example */\nnew',
      ),
      true,
    );
    expect(
      ImportedCommitEditRequest.preservesFormat(
        'code\n// copyright below\n',
        'code changed',
      ),
      false,
    );
  });
  test('typed draft refuses removal of an existing legal header before native entry', () {
    final saved = historicalRecord(
          before: '\ufeff// Copyright Example\r\nold',
          after: '\ufeff// Copyright Example\r\nnew',
        ),
        basis = editBasis(saved);
    final good = ImportedCommitEditRequest.create(
      copyHistory: basis.history,
      proposal: saved,
      reviewed: basis.read,
      observation: basis.result,
      python: '/fresh/python',
      destination: '/output',
      attemptId: 'c' * 32,
    );
    expect(good.replacement.startsWith('\ufeff// Copyright Example\r\n'), true);
    final bad = historicalRecord(
          before: '\ufeff// Copyright Example\r\nold',
          after: '\ufeffnew',
        ),
        badBasis = editBasis(bad);
    expect(
      () => ImportedCommitEditRequest.create(
        copyHistory: badBasis.history,
        proposal: bad,
        reviewed: badBasis.read,
        observation: badBasis.result,
        python: '/fresh/python',
        destination: '/output',
        attemptId: 'c' * 32,
      ),
      throwsFormatException,
    );
  });
}
