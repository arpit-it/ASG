# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Portable deterministic boundary defenses; live Mac probes use explicit CLI."""
import contextlib
import io
import json
import os
from pathlib import Path
import socket
import tempfile
import unittest
from unittest.mock import patch

import f12_runner_boundary as boundary


class BoundaryTests(unittest.TestCase):
    def message(self):
        return dict(schemaVersion=1, stage='engine', family='127.0.0.1', nonce='session',
                    sourceHash='source', kernelHash='kernel', observations={key: True for key in
                    ('engineApi', 'readDenied', 'writeDenied', 'spawnDenied', 'canaryV4Denied', 'canaryV6Denied')})

    def parse(self, data):
        return boundary.broker_message(data, nonce='session', source_hash='source', kernel_hash='kernel')

    def test_fixed_fixture_bytes_are_reviewed(self):
        self.assertEqual(set(boundary.fixture_sources()), set(boundary.FIXTURES))
        with patch.dict(boundary.FIXTURES, {'hook_probe.dart': 'unreviewed'}):
            with self.assertRaisesRegex(ValueError, 'identity'):
                boundary.fixture_sources()

    def test_protocol_accepts_exact_frame_only(self):
        good = json.dumps(self.message()).encode() + b'\n'
        self.assertEqual(self.parse(good)['stage'], 'engine')
        bad = [good[:-1], good + b'\n', good + b'{}', b'x' * (boundary.FRAME_LIMIT + 1),
               b'[]\n', b'{}\n', good.replace(b'"stage": "engine"', b'"stage":"engine","stage":"engine"')]
        for frame in bad:
            with self.subTest(frame=frame[:30]), self.assertRaises((ValueError, TypeError)):
                self.parse(frame)

    def test_protocol_binds_every_session_identity_and_boolean(self):
        mutations = [('schemaVersion', True), ('stage', 'compile'), ('family', 'external'),
                     ('nonce', 'old-session'), ('sourceHash', 'other'), ('kernelHash', 'other')]
        for key, value in mutations:
            message = self.message()
            message[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.parse(json.dumps(message).encode() + b'\n')
        for value in (False, 1, 'true', None):
            message = self.message()
            message['observations']['readDenied'] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.parse(json.dumps(message).encode() + b'\n')
        message = self.message()
        message['observations']['unexpected'] = True
        with self.assertRaises(ValueError):
            self.parse(json.dumps(message).encode() + b'\n')

    def test_profiles_confine_stages_and_exact_port(self):
        compiler = boundary.profile('/sdk', '/source', '/compile')
        self.assertNotIn('network-', compiler)
        self.assertNotIn('process-fork', compiler)
        self.assertIn('SYS_posix_spawn', compiler)
        self.assertNotIn('/engine', compiler)
        engine = boundary.profile('/sdk', '/source', '/engine', kernel='/compile/fixed.dill', port=43210)
        self.assertEqual(engine.count('network-outbound'), 1)
        self.assertIn('localhost:43210', engine)
        self.assertNotIn('network-inbound', engine)
        for port in (0, 65536, True, '43210'):
            with self.assertRaises(ValueError):
                boundary.profile('/sdk', '/source', '/engine', port=port)

    def test_regular_files_refuse_links_special_and_oversize(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = root / 'file'
            original.write_bytes(b'fixed')
            self.assertEqual(boundary.regular_bytes(original, 5), b'fixed')
            with self.assertRaises(ValueError):
                boundary.regular_bytes(original, 4)
            linked = root / 'linked'
            linked.symlink_to(original)
            with self.assertRaises(OSError):
                boundary.regular_bytes(linked, 5)
            hard = root / 'hard'
            os.link(original, hard)
            with self.assertRaises(ValueError):
                boundary.regular_bytes(original, 5)
            fifo = root / 'fifo'
            os.mkfifo(fifo)
            with self.assertRaises(ValueError):
                boundary.regular_bytes(fifo, 5)

    def test_unknown_sdk_fails_before_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / 'bin/cache').mkdir(parents=True)
            (root / 'bin/cache/flutter.version.json').write_text('{"frameworkRevision":"unknown"}')
            with self.assertRaisesRegex(ValueError, 'reviewed Flutter'):
                boundary.toolchain(root)

    def test_both_address_families_are_owned_until_release(self):
        ports = boundary.OwnedPorts()
        port = ports.port
        try:
            for family, host in ((socket.AF_INET, '127.0.0.1'), (socket.AF_INET6, '::1')):
                with socket.socket(family, socket.SOCK_STREAM) as outsider:
                    if family == socket.AF_INET6:
                        outsider.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                    with self.assertRaises(OSError):
                        outsider.bind((host, port))
        finally:
            ports.close()
        self.assertEqual(ports.sockets, [])
        for family, host in ((socket.AF_INET, '127.0.0.1'), (socket.AF_INET6, '::1')):
            with socket.socket(family, socket.SOCK_STREAM) as released:
                released.bind((host, port))

    def test_second_family_failure_releases_first(self):
        first = unittest.mock.Mock()
        first.getsockname.return_value = ('127.0.0.1', 43210)
        with patch.object(boundary.socket, 'socket', side_effect=[first, OSError('v6 unavailable')]):
            with self.assertRaises(OSError):
                boundary.OwnedPorts()
        first.close.assert_called_once()

    def test_failed_preparation_never_launches_engine(self):
        for failure in ('hook', 'compile', 'missing-kernel', 'corrupt-kernel', 'changed-tools'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                tools = {key: root / key for key in ('dart', 'aot', 'frontend', 'platform', 'engine', 'icu')}
                stages = []
                def stage(argv, cwd, env, policy, **kwargs):
                    stages.append(cwd.name)
                    result = dict(exitCode=0, reason=None, groupReaped=True,
                                  output=json.dumps({k: True for k in ('readDenied', 'writeDenied', 'spawnDenied', 'networkDenied')}))
                    if cwd.name == failure:
                        result['exitCode'] = 2
                    if cwd.name == 'compile' and failure != 'missing-kernel':
                        (cwd / 'engine.dill').write_bytes(b'bad' if failure == 'corrupt-kernel' else b'\x90\xab\xcd\xeffixed')
                    return result
                chain = (root, {}, tools, {'identity': 'first'})
                chains = [chain, (root, {}, tools, {'identity': 'changed'}), (root, {}, tools, {'identity': 'changed'})] if failure == 'changed-tools' else None
                with patch.object(boundary.platform, 'system', return_value='Darwin'), \
                        patch.object(boundary.threading, 'active_count', return_value=1), \
                        patch.object(boundary, 'toolchain', side_effect=chains, return_value=chain), \
                        patch.object(boundary, 'run_stage', side_effect=stage):
                    report = boundary.exercise(root)
                self.assertFalse(report['pass'])
                self.assertNotIn('engine', stages)
                self.assertTrue(report['sentinelPreserved'])
                # Only roots created by this isolated mocked exercise are removed.
                import shutil
                shutil.rmtree(report['run'])

    def test_cli_cannot_accept_candidate_source_or_command(self):
        for extra in ('--source', '--command', '--entrypoint'):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                boundary.main(['--synthetic-fixture', '--sdk', '/sdk', extra, 'untrusted'])
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            boundary.main(['--sdk', '/sdk'])


if __name__ == '__main__':
    unittest.main()
