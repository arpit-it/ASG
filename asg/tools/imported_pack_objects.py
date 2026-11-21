# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Bounded SHA-1 pack-index declarations; selected bytes need separate verification.

The parser accepts supplied bytes; PackStore holds bounded files via its injected reader.
Neither runs commands, writes files, or authenticates repository state.
An index checksum and matching header/trailer declarations do not verify a pack.
"""
import bisect
import hashlib
import os
import re
import stat
import struct
import zlib
from typing import Callable, NamedTuple

INDEX_BYTES = 524288
INDEX_OBJECTS = 16384
PACK_FILE_BYTES = 67108864
FRAME_BYTES = 131072


class PackFormatError(ValueError):
    """A malformed or unsupported bounded pack declaration."""


def _check_oid(value):
    if (not isinstance(value, str) or re.fullmatch(r'[a-f0-9]{40}', value, re.ASCII) is None
            or value == '0' * 40):
        raise PackFormatError('invalid object label')


class PackEntry(NamedTuple):
    oid: str
    offset: int
    encoded_bytes: int
    declared_crc32: int

    def bounded(self):
        if not 9 <= self.encoded_bytes <= FRAME_BYTES:
            raise PackFormatError('selected frame byte bound')
        return self


class PackIndex(NamedTuple):
    index_sha256: str
    index_byte_length: int
    declared_pack_sha1: str
    pack_file_bytes: int
    names: tuple[str, ...]
    entries: tuple[PackEntry, ...]
    offsets: tuple[int, ...]
    by_offset: tuple[PackEntry, ...]

    @property
    def object_count(self):
        return len(self.entries)

    @property
    def whole_pack_integrity_verified(self):
        return False

    def selected(self, oid):
        _check_oid(oid)
        at = bisect.bisect_left(self.names, oid)
        if at == len(self.names) or self.names[at] != oid:
            return None  # Absence in this declaration is not repository absence.
        return self.entries[at].bounded()

    def base(self, offset, *, before):
        if type(offset) is not int or type(before) is not int or not 12 <= offset < before:
            raise PackFormatError('backward base offset')
        at = bisect.bisect_left(self.offsets, offset)
        if at == len(self.offsets) or self.offsets[at] != offset:
            raise PackFormatError('base is not an indexed frame')
        return self.by_offset[at].bounded()


def parse_index(raw: bytes, header: bytes, trailer: bytes, pack_file_bytes: int,
                check: Callable[[], None] = lambda: None) -> PackIndex:
    """Verify one supplied index2 and its declared pack2 geometry, without pack IO."""
    check()
    if (not isinstance(raw, bytes) or not 1072 <= len(raw) <= INDEX_BYTES
            or not isinstance(header, bytes) or len(header) != 12
            or not isinstance(trailer, bytes) or len(trailer) != 20 or trailer == b'\0' * 20
            or type(pack_file_bytes) is not int or not 32 <= pack_file_bytes <= PACK_FILE_BYTES):
        raise PackFormatError('index/prefix byte bounds')
    if raw[:8] != b'\xfftOc\0\0\0\2' or header[:8] != b'PACK\0\0\0\2':
        raise PackFormatError('unsupported index/pack version')
    fanout = struct.unpack('!256I', raw[8:1032])
    count = fanout[-1]
    if (not 1 <= count <= INDEX_OBJECTS or fanout != tuple(sorted(fanout))
            or len(raw) != 1072 + 28 * count or struct.unpack('!I', header[8:12])[0] != count):
        raise PackFormatError('count/fanout/large-offset subset')
    if hashlib.sha1(raw[:-20]).digest() != raw[-20:] or raw[-40:-20] != trailer:
        raise PackFormatError('index checksum or declared pack binding')
    check()
    names = []
    frequencies = [0] * 256
    previous = None
    for i in range(count):
        check()
        name = raw[1032 + 20 * i:1052 + 20 * i]
        if name == b'\0' * 20 or previous is not None and name <= previous:
            raise PackFormatError('nonunique or unsorted object labels')
        frequencies[name[0]] += 1
        names.append(name.hex())
        previous = name
    total = 0
    for i, frequency in enumerate(frequencies):
        check()
        total += frequency
        if fanout[i] != total:
            raise PackFormatError('fanout identity')
    start = 1032 + 20 * count
    crcs = struct.unpack('!' + str(count) + 'I', raw[start:start + 4 * count])
    offsets = struct.unpack('!' + str(count) + 'I', raw[start + 4 * count:start + 8 * count])
    ordered = tuple(sorted(offsets))
    if (len(set(offsets)) != count or ordered[0] != 12
            or any(offset & 0x80000000 or not 12 <= offset < pack_file_bytes - 20 for offset in offsets)):
        raise PackFormatError('unsupported frame offsets')
    ends = {offset: ordered[i + 1] if i + 1 < count else pack_file_bytes - 20
            for i, offset in enumerate(ordered)}
    entries = tuple(PackEntry(name, offset, ends[offset] - offset, crc)
                    for name, offset, crc in zip(names, offsets, crcs))
    check()
    return PackIndex(hashlib.sha256(raw).hexdigest(), len(raw), trailer.hex(), pack_file_bytes,
                     tuple(names), entries, ordered, tuple(sorted(entries, key=lambda e: e.offset)))


# The physical reader is injected by the trusted sibling helper. This module owns
# only its bounded pack read set; it never creates a process or writes files.
PROFILE = 'bounded-loose-pack2-index2-v1'
PAIR_COUNT = 4
NAMESPACE_COUNT = 32
SIDECAR_BYTES = 1048576
ENCODED_BYTES = 524288
EXPANDED_BYTES = 262144
OBJECT_COUNT = 70
DELTA_DEPTH = 32
PROGRAM_BYTES = 65536


class PackReadError(PackFormatError):
    def __init__(self, reason):
        self.reason = reason
        super().__init__(reason)


def _header(kind, size):
    output = bytearray([(kind << 4) | (size & 15)])
    size >>= 4
    while size:
        output[-1] |= 128
        output.append(size & 127)
        size >>= 7
    return bytes(output)


def _size(raw, position, limit, check):
    value, shift, start = 0, 0, position
    while True:
        check()
        if position >= len(raw) or shift > 28:
            raise PackReadError('invalid_object')
        byte = raw[position]
        position += 1
        value |= (byte & 127) << shift
        if value > limit:
            raise PackReadError('bounds')
        if not byte & 128:
            if position - start > 1 and byte == 0:
                raise PackReadError('invalid_object')
            return value, position
        shift += 7


def _distance(raw, position, check):
    if position >= len(raw):
        raise PackReadError('invalid_object')
    byte = raw[position]
    value, position, count = byte & 127, position + 1, 1
    while byte & 128:
        check()
        if position >= len(raw) or count >= 5:
            raise PackReadError('invalid_object')
        byte = raw[position]
        position += 1
        count += 1
        value = ((value + 1) << 7) + (byte & 127)
        if value > PACK_FILE_BYTES:
            raise PackReadError('bounds')
    if value == 0:
        raise PackReadError('invalid_object')
    return value, position


def apply_delta(base, program, limit, check=lambda: None):
    if len(program) > PROGRAM_BYTES:
        raise PackReadError('bounds')
    size, position = _size(program, 0, 65536, check)
    target, position = _size(program, position, limit, check)
    if size != len(base):
        raise PackReadError('invalid_object')
    output, instructions = bytearray(), 0
    while position < len(program):
        check()
        operation = program[position]
        position += 1
        instructions += 1
        if operation == 0 or instructions > 32768:
            raise PackReadError('invalid_object')
        if operation & 128:
            offset, size = 0, 0
            for i in range(7):
                if operation & (1 << i):
                    if position >= len(program):
                        raise PackReadError('invalid_object')
                    byte = program[position]
                    position += 1
                    if i < 4:
                        offset |= byte << (8 * i)
                    else:
                        size |= byte << (8 * (i - 4))
            size = size or 65536
            if offset > len(base) or size > len(base) - offset:
                raise PackReadError('invalid_object')
            fragment = base[offset:offset + size]
        else:
            if position + operation > len(program):
                raise PackReadError('invalid_object')
            fragment = program[position:position + operation]
            position += operation
        if len(output) + len(fragment) > target:
            raise PackReadError('invalid_object')
        output.extend(fragment)
    if len(output) != target:
        raise PackReadError('invalid_object')
    check()
    return bytes(output)


class _Pack(NamedTuple):
    index: PackIndex
    fd: int
    signature: tuple


class PackStore:
    """Held selected/base frames with one aggregate loose/packed resource ledger."""
    def __init__(self, reader, check, verify, signature):
        self.reader, self.check, self.verify, self.signature = reader, check, verify, signature
        self.pack_fd, self.catalog_names, self.packs = None, None, None
        self.cache, self.active, self.loose = {}, set(), set()
        self.encoded_bytes = self.expanded_bytes = self.max_delta_depth = 0

    @property
    def object_count(self):
        return len(self.cache) + len(self.loose)

    def record_loose(self, kind, oid, body):
        key = (kind, oid)
        if key not in self.loose:
            if self.object_count + len(self.active) >= OBJECT_COUNT:
                raise PackReadError('bounds')
            self.loose.add(key)
            self._expanded(len(body))

    def _expanded(self, size):
        self.expanded_bytes += size
        if self.expanded_bytes > EXPANDED_BYTES:
            raise PackReadError('bounds')

    def _catalog(self):
        names = []
        with os.scandir(self.pack_fd) as scan:
            for entry in scan:
                self.check()
                names.append(entry.name)
                if len(names) > NAMESPACE_COUNT:
                    raise PackReadError('bounds')
        names.sort()
        groups = {}
        for name in names:
            if name == 'multi-pack-index':
                continue
            match = re.fullmatch(r'(pack-[a-f0-9]{40})\.(pack|idx|rev|bitmap|keep|mtimes)', name, re.ASCII)
            if match is None:
                raise PackReadError('unsupported_layout')
            groups.setdefault(match[1], set()).add(match[2])
        if not 1 <= len(groups) <= PAIR_COUNT or any(not {'pack', 'idx'} <= kinds for kinds in groups.values()):
            raise PackReadError('unsupported_layout')
        return tuple(names), tuple(sorted(groups))

    def validate(self):
        if self.catalog_names is not None and self._catalog()[0] != self.catalog_names:
            raise PackReadError('changed')

    def _hold(self, name, limit):
        self.check()
        before = os.stat(name, dir_fd=self.pack_fd, follow_symlinks=False)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise PackReadError('unsupported_layout')
        if before.st_size > limit:
            raise PackReadError('bounds')
        fd = os.open(name, self.reader.file_flags, dir_fd=self.pack_fd)
        self.reader.fds.append(fd)
        expected = self.signature(before)
        if self.signature(os.fstat(fd)) != expected:
            raise PackReadError('changed')
        self.reader.files.append((self.pack_fd, name, fd, expected))
        self.check()
        return fd, before.st_size, expected

    def _pread(self, fd, offset, size, signature):
        self.check()
        raw = os.pread(fd, size, offset)
        if len(raw) != size or self.signature(os.fstat(fd)) != signature:
            raise PackReadError('changed')
        self.check()
        return raw

    def _load(self):
        if self.packs is not None:
            return
        try:
            self.pack_fd = self.reader.directory(self.reader.objects, 'pack')
        except FileNotFoundError:
            raise PackReadError('missing_loose_object') from None
        names, pairs = self._catalog()
        self.catalog_names = names
        for name in names:
            if not name.endswith(('.pack', '.idx')):
                self._hold(name, SIDECAR_BYTES if name == 'multi-pack-index' else PACK_FILE_BYTES)
        packs, total = [], 0
        for pair in pairs:
            self.check()
            raw = self.reader.read(self.pack_fd, pair + '.idx', INDEX_BYTES - total)
            total += len(raw)
            fd, size, signature = self._hold(pair + '.pack', PACK_FILE_BYTES)
            if size < 32:
                raise PackReadError('invalid_object')
            header = self._pread(fd, 0, 12, signature)
            trailer = self._pread(fd, size - 20, 20, signature)
            if pair != 'pack-' + trailer.hex():
                raise PackReadError('invalid_object')
            parsed = parse_index(raw, header, trailer, size, self.check)
            packs.append(_Pack(parsed, fd, signature))
        self.packs = tuple(packs)

    def read(self, kind, oid):
        self._load()
        matches = []
        for pack in self.packs:
            self.check()
            entry = pack.index.selected(oid)
            if entry is not None:
                matches.append((pack, entry))
        if len(matches) != 1:
            raise PackReadError('unsupported_layout' if matches else 'missing_loose_object')
        return self._frame(*matches[0], kind=kind)[1]

    def _frame(self, pack, entry, kind=None, depth=0):
        self.check()
        key = (pack.fd, entry.offset)
        if depth > DELTA_DEPTH or key in self.active:
            raise PackReadError('bounds')
        self.max_delta_depth = max(self.max_delta_depth, depth)
        if key in self.cache:
            actual, body = self.cache[key]
            if kind is not None and kind != actual:
                raise PackReadError('invalid_object')
            return actual, body
        if self.object_count + len(self.active) >= OBJECT_COUNT:
            raise PackReadError('bounds')
        entry.bounded()
        if self.encoded_bytes + entry.encoded_bytes > ENCODED_BYTES:
            raise PackReadError('bounds')
        raw = self._pread(pack.fd, entry.offset, entry.encoded_bytes, pack.signature)
        self.encoded_bytes += len(raw)
        if zlib.crc32(raw) & 0xffffffff != entry.declared_crc32:
            raise PackReadError('invalid_object')
        byte = raw[0]
        code, size, position, shift = (byte >> 4) & 7, byte & 15, 1, 4
        while byte & 128:
            self.check()
            if position >= len(raw) or shift > 32:
                raise PackReadError('invalid_object')
            byte = raw[position]
            position += 1
            size |= (byte & 127) << shift
            shift += 7
        if raw[:position] != _header(code, size):
            raise PackReadError('invalid_object')
        if code not in (1, 2, 3, 6):
            raise PackReadError('unsupported_layout')
        if size > PROGRAM_BYTES:
            raise PackReadError('bounds')
        base = None
        if code == 6:
            distance, position = _distance(raw, position, self.check)
            base = pack.index.base(entry.offset - distance, before=entry.offset)
        decoder = zlib.decompressobj()
        payload = decoder.decompress(raw[position:], PROGRAM_BYTES + 1)
        if len(payload) != size or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
            raise PackReadError('invalid_object')
        self._expanded(len(payload))
        self.active.add(key)
        try:
            if base is not None:
                actual, parent = self._frame(pack, base, depth=depth + 1)
                body = apply_delta(parent, payload, 32768 if actual == 'blob' else 65536, self.check)
                self._expanded(len(body))
            else:
                actual, body = {1: 'commit', 2: 'tree', 3: 'blob'}[code], payload
            if ((kind is not None and kind != actual)
                    or len(body) > (32768 if actual == 'blob' else 65536)):
                raise PackReadError('invalid_object')
            self.check()
            self.verify(actual, entry.oid, body)
            self.check()
            self.cache[key] = (actual, body)
            return actual, body
        finally:
            self.active.remove(key)

    def provenance(self):
        return {'profile': PROFILE, 'loose_object_count': len(self.loose),
                'packed_object_count': len(self.cache), 'encoded_bytes': self.encoded_bytes,
                'expanded_bytes': self.expanded_bytes, 'max_delta_depth': self.max_delta_depth,
                'indexes': [{'index_sha256': pack.index.index_sha256,
                             'index_byte_length': pack.index.index_byte_length,
                             'declared_pack_sha1': pack.index.declared_pack_sha1,
                             'pack_file_bytes': pack.index.pack_file_bytes,
                             'object_count': pack.index.object_count} for pack in self.packs or ()],
                'whole_pack_integrity_verified': False}
