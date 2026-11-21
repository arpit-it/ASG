# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Owned independent pack/index fixtures; never executes Git or project code."""
import hashlib
import struct
import unittest
import zlib

import imported_pack_objects as subject


def word(value):
    return struct.pack('!I', value)


def fixture():
    pack = b'PACK' + word(2) + word(2)
    records = []
    for body in (b'first', b'second'):
        raw = bytes([0x30 + len(body)]) + zlib.compress(body)
        name = hashlib.sha1(b'blob ' + str(len(body)).encode() + b'\0' + body).digest()
        records.append((name, len(pack), zlib.crc32(raw) & 0xffffffff, len(raw)))
        pack += raw
    checksum = hashlib.sha1(pack).digest()
    pack += checksum
    ordered = sorted(records)
    index = b'\xfftOc' + word(2)
    index += b''.join(word(sum(name[0] <= i for name, _, _, _ in records)) for i in range(256))
    index += b''.join(name for name, _, _, _ in ordered)
    index += b''.join(word(crc) for _, _, crc, _ in ordered)
    index += b''.join(word(offset) for _, offset, _, _ in ordered)
    index += checksum
    return pack, index + hashlib.sha1(index).digest(), records


def reseal(raw):
    return raw[:-20] + hashlib.sha1(raw[:-20]).digest()


class PackIndexTest(unittest.TestCase):
    def setUp(self):
        self.pack, self.index, self.records = fixture()

    def parse(self, raw=None, header=None, trailer=None, size=None, check=lambda: None):
        return subject.parse_index(self.index if raw is None else raw,
                                   self.pack[:12] if header is None else header,
                                   self.pack[-20:] if trailer is None else trailer,
                                   len(self.pack) if size is None else size, check)

    def test_declared_geometry_does_not_verify_pack_contents(self):
        value = self.parse()
        self.assertEqual(value.object_count, 2)
        self.assertEqual(value.index_sha256, hashlib.sha256(self.index).hexdigest())
        self.assertEqual(value.declared_pack_sha1, self.pack[-20:].hex())
        self.assertFalse(value.whole_pack_integrity_verified)
        for name, offset, crc, length in self.records:
            selected = value.selected(name.hex())
            self.assertEqual(selected, subject.PackEntry(name.hex(), offset, length, crc))
        with self.assertRaises(AttributeError):
            value.pack_file_bytes = 1

    def test_exact_backward_base_and_missing_label(self):
        value = self.parse()
        first = self.records[0]
        self.assertEqual(value.base(first[1], before=self.records[1][1]).oid, first[0].hex())
        self.assertIsNone(value.selected('f' * 40))
        for offset, before in [(12, 12), (13, 100), (True, 100), (12, True), (0, 100)]:
            with self.subTest(offset=offset, before=before), self.assertRaises(subject.PackFormatError):
                value.base(offset, before=before)
        for name in ('0' * 40, 'A' * 40, 1):
            with self.subTest(name=name), self.assertRaises(subject.PackFormatError):
                value.selected(name)

    def test_bounds_versions_counts_and_binding(self):
        for kwargs in [dict(raw=b''), dict(raw=bytearray(self.index)), dict(header=b''),
                       dict(trailer=b'\0' * 20), dict(size=True), dict(size=subject.PACK_FILE_BYTES + 1),
                       dict(raw=self.index[:4] + word(3) + self.index[8:]),
                       dict(header=b'PACK' + word(3) + word(2)),
                       dict(header=b'PACK' + word(2) + word(3)),
                       dict(raw=self.index[:-1] + bytes([self.index[-1] ^ 1])),
                       dict(trailer=b'x' * 20)]:
            with self.subTest(kwargs=list(kwargs)), self.assertRaises(subject.PackFormatError):
                self.parse(**kwargs)

    def test_resealed_malformed_tables(self):
        count = 2
        crc_start = 1032 + 20 * count
        offsets = crc_start + 4 * count
        changes = [(8, word(1)), (1032, b'\0' * 20), (1052, self.index[1032:1052]),
                   (offsets, word(1)), (offsets, word(0x80000001)),
                   (offsets + 4, self.index[offsets:offsets + 4])]
        for at, data in changes:
            with self.subTest(at=at), self.assertRaises(subject.PackFormatError):
                self.parse(raw=reseal(self.index[:at] + data + self.index[at + len(data):]))

    def test_crc_is_a_declaration_until_selected_bytes_are_checked(self):
        at = 1032 + 20 * 2
        raw = reseal(self.index[:at] + word(0) + self.index[at + 4:])
        parsed = self.parse(raw=raw)
        self.assertEqual(parsed.entries[0].declared_crc32, 0)
        self.assertFalse(parsed.whole_pack_integrity_verified)

    def test_oversized_unselected_geometry_is_not_silently_read(self):
        parsed = self.parse(size=subject.FRAME_BYTES + 1000)
        last = parsed.by_offset[-1]
        with self.assertRaises(subject.PackFormatError):
            parsed.selected(last.oid)
        self.assertIsNotNone(parsed.selected(parsed.by_offset[0].oid))

    def test_explicit_index_object_count_boundary(self):
        for count, accepted in ((0, False), (subject.INDEX_OBJECTS, True),
                                (subject.INDEX_OBJECTS + 1, False)):
            names = b''.join(i.to_bytes(20, 'big') for i in range(1, count + 1))
            trailer = b'x' * 20
            raw = (b'\xfftOc' + word(2) + word(count) * 256 + names + word(0) * count
                   + b''.join(word(12 + 16 * i) for i in range(count)) + trailer)
            raw += hashlib.sha1(raw).digest()
            args = (raw, b'PACK' + word(2) + word(count), trailer, 32 + 16 * count)
            with self.subTest(count=count):
                if accepted:
                    parsed = subject.parse_index(*args)
                    self.assertEqual(parsed.object_count, count)
                    self.assertEqual(parsed.selected(f'{count:040x}').encoded_bytes, 16)
                else:
                    with self.assertRaises(subject.PackFormatError):
                        subject.parse_index(*args)
        with self.assertRaises(subject.PackFormatError):
            self.parse(raw=self.index + b'x' * subject.INDEX_BYTES)

    def test_cancellation_propagates_without_a_result(self):
        class Cancelled(Exception):
            pass
        for after in (0, 1, 3, 100):
            calls = 0
            def check():
                nonlocal calls
                calls += 1
                if calls > after:
                    raise Cancelled()
            with self.subTest(after=after), self.assertRaises(Cancelled):
                self.parse(check=check)


