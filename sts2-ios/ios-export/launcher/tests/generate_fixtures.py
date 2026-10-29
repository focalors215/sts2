"""Equivalent to Java ZipOutputStream DEFLATED output; no Java runtime required.
Python's unseekable output uses local zero sizes/CRC, flags bit 3, raw DEFLATE,
and a signature-prefixed descriptor. Also derive the valid unsigned form.
"""
import io
import struct
import zipfile
from pathlib import Path

class Stream(io.BytesIO):
    def seekable(self):
        return False
    def seek(self, *args):
        raise io.UnsupportedOperation()

out = Stream()
with zipfile.ZipFile(out, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
    archive.writestr('profile.save', b'java-compatible-save')
raw = out.getvalue()
root = Path(__file__).parent / 'fixtures'
root.mkdir(exist_ok=True)
(root / 'java-equivalent-signed.zip').write_bytes(raw)
central = raw.index(b'PK\x01\x02')
descriptor = central - 16
assert raw[descriptor:descriptor+4] == b'PK\x07\x08'
unsigned = bytearray(raw[:descriptor] + raw[descriptor+4:])
eocd = len(unsigned) - 22
struct.pack_into('<I', unsigned, eocd+16, central-4)
(root / 'java-equivalent-unsigned.zip').write_bytes(unsigned)
