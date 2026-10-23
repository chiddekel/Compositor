#!/usr/bin/env python3
"""Write a tiny, independently assembled RGB PSD with two artboards for the native import journey."""
import struct
import sys
from pathlib import Path


def fixture():
    u16 = lambda v: struct.pack('>H', v)
    u32 = lambda v: struct.pack('>I', v)
    def key(text):
        data = text.encode('ascii')
        return u32(0 if len(data) == 4 else len(data)) + data

    def artboard(left, top, width, height):
        descriptor = u32(16) + u32(0) + key('null') + u32(1)
        descriptor += key('artboardRect') + b'Objc' + u32(0) + key('classFloatRect') + u32(4)
        for name, value in [('Top ', top), ('Left', left), ('Btom', top + height), ('Rght', left + width)]:
            descriptor += key(name) + b'doub' + struct.pack('>d', value)
        return descriptor

    def block(kind, data):
        return b'8BIM' + kind + u32(len(data)) + data + (b'\0' if len(data) % 2 else b'')

    records, channels = [], []
    def layer(name, bounds=(0, 0, 0, 0), color=None, section=None, board=None):
        top, left, bottom, right = bounds
        planes = [] if color is None else [(-1, 255), (0, color[0]), (1, color[1]), (2, color[2])]
        payloads = [(index, u16(0) + bytes([value]) * ((bottom - top) * (right - left))) for index, value in planes]
        encoded_name = bytes([len(name)]) + name.encode('ascii')
        extra = u32(0) + u32(0) + encoded_name + b'\0' * (-len(encoded_name) % 4)
        if section is not None:
            extra += block(b'lsct', u32(section))
        if board is not None:
            extra += block(b'artb', artboard(*board))
        record = struct.pack('>iiiiH', top, left, bottom, right, len(payloads))
        record += b''.join(struct.pack('>hI', index, len(data)) for index, data in payloads)
        record += b'8BIMnorm' + bytes([255, 0, 0, 0]) + u32(len(extra)) + extra
        records.append(record)
        channels.extend(data for _, data in payloads)

    layer('</Layer group>', section=3)
    layer('Red', (2, 1, 7, 5), (255, 0, 0))
    layer('Phone', section=1, board=(0, 0, 10, 12))
    layer('</Layer group>', section=3)
    layer('Blue', (3, 22, 7, 25), (0, 0, 255))
    layer('Tablet', section=1, board=(20, 0, 12, 14))
    info = u16(len(records)) + b''.join(records) + b''.join(channels)
    info += b'\0' * (len(info) % 2)
    layer_section = u32(len(info)) + info + u32(0)
    header = b'8BPS' + u16(1) + b'\0' * 6 + u16(3) + u32(16) + u32(32) + u16(8) + u16(3)
    return header + u32(0) + u32(0) + u32(len(layer_section)) + layer_section + u16(0) + b'\0' * (32 * 16 * 3)


if __name__ == '__main__':
    path = Path(__file__).parent / 'fixtures' / 'artboards.psd'
    data = fixture()
    if '--check' in sys.argv:
        assert path.read_bytes() == data, 'Native artboard fixture is stale'
        print('Artboard PSD fixture OK')
    else:
        path.parent.mkdir(exist_ok=True)
        path.write_bytes(data)