class DeltaProgramTest(unittest.TestCase):
    def test_independently_expected_copy_literal_empty_and_sparse_offsets(self):
        self.assertEqual(subject.apply_delta(b'hello world', b'\x0b\x11\x90\x06\x06brave \x91\x06\x05', 32768), b'hello brave world')
        self.assertEqual(subject.apply_delta(b'', b'\0\0', 32768), b'')
        self.assertEqual(subject.apply_delta(b'hello world', b'\x0b\x03\x03new', 32768), b'new')
        self.assertEqual(subject.apply_delta(b'x' * 256 + b'Z', b'\x81\x02\x01\x92\x01\x01', 32768), b'Z')
        self.assertEqual(subject.apply_delta(b'x' * 65536, b'\x80\x80\x04\x80\x80\x04\x80', 65536), b'x' * 65536)

    def test_invalid_instructions_varints_and_result_boundaries_refuse(self):
        bad = [b'\x0b\x00\x00', b'\x0a\x00', b'\x0b\x01\x91\x0b\x01',
               b'\x0b\x01\x91', b'\x0b\x03\x03x', b'\x0b\x00\x01x',
               b'\x0b\x02\x01x', b'\x8b\x00\x00', b'\x80', b'\x0b\x81\x80\x04',
               b'x' * (subject.PROGRAM_BYTES + 1)]
        for program in bad:
            with self.subTest(program=program[:16]), self.assertRaises(subject.PackReadError):
                subject.apply_delta(b'hello world', program, 32768)

    def test_instruction_and_decode_cancellation_is_preserved(self):
        class Stopped(Exception):
            pass
        for after in (0, 1, 2, 3, 4):
            calls = 0
            def check():
                nonlocal calls
                calls += 1
                if calls > after: raise Stopped()
            with self.subTest(after=after), self.assertRaises(Stopped):
                subject.apply_delta(b'hello world', b'\x0b\x11\x90\x06\x06brave \x91\x06\x05', 32768, check)


if __name__ == '__main__':
    unittest.main()
