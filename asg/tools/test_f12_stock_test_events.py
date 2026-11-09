# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Portable refusal tests; the opt-in Flutter fixture supplies live evidence."""

import contextlib
import io
import json
import signal
import sys
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, call, patch

import f12_stock_test_events as events


class StockTestEventsTest(unittest.TestCase):
    def test_reaped_group_absence_needs_no_kill(self):
        with patch.object(events.os, 'killpg', side_effect=ProcessLookupError) as killpg:
            self.assertIsNone(events.settle_reaped_group(123))
        killpg.assert_called_once_with(123, 0)

    def test_post_reap_kill_denial_requires_a_later_absence_probe(self):
        observations = [None, PermissionError, PermissionError, ProcessLookupError]
        with (patch.object(events.os, 'killpg', side_effect=observations) as killpg,
              patch.object(events.time, 'monotonic', side_effect=[0, .01, .02]),
              patch.object(events.time, 'sleep')):
            self.assertIsNone(events.settle_reaped_group(123))
        self.assertEqual(killpg.call_args_list, [
            call(123, 0), call(123, signal.SIGKILL), call(123, 0), call(123, 0),
        ])

    def test_unconfirmed_group_cleanup_has_a_bounded_diagnostic(self):
        for observations, message in (
            ([PermissionError, PermissionError], 'signal-zero probe denied'),
            ([None, PermissionError, None], 'post-reap SIGKILL denied'),
            ([None, None, None], 'group still present'),
        ):
            with self.subTest(message=message):
                with (patch.object(events.os, 'killpg', side_effect=observations),
                      patch.object(events.time, 'monotonic', side_effect=[0, .49, .5]),
                      patch.object(events.time, 'sleep') as sleep):
                    self.assertIn(message, events.settle_reaped_group(123))
                sleep.assert_called_once()

    def test_driver_report_retains_unconfirmed_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = {'ready': root / 'ready', 'engineDir': root}
            with patch.object(events, 'settle_reaped_group', return_value='group present') as settle:
                execution = events.run_driver(
                    [sys.executable, '-c', 'print("observed output")'],
                    root, config, root, root, 'positive',
                )
            self.assertEqual(execution['exitCode'], 0)
            self.assertEqual(execution['output'], 'observed output\n')
            self.assertFalse(execution['groupReaped'])
            self.assertEqual(execution['cleanupError'], 'group present')
            settle.assert_called_once()

    def test_emergency_cleanup_failure_preserves_original_error_and_handlers(self):
        handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGINT)}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ready = root / 'ready'
            ready.touch()
            config = {'ready': ready, 'engineDir': root}
            process = Mock(pid=123)
            process.poll.return_value = None
            process.stdout.close.side_effect = OSError('pipe close denied')
            with (patch.object(events.subprocess, 'Popen', return_value=process),
                  patch.object(events.selectors, 'DefaultSelector'),
                  patch.object(events, 'read_port', side_effect=ValueError('bad receipt')),
                  patch.object(events.os, 'killpg', side_effect=PermissionError) as killpg):
                with self.assertRaisesRegex(ValueError, 'bad receipt'):
                    events.run_driver([], root, config, root, root, 'positive')
        killpg.assert_called_once_with(123, signal.SIGKILL)
        process.stdout.close.assert_called_once()
        self.assertEqual({sig: signal.getsignal(sig) for sig in handlers}, handlers)

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

    def test_widget_overlay_uses_only_pinned_local_packages(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            sdk, cache = root / 'sdk', root / 'cache'
            tool = dict(name='flutter_tools', rootUri='../', packageUri='lib/', languageVersion='3.11')
            original = json.dumps(dict(configVersion=2, packages=[tool])).encode()
            for name in ('flutter', 'flutter_test'):
                (sdk / 'packages' / name / 'lib').mkdir(parents=True)
            for name, (version, _) in events.WIDGET_CACHE_PACKAGES.items():
                (cache / 'hosted/pub.dev' / f'{name}-{version}' / 'lib').mkdir(parents=True)
            overlay = events.widget_package_config(original, sdk, cache)
            self.assertEqual(events.widget_package_config(original, sdk, cache), overlay)
            packages = {entry['name']: entry for entry in json.loads(overlay)['packages']}
            self.assertEqual(set(packages), {'flutter_tools', 'flutter', 'flutter_test',
                                             *events.WIDGET_CACHE_PACKAGES})
            self.assertEqual(packages['flutter_tools']['rootUri'],
                             (sdk / 'packages/flutter_tools').as_uri() + '/')
            self.assertEqual(json.loads(original)['packages'][0]['rootUri'], '../')
            conflicting = json.dumps(dict(configVersion=2, packages=[tool, packages['flutter']]))
            with self.assertRaisesRegex(ValueError, 'Conflicting'):
                events.widget_package_config(conflicting, sdk, cache)
            (sdk / 'packages/flutter_test/lib').rmdir()
            with self.assertRaisesRegex(ValueError, 'unavailable: flutter_test'):
                events.widget_package_config(original, sdk, cache)

    def test_widget_receipt_requires_widget_assertions_and_stop_evidence(self):
        settled = dict(exitCode=0, reason=None, output=(
            'Found 0 widgets with text "fixture absent widget marker"\n' * 2
        ))
        rows = [
            dict(family=family, outcomes=events.WIDGET_OUTCOMES.copy(), complete=True,
                 phase='test-run', rejected=0, engineSettled=True, ingressAttached=True,
                 stockOfferDeclined=True)
            for family in events.FAMILIES
        ]
        self.assertTrue(events.result_matches('generated-widget-positive', rows, settled))
        self.assertFalse(events.result_matches('generated-widget-positive', rows,
                                              dict(settled, output='')))
        rows[1]['outcomes'] = events.OUTCOMES
        self.assertFalse(events.result_matches('generated-widget-positive', rows, settled))
        stopped = dict(exitCode=-15, reason='cancelled', waitEntered=True)
        self.assertTrue(events.result_matches('generated-widget-stop', None, stopped))
        self.assertFalse(events.result_matches('generated-widget-stop', None,
                                              dict(stopped, waitEntered=False)))

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
