# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Portable parser and fail-closed supervisor design regressions."""
import base64
import io
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import f12_supervisor_design as design


class Connection:
    def __init__(self, data):
        self.input = io.BytesIO(data)
        self.sent = bytearray()

    def recv(self, count):
        return self.input.read(count)

    def sendall(self, data):
        self.sent.extend(data)


def masked(payload, first=0x81):
    key = b'1234'
    size = len(payload)
    header = bytes([first, 0x80 | size]) if size < 126 else bytes([first, 0xfe]) + struct.pack('!H', size)
    return header + key + bytes(x ^ key[i % 4] for i, x in enumerate(payload))


class SupervisorTests(unittest.TestCase):
    def upgrade(self, **changes):
        values = {'first': 'GET /session HTTP/1.1', 'key': base64.b64encode(b'x' * 16).decode(), 'extra': ''}
        values.update(changes)
        return (values['first'] + '\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ' + values['key'] + '\r\n' + values['extra'] + '\r\n').encode()

    def test_reviewed_fixture_identity(self):
        self.assertEqual(len(design.fixtures()), 3)
        with patch.dict(design.FIXTURES, {'engine.dart': 'wrong'}):
            with self.assertRaises(ValueError):
                design.fixtures()

    def test_upgrade_requires_exact_session_and_strict_headers(self):
        connection = Connection(self.upgrade())
        design.upgrade(connection, 'session')
        self.assertIn(b'101 Switching Protocols', connection.sent)
        for data in [self.upgrade(first='POST /session HTTP/1.1'), self.upgrade(first='GET /stale HTTP/1.1'), self.upgrade(key='invalid'), self.upgrade(extra='Origin: http://external\r\n'), self.upgrade(extra='Sec-WebSocket-Version: 13\r\n'), self.upgrade(extra='Sec-WebSocket-Protocol: commands\r\n'), b'x' * 4097]:
            with self.subTest(data=data[:50]), self.assertRaises((ValueError, UnicodeError)):
                design.upgrade(Connection(data), 'session')

    def test_frame_rejects_unmasked_fragment_binary_control_and_huge(self):
        self.assertEqual(design.frame(Connection(masked(b'known'))), b'known')
        for data in [b'\x81\x02xx', masked(b'{}', 0x01), masked(b'{}', 0x82), masked(b'{}', 0x89), b'\x81\xff', b'\x81\xfe\x00\x01', masked(b'x' * 4097), masked(b'{}')[:-1]]:
            with self.subTest(data=data[:10]), self.assertRaises(ValueError):
                design.frame(Connection(data))

    def test_extra_frame_cannot_replace_close(self):
        stream = Connection(masked(b'{}') + masked(b'{}'))
        design.frame(stream)
        with self.assertRaises(ValueError):
            design.frame(stream, close=True)
        closed = Connection(masked(struct.pack('!H', 1000), 0x88))
        design.frame(closed, close=True)
        self.assertEqual(closed.sent, b'\x88\x02\x03\xe8')
        for data in [masked(b'x', 0x88), masked(struct.pack('!H', 1002), 0x88)]:
            with self.assertRaises(ValueError):
                design.frame(Connection(data), close=True)

    def test_session_schema_nonce_identity_boolean_and_duplicate_keys(self):
        expected = {'session': 'session', 'source': 'source', 'kernel': 'kernel'}
        value = dict(expected, schema=1, engine=True)
        self.assertEqual(design.session_message(json.dumps(value).encode(), expected), value)
        for key, item in [('session', 'old'), ('source', 'other'), ('kernel', 'other'), ('schema', True), ('engine', 1), ('command', 'run')]:
            changed = dict(value, **{key: item})
            with self.subTest(key=key), self.assertRaises(ValueError):
                design.session_message(json.dumps(changed).encode(), expected)
        with self.assertRaises(ValueError):
            design.session_message(b'{"schema":1,"schema":1}', expected)
        with self.assertRaises(UnicodeError):
            design.session_message(b'\xff', expected)

    def test_hook_output_rejects_commands_assets_failure_links_and_oversize(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'output.json'
            path.write_text('{"timestamp":"now","status":"success","assets_for_linking":{}}')
            design.hook_output(path)
            for value in [{'timestamp': 'now', 'command': 'run'}, {'timestamp': 'now', 'assets_for_linking': {'other': []}}, {'timestamp': 'now', 'status': 'failure'}, {'timestamp': 'x' * 65}, {'timestamp': True}]:
                path.write_text(json.dumps(value))
                with self.subTest(value=value), self.assertRaises(ValueError):
                    design.hook_output(path)
            path.write_text('{"timestamp":"now","timestamp":"old"}')
            with self.assertRaises(ValueError):
                design.hook_output(path)
            link = Path(directory) / 'linked'
            link.symlink_to(path)
            with self.assertRaises(OSError):
                design.hook_output(link)
            path.write_bytes(b'x' * 16385)
            with self.assertRaises(ValueError):
                design.hook_output(path)

    def test_unknown_case_refuses_before_any_tool_or_process(self):
        with patch.object(design.boundary, 'toolchain') as tool:
            with self.assertRaises(ValueError):
                design.exercise('/ignored', 'candidate')
            tool.assert_not_called()

    def test_wrong_session_and_extra_frame_require_exact_rejection(self):
        for case, reason in [('wrong-token', 'Wrong session path'), ('extra-frame', 'Only final masked text/close frames allowed')]:
            report = {'stages': {}, 'engineDispatched': True, 'broker': {'pass': False, 'error': reason}}
            self.assertTrue(design.expected_failure(case, report))
            for other in ['timed out', 'Truncated frame', 'Wrong session evidence', '']:
                report['broker']['error'] = other
                self.assertFalse(design.expected_failure(case, report))

    def test_strict_json_refuses_duplicates_and_nonfinite_numbers(self):
        for data in ['{"x":1,"x":2}', '{"x":NaN}', '{"x":Infinity}']:
            with self.assertRaises(ValueError):
                design.strict_json(data)


if __name__ == '__main__':
    unittest.main()
