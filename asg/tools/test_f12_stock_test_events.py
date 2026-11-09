# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Portable refusal tests; the opt-in Flutter fixture supplies live evidence."""

import contextlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import f12_stock_test_events as events


class StockTestEventsTest(unittest.TestCase):
    def test_cli_refuses_arbitrary_source_before_dispatch(self):
        with patch.object(events, 'exercise') as exercise, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as refused:
                events.main(['--synthetic-fixture', '--sdk', '/sdk', '--source', 'candidate.dart'])
            self.assertEqual(refused.exception.code, 2)
            exercise.assert_not_called()

    def test_rejects_changed_or_linked_fixture(self):
        tools = Path(events.__file__).resolve().parent
        fixed = events.read_fixtures(tools)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = root / 'f12_stock_test_fixtures'
            fixture.mkdir()
            for name in events.FIXTURES:
                (fixture / name).write_bytes(fixed[name.removesuffix('.txt')])
            original = fixture / 'driver.dart.txt'
            original.write_bytes(fixed['driver.dart'] + b'\n')
            with self.assertRaisesRegex(ValueError, 'identity differs'):
                events.read_fixtures(root)
            original.unlink()
            original.symlink_to(tools / 'f12_stock_test_fixtures/driver.dart.txt')
            with self.assertRaises((OSError, ValueError)):
                events.read_fixtures(root)

    def test_refuses_invalid_port_receipts(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'ready.json'
            path.write_text('{"port": 12345}')
            self.assertEqual(events.read_port(path), 12345)
            for data in (
                '{"port": true}', '{"port": 0}', '{"port": 65536}',
                '{"port": 1000, "port": 12345}', '{"port": 1, "extra": 2}', '[]',
            ):
                with self.subTest(data=data):
                    path.write_text(data)
                    with self.assertRaises(ValueError):
                        events.read_port(path)

    def test_success_requires_both_families_and_a_real_expected_failure(self):
        settled = {'exitCode': 0, 'reason': None, 'waitEntered': False}
        rows = [
            dict(family=family, outcomes=events.OUTCOMES.copy(), complete=True,
                 phase='test-run', rejected=0, engineSettled=True, ingressAttached=True)
            for family in ('IPv4', 'IPv6')
        ]
        self.assertTrue(events.result_matches('positive', rows, settled))
        self.assertFalse(events.result_matches('positive', rows[:1], settled))
        self.assertFalse(events.result_matches('positive', rows[::-1], settled))
        self.assertFalse(events.result_matches('positive', rows, dict(settled, reason='cancelled')))
        rows[0]['outcomes']['fixture deliberate failure'] = 'success'
        self.assertFalse(events.result_matches('positive', rows, settled))

    def test_generated_success_requires_a_declined_offer_on_both_families(self):
        settled = {'exitCode': 0, 'reason': None, 'waitEntered': False}
        rows = [
            dict(family=family, outcomes=events.OUTCOMES.copy(), complete=True,
                 phase='test-run', rejected=0, engineSettled=True, ingressAttached=True,
                 stockOfferDeclined=True)
            for family in events.FAMILIES
        ]
        self.assertTrue(events.result_matches('generated-positive', rows, settled))
        rows[1]['stockOfferDeclined'] = False
        self.assertFalse(events.result_matches('generated-positive', rows, settled))

    def test_generated_missing_token_requires_observed_natural_exit(self):
        settled = {'exitCode': 0, 'reason': None}
        row = dict(family='IPv4', outcomes={}, phase='device-start', rejected=1,
                   engineSettled=True, failure='token-refused', ingressAttached=False,
                   stockOfferDeclined=False, engineExitCode=1)
        self.assertTrue(events.result_matches('generated-missing-token', [row], settled))
        self.assertFalse(events.result_matches('generated-missing-token',
                                              [dict(row, engineExitCode=0)], settled))

    def test_ingress_refusal_requires_the_specific_guard_receipt(self):
        settled = {'exitCode': 0, 'reason': None, 'waitEntered': False, 'wirePeerReceipt': True}
        for case, reason in events.INGRESS_CASES.items():
            with self.subTest(case=case):
                row = dict(family='IPv4', outcomes={}, phase='suite-load', rejected=0,
                           engineSettled=True, failure='ingress-refused', ingressFailure=reason,
                           ingressAttached=True, wirePeerClosed=True)
                self.assertTrue(events.result_matches(case, [row], settled))
                self.assertFalse(events.result_matches(case, [dict(row, failure='deadline')], settled))
                self.assertFalse(events.result_matches(case, [dict(row, ingressAttached=False)], settled))
                self.assertFalse(events.result_matches(case, [dict(row, wirePeerClosed=False)], settled))
                self.assertFalse(events.result_matches(case, [dict(row, ingressFailure='other')], settled))
                self.assertFalse(events.result_matches(case, [dict(row, complete=True)], settled))
                self.assertFalse(events.result_matches(case, [dict(row, engineSettled=False)], settled))
                self.assertFalse(events.result_matches(case, [row], dict(settled, reason='driver-deadline')))
                self.assertFalse(events.result_matches(case, [row], dict(settled, wirePeerReceipt=False)))

    def test_stop_requires_observed_wait_and_no_suite_receipt(self):
        stopped = {'exitCode': -15, 'reason': 'cancelled', 'waitEntered': True}
        self.assertTrue(events.result_matches('stop', None, stopped))
        self.assertFalse(events.result_matches('stop', None, dict(stopped, waitEntered=False)))
        self.assertFalse(events.result_matches('stop', [], stopped))
        self.assertFalse(events.result_matches('stop', None, dict(stopped, exitCode=0)))


if __name__ == '__main__':
    unittest.main()
