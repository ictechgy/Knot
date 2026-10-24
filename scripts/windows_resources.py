#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Bounded Win32 resource writer/PE inspection; never executes Windows code."""
import re
import struct


def version_resource(version):
    """Build the native shell-visible VERSIONINFO from the release VERSION."""
    if (not isinstance(version, str) or len(version) > 128 or
            not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[a-zA-Z0-9.]+)?', version)):
        raise ValueError('Invalid native product version')
    parts = tuple(map(int, version.split('-')[0].split('.'))) + (0,)
    if any(part > 65535 for part in parts):
        raise ValueError('Native product version component exceeds WORD')

    def block(key, value=b'', kind=1, children=()):
        key_bytes = (key + '\0').encode('utf-16le')
        data = b'\0' * 6 + key_bytes
        data += b'\0' * (-len(data) % 4) + value
        for child in children:
            data += b'\0' * (-len(data) % 4) + child
        value_length = len(value) // 2 if kind == 1 else len(value)
        return struct.pack('<HHH', len(data), value_length, kind) + data[6:]

    major, minor, patch, revision = parts
    fixed = struct.pack('<13I', 0xfeef04bd, 0x10000,
                        major << 16 | minor, patch << 16 | revision,
                        major << 16 | minor, patch << 16 | revision,
                        0x3f, 2 if '-' in version else 0, 0x40004, 1, 0, 0, 0)
    strings = {
        'CompanyName': 'Knot contributors', 'FileDescription': 'Knot Windows',
        'FileVersion': version, 'InternalName': 'Knot',
        'OriginalFilename': 'Knot-Windows.exe', 'ProductName': 'Knot',
        'ProductVersion': version,
    }
    table = block('040904B0', children=[block(key, (value + '\0').encode('utf-16le'))
                                      for key, value in strings.items()])
    return block('VS_VERSION_INFO', fixed, 0, [
        block('StringFileInfo', children=[table]),
        block('VarFileInfo', children=[block('Translation', struct.pack('<HH', 0x409, 1200), 0)]),
    ])


def validate_version_resource(data, version=None):
    """Bounded parsing plus exact release metadata validation; no native code runs."""
    if not 92 <= len(data) <= 65535:
        raise ValueError('Invalid native version resource size')

    def read(offset, end, depth=0):
        if depth > 4 or offset + 6 > end:
            raise ValueError('Invalid native version block')
        length, value_length, kind = struct.unpack_from('<HHH', data, offset)
        stop = offset + length
        if length < 8 or stop > end or kind not in (0, 1):
            raise ValueError('Invalid native version block bounds')
        cursor = offset + 6
        start = cursor
        while cursor + 2 <= stop and data[cursor:cursor + 2] != b'\0\0':
            cursor += 2
        if cursor + 2 > stop:
            raise ValueError('Unterminated native version key')
        key = data[start:cursor].decode('utf-16le')
        cursor = (cursor + 2 + 3) & ~3
        size = value_length * 2 if kind == 1 else value_length
        if cursor + size > stop:
            raise ValueError('Native version value outside block')
        value = data[cursor:cursor + size]
        cursor += size
        children = {}
        while cursor < stop:
            cursor = (cursor + 3) & ~3
            if cursor == stop:
                break
            child_key, child_value, child_children, next_cursor = read(cursor, stop, depth + 1)
            if child_key in children or len(children) >= 32:
                raise ValueError('Duplicate or excessive native version children')
            children[child_key] = (child_value, child_children)
            cursor = next_cursor
        return key, value, children, stop

    try:
        key, fixed, children, end = read(0, len(data))
        strings = children['StringFileInfo'][1]['040904B0'][1]
        stored = strings['ProductVersion'][0]
        if key != 'VS_VERSION_INFO' or len(fixed) != 52 or end != len(data) or not stored.endswith(b'\0\0'):
            raise ValueError('Invalid native product version')
        actual = stored[:-2].decode('utf-16le')
        if version is not None and actual != version:
            raise ValueError('Native product version differs from release VERSION')
        if data != version_resource(actual):
            raise ValueError('Native product metadata differs from Knot release metadata')
        return actual
    except (KeyError, UnicodeError, struct.error) as error:
        raise ValueError('Invalid native product metadata') from error


def resource_file(managed, manifest, icon, version):
    def entry(kind, name, data, dummy=False):
        header = struct.pack('<IIHHHHIHHII', len(data), 32, 0xffff, kind,
                             0xffff, name, 0, 0 if dummy else 0x1030,
                             0 if dummy else 0x409, 0, 0)
        return header + data + b'\0' * (-len(data) % 4)
    if len(managed) > 32 * 1024 * 1024 or len(manifest) > 65536:
        raise ValueError('Unexpected bootstrap resource size')
    reserved, kind, count = struct.unpack_from('<HHH', icon)
    if reserved or kind != 1 or not 1 <= count <= 256 or len(icon) < 6 + count * 16:
        raise ValueError('Invalid ICO header')
    result = (entry(0, 0, b'', True) + entry(10, 101, managed) +
              entry(24, 1, manifest) + entry(16, 1, version_resource(version)))
    group = struct.pack('<HHH', 0, 1, count)
    for i in range(count):
        width, height, colors, zero, planes, bits, size, offset = struct.unpack_from('<BBBBHHII', icon, 6 + 16 * i)
        if zero or offset < 6 + 16 * count or size == 0 or offset + size > len(icon):
            raise ValueError('Invalid ICO image bounds')
        result += entry(3, i + 1, icon[offset:offset + size])
        group += struct.pack('<BBBBHHIH', width, height, colors, zero, planes, bits, size, i + 1)
    return result + entry(14, 1, group)


