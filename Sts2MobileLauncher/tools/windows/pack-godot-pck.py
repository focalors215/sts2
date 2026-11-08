#!/usr/bin/env python3
"""Pack a directory into a Godot 4 (format 3) PCK.

Only used for the bundled LAN mod's localization files. A mod PCK loaded with
ProjectSettings.load_resource_pack() does not need project.binary, so the pack
holds data files plus the trailing directory and nothing else.

Directory entry layout (matching godot/core/io/file_access_pack.cpp):
  u32 path_len (path padded to 4 bytes)
  path bytes
  u64 offset (relative to the header's file_base)
  u64 size
  16-byte MD5 of the file
  u32 flags (0 = not encrypted)
"""

import argparse
import hashlib
import struct
from pathlib import Path

PCK_MAGIC = b'GDPC'
PCK_FORMAT_VERSION = 3
ENGINE_VERSION = (4, 5, 1)
# PACK_REL_FILEBASE: directory offsets are relative to file_base.
PACK_FLAGS = 2
FILE_BASE = 112
ALIGN = 16


def align_up(value, align=ALIGN):
    return (value + align - 1) // align * align


def collect(root, prefix):
    prefix = prefix.strip('/')
    entries = []
    for path in sorted(p for p in root.rglob('*') if p.is_file()):
        name = path.relative_to(root).as_posix()
        entries.append((f'{prefix}/{name}' if prefix else name, path.read_bytes()))
    return entries


def build_pck(entries):
    data = bytearray()
    directory = bytearray(struct.pack('<I', len(entries)))
    for name, content in entries:
        offset = len(data)
        data += content
        data += b'\0' * (align_up(len(data)) - len(data))
        path = name.encode('utf-8')
        path += b'\0' * (align_up(len(path), 4) - len(path))
        directory += struct.pack('<I', len(path))
        directory += path
        directory += struct.pack('<QQ', offset, len(content))
        directory += hashlib.md5(content).digest()
        directory += struct.pack('<I', 0)
    dir_offset = FILE_BASE + len(data)
    header = PCK_MAGIC + struct.pack('<IIIII', PCK_FORMAT_VERSION, *ENGINE_VERSION, PACK_FLAGS)
    header += struct.pack('<QQ', FILE_BASE, dir_offset)
    header += b'\0' * (FILE_BASE - len(header))
    return header + bytes(data) + bytes(directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--root', required=True, type=Path, help='directory to pack recursively')
    parser.add_argument('--prefix', required=True, help='resource path prefix inside the PCK')
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()

    if not args.root.is_dir():
        parser.error(f'not a directory: {args.root}')
    entries = collect(args.root, args.prefix)
    if not entries:
        parser.error(f'no files under {args.root}')
    pck = build_pck(entries)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(pck)
    print(f'packed {len(entries)} files into {args.out} ({len(pck)} bytes)')


if __name__ == '__main__':
    main()
