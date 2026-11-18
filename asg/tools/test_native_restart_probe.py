# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
from pathlib import Path
import plistlib
import json
import tempfile
import unittest
from unittest import mock

import native_restart_probe as probe


class ProbeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='asg-probe-validation-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.bundle = self.root / 'Disposable.app'
        self.executable = self.bundle / 'Contents/MacOS/probe'
        self.executable.parent.mkdir(parents=True)
        self.executable.write_text('fixture executable')
        self.executable.chmod(0o700)
        self.plist = self.bundle / 'Contents/Info.plist'
        self.metadata(probe.BUNDLE)

    def metadata(self, identity, executable='probe'):
        self.plist.write_bytes(plistlib.dumps({'CFBundleIdentifier': identity, 'CFBundleExecutable': executable}))

    def test_inspection_is_read_only_and_identity_covers_resources(self):
        executable, first = probe.inspect_bundle(self.bundle)
        self.assertEqual(executable, self.executable)
        resource = self.bundle / 'Contents/resource'
        resource.write_text('entrypoint')
        self.assertNotEqual(first, probe.inspect_bundle(self.bundle)[1])
        self.assertFalse((self.root / 'launch-1.json').exists())

    def test_stable_identity_and_executable_escape_are_refused_before_launch(self):
        for identity, executable in [('com.arsinha.asg.asg', 'probe'), (probe.BUNDLE, '../probe')]:
            self.metadata(identity, executable)
            with mock.patch.object(probe.subprocess, 'run') as launch:
                with self.assertRaises(ValueError):
                    probe.inspect_bundle(self.bundle)
                launch.assert_not_called()

    def test_external_bundle_links_and_linked_executable_are_refused(self):
        external = self.root / 'outside'
        external.write_text('outside')
        link = self.bundle / 'Contents/external'
        link.symlink_to(external)
        with self.assertRaises(ValueError):
            probe.inspect_bundle(self.bundle)
        link.unlink()
        self.executable.unlink()
        self.executable.symlink_to(external)
        with self.assertRaises(ValueError):
            probe.inspect_bundle(self.bundle)

    def test_same_bundle_is_rechecked_before_second_launch(self):
        root = self.root / 'control'
        root.mkdir(mode=0o700)
        count = 0

        def launch(*args, **kwargs):
            nonlocal count
            count += 1
            challenge = json.loads((root / 'challenge.json').read_text())
            (root / 'launch-1.json').write_text(json.dumps({
                'version': 1, 'bundle': probe.BUNDLE, 'nonce': challenge['nonce'], 'launch': 1,
                'preferencesPersisted': False, 'support': str(self.root / probe.BUNDLE)}))
            self.executable.write_text('changed binary')
            return mock.Mock(returncode=0)

        with mock.patch.object(probe.sys, 'platform', 'darwin'), \
                mock.patch.object(probe.tempfile, 'mkdtemp', return_value=str(root)), \
                mock.patch.object(probe.subprocess, 'run', side_effect=launch):
            with self.assertRaisesRegex(ValueError, 'binary changed'):
                probe.run_probe(self.bundle)
        self.assertEqual(count, 1)

    def test_two_launches_and_explicit_preference_domain_are_required(self):
        root = self.root / 'control'
        root.mkdir(mode=0o700)
        launches = []
        def launch(command, **kwargs):
            if command[0] == '/usr/bin/defaults':
                self.assertEqual(command[2], probe.BUNDLE)
                return mock.Mock(returncode=0, stdout='a' * 32)
            challenge = json.loads((root / 'challenge.json').read_text())
            number = challenge['launch']
            launches.append(number)
            (root / f'launch-{number}.json').write_text(json.dumps({
                'version': 1, 'bundle': probe.BUNDLE, 'nonce': challenge['nonce'], 'launch': number,
                'preferencesPersisted': number == 2, 'support': str(self.root / probe.BUNDLE)}))
            return mock.Mock(returncode=0)
        with mock.patch.object(probe.sys, 'platform', 'darwin'), \
                mock.patch.object(probe.tempfile, 'mkdtemp', return_value=str(root)), \
                mock.patch.object(probe.secrets, 'token_hex', return_value='a' * 32), \
                mock.patch.object(probe.subprocess, 'run', side_effect=launch):
            result = probe.run_probe(self.bundle)
        self.assertEqual(launches, [1, 2])
        self.assertEqual(len(result['observations']), 2)

    def test_wrong_handshake_cannot_be_accepted(self):
        root = self.root / 'control'
        root.mkdir(mode=0o700)
        def launch(*args, **kwargs):
            (root / 'launch-1.json').write_text('{}')
            return mock.Mock(returncode=0)
        with mock.patch.object(probe.sys, 'platform', 'darwin'), \
                mock.patch.object(probe.tempfile, 'mkdtemp', return_value=str(root)), \
                mock.patch.object(probe.subprocess, 'run', side_effect=launch):
            with self.assertRaises(ValueError):
                probe.run_probe(self.bundle)


if __name__ == '__main__':
    unittest.main()