class NativePE:
    def __init__(self, data):
        self.data = data
        if not 64 <= len(data) <= 64 * 1024 * 1024 or data[:2] != b'MZ':
            raise ValueError('Invalid native PE size/header')
        pe = self.u32(60)
        if self.take(pe, 4) != b'PE\0\0' or self.u16(pe + 4) != 0x8664:
            raise ValueError('Native bootstrap must be x64 PE')
        count, optional_size = self.u16(pe + 6), self.u16(pe + 20)
        optional = pe + 24
        if self.u16(optional) != 0x20b or optional_size < 240 or self.u16(optional + 68) != 2:
            raise ValueError('Native bootstrap must be Windows GUI PE32+')
        if self.u32(optional + 108) < 16:
            raise ValueError('Missing PE directories')
        self.directories = [struct.unpack_from('<II', self.take(optional + 112 + 8 * i, 8)) for i in range(16)]
        if self.directories[14] != (0, 0):
            raise ValueError('Distributed bootstrap must not activate CLR')
        if self.directories[11] != (0, 0) or self.directories[13] != (0, 0):
            raise ValueError('Distributed bootstrap must not use bound or delayed imports')
        if not 1 <= count <= 96:
            raise ValueError('Invalid section count')
        self.sections = []
        for i in range(count):
            section = optional + optional_size + 40 * i
            virtual_size, rva, size, offset = struct.unpack_from('<IIII', self.take(section + 8, 16))
            self.sections.append((rva, virtual_size, offset, size))

    def take(self, offset, size):
        if offset < 0 or size < 0 or offset + size > len(self.data):
            raise ValueError('PE data outside file')
        return self.data[offset:offset + size]

    def u16(self, offset):
        return struct.unpack('<H', self.take(offset, 2))[0]

    def u32(self, offset):
        return struct.unpack('<I', self.take(offset, 4))[0]

    def offset(self, rva, size):
        for base, virtual, offset, raw in self.sections:
            backed = min(raw, virtual) if virtual > 0 else raw
            if base <= rva and rva + size <= base + backed:
                self.take(offset + rva - base, size)
                return offset + rva - base
        raise ValueError('PE RVA outside backed sections')

    def imports(self):
        rva, size = self.directories[1]
        if not rva or size < 20 or size > 65536:
            raise ValueError('Invalid native imports')
        offset = self.offset(rva, size)
        names = []
        for i in range(min(size // 20, 128)):
            descriptor = self.take(offset + i * 20, 20)
            if descriptor == bytes(20):
                return names
            name_rva = struct.unpack_from('<I', descriptor, 12)[0]
            name_offset = self.offset(name_rva, 1)
            name = self.take(name_offset, min(256, len(self.data) - name_offset)).split(b'\0', 1)
            if len(name) != 2:
                raise ValueError('Unterminated import')
            names.append(name[0].decode('ascii').lower())
        raise ValueError('Unterminated import directory')

    def resource(self, kind, name, language=0x409):
        rva, size = self.directories[2]
        base = self.offset(rva, size)
        def bounded(relative, length):
            if relative < 0 or relative + length > size:
                raise ValueError('Resource directory outside bounds')
            return base + relative
        directory = 0
        for depth, key in enumerate((kind, name, language)):
            address = bounded(directory, 16)
            count = self.u16(address + 12) + self.u16(address + 14)
            if count > 1024:
                raise ValueError('Too many resource entries')
            found = None
            for i in range(count):
                identifier, target = struct.unpack('<II', self.take(bounded(directory + 16 + i * 8, 8), 8))
                if identifier == key:
                    if found is not None:
                        raise ValueError('Duplicate resource')
                    found = target
            if found is None or bool(found & 0x80000000) != (depth < 2):
                raise ValueError('Missing/invalid bootstrap resource')
            directory = found & 0x7fffffff
        location, length, codepage, reserved = struct.unpack('<IIII', self.take(bounded(directory, 16), 16))
        return self.take(self.offset(location, length), length)


def validate_bootstrap(data, managed, version=None):
    pe = NativePE(data)
    allowed = {'kernel32.dll', 'advapi32.dll', 'shell32.dll', 'ole32.dll', 'user32.dll', 'msvcrt.dll'}
    # Windows 11 resolves these UCRT API-set contracts through the OS schema,
    # before filesystem DLL searching. Keep the set explicit, not a prefix match.
    allowed |= {'api-ms-win-crt-' + name + '-l1-1-0.dll' for name in
                ('heap', 'locale', 'runtime', 'stdio', 'string', 'math', 'environment')}
    imports = pe.imports()
    if not imports or set(imports) - allowed:
        raise ValueError('Unexpected bootstrap DLL dependency: ' + repr(imports))
    if pe.resource(10, 101) != managed:
        raise ValueError('Native bootstrap managed resource mismatch')
    validate_version_resource(pe.resource(16, 1), version)
    return imports
