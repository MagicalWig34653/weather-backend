#!/usr/bin/env python3
"""Cuts a small test GRIB2 out of a real ICON-D2 file (regular-lat-lon, simple packing, bitmap).

Usage: make_grib_fixture.py <unpacked .grib2> <out.grib2> <col0> <row0> <ni> <nj>

Keeps the real section layout (1, 2, 3, 4, 5, 6, 7) and the real packing constants R/E/D; only the grid size and first/last point
(section 3), the value count (section 5), the bitmap (section 6) and the packed values (section 7) are rewritten for the window.
Decoding the result gives exactly the values of the original file in that window (no re-quantisation). Stdlib only.
"""
import struct, sys

src, dst, c0, r0, ni, nj = sys.argv[1], sys.argv[2], *map(int, sys.argv[3:7])
d = open(src, 'rb').read()
pos = 16; secs = {}
while d[pos:pos + 4] != b'7777':
    ln = struct.unpack('>I', d[pos:pos + 4])[0]; secs[d[pos + 4]] = bytearray(d[pos:pos + ln]); pos += ln
s3, s5, s6, s7 = secs[3], secs[5], secs[6], secs[7]
oni, onj = struct.unpack('>II', s3[30:38])
la1, lo1 = struct.unpack('>ii', s3[46:54]); di, dj = struct.unpack('>II', s3[63:71])
bits = s5[19]; assert bits == 16 and s5[9:11] == b'\x00\x00' or struct.unpack('>H', s5[9:11])[0] == 0
bm = s6[6:]; xs = struct.unpack('>%dH' % struct.unpack('>I', s5[5:9])[0], s7[5:5 + 2 * struct.unpack('>I', s5[5:9])[0]])
index = {}; k = 0
for i in range(oni * onj):
    if (bm[i >> 3] >> (7 - (i & 7))) & 1: index[i] = xs[k]; k += 1
new_bm = bytearray((ni * nj + 7) // 8); new_x = []
for r in range(nj):
    for c in range(ni):
        i = (r0 + r) * oni + (c0 + c)
        if i in index: new_bm[(r * ni + c) >> 3] |= 0x80 >> ((r * ni + c) & 7); new_x.append(index[i])
nla1 = la1 + r0 * dj; nlo1 = lo1 + c0 * di
s3[30:38] = struct.pack('>II', ni, nj); s3[6:10] = struct.pack('>I', ni * nj)
s3[46:54] = struct.pack('>ii', nla1, nlo1)
s3[55:63] = struct.pack('>ii', nla1 + (nj - 1) * dj, nlo1 + (ni - 1) * di)
s5[5:9] = struct.pack('>I', len(new_x))
s6 = bytearray(struct.pack('>I', 6 + len(new_bm)) + b'\x06\x00') + new_bm
s7 = bytearray(struct.pack('>I', 5 + 2 * len(new_x)) + b'\x07') + struct.pack('>%dH' % len(new_x), *new_x)
body = bytes(secs[1]) + bytes(secs[2]) + bytes(s3) + bytes(secs[4]) + bytes(s5) + bytes(s6) + bytes(s7) + b'7777'
open(dst, 'wb').write(d[:8] + struct.pack('>Q', 16 + len(body)) + body)
print('values', len(new_x), 'of', ni * nj)
