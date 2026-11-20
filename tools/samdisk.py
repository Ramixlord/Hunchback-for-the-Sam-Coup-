"""MGT disk helpers: read files from a SAM .mgt image, decode mode-4 screens."""
import numpy as np


def sector_offset(t, s):
    side = 1 if t >= 128 else 0
    return (((t & 127) * 2 + side) * 10 + (s - 1)) * 512


def entry_offset(i):
    return sector_offset(i // 20, (i % 20) // 2 + 1) + (i % 2) * 256


def read_files(path):
    d = open(path, 'rb').read()
    files = {}
    for i in range(80):
        e = d[entry_offset(i):entry_offset(i) + 256]
        if e[0] == 0:
            continue
        name = e[1:11].decode('latin1').strip()
        n = e[11] * 256 + e[12]
        t, s = e[13], e[14]
        buf = b''
        for _ in range(n):
            o = sector_offset(t, s)
            buf += d[o:o + 510]
            t, s = d[o + 510], d[o + 511]
        files[name] = buf
    return files


def screen(buf):
    """file bytes of a mode-4 SCREEN$ -> (192x256 index array, 16 palette bytes)"""
    s = np.frombuffer(buf[9:9 + 24576], np.uint8).reshape(192, 128)
    a = np.zeros((192, 256), np.uint8)
    a[:, 0::2] = s >> 4
    a[:, 1::2] = s & 15
    return a, list(buf[9 + 24576:9 + 24576 + 16])
