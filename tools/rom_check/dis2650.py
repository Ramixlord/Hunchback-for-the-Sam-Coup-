"""Small Signetics 2650 disassembler for the hunchbkd ROMs.

    python3 dis2650.py ROMDIR [start end]

hunchbkd (Donkey Kong conversion): hb.5e at 0000, hbsc-1.5c at 2000,
hb.5b at 4000, hb.5a at 6000 (each page's upper 4K mirrors RAM/IO 1000-1FFF).
"""
import sys, os

def load(romdir):
    mem = bytearray([0xFF]) * 0x8000
    for name, base in (('hb.5e', 0), ('hbsc-1.5c', 0x2000), ('hb.5b', 0x4000), ('hb.5a', 0x6000)):
        d = open(os.path.join(romdir, name), 'rb').read()
        mem[base:base + len(d)] = d
    return mem

R = ['r0', 'r1', 'r2', 'r3']
CC = ['eq', 'gt', 'lt', 'un']
ONE = {0x00: 'lodz', 0x20: 'eorz', 0x40: 'andz', 0x60: 'iorz', 0x80: 'addz', 0xA0: 'subz',
       0xC0: 'strz', 0xE0: 'comz', 0x30: 'redc', 0x50: 'rrr', 0x70: 'redd', 0x94: 'dar',
       0xB0: 'wrtc', 0xD0: 'rrl', 0xF0: 'wrtd'}
IMM = {0x04: 'lodi', 0x24: 'eori', 0x44: 'andi', 0x64: 'iori', 0x84: 'addi', 0xA4: 'subi',
       0xE4: 'comi', 0x54: 'rede', 0xD4: 'wrte', 0xF4: 'tmi'}
REL = {0x08: 'lodr', 0x28: 'eorr', 0x48: 'andr', 0x68: 'iorr', 0x88: 'addr', 0xA8: 'subr',
       0xC8: 'strr', 0xE8: 'comr'}
ABS = {0x0C: 'loda', 0x2C: 'eora', 0x4C: 'anda', 0x6C: 'iora', 0x8C: 'adda', 0xAC: 'suba',
       0xCC: 'stra', 0xEC: 'coma'}
BREL = {0x18: 'bctr', 0x38: 'bstr', 0x98: 'bcfr', 0xB8: 'bsfr'}
BABS = {0x1C: 'bcta', 0x3C: 'bsta', 0x9C: 'bcfa', 0xBC: 'bsfa'}
RBREL = {0x58: 'brnr', 0x78: 'bsnr', 0xD8: 'birr', 0xF8: 'bdrr'}
RBABS = {0x5C: 'brna', 0x7C: 'bsna', 0xDC: 'bira', 0xFC: 'bdra'}
PSW = {0x74: 'cpsu', 0x75: 'cpsl', 0x76: 'ppsu', 0x77: 'ppsl', 0xB4: 'tpsu', 0xB5: 'tpsl'}
SIMPLE = {0x12: 'spsu', 0x13: 'spsl', 0x92: 'lpsu', 0x93: 'lpsl', 0x40: 'halt', 0xC0: 'nop'}


def rel(pc, b):
    off = b & 0x7F
    if off & 0x40:
        off -= 0x80
    return ((pc & 0x6000) | ((pc + off) & 0x1FFF)), '*' if b & 0x80 else ''


def dis(mem, pc):
    """-> (length, text, info) ; info: dict(kind, target, addr, reg, op)"""
    op = mem[pc]
    hi, r = op & 0xFC, op & 3
    b1 = mem[(pc + 1) & 0x7FFF]
    b2 = mem[(pc + 2) & 0x7FFF]
    info = {'op': None, 'reg': r}
    if op in SIMPLE:
        info['op'] = SIMPLE[op]
        return 1, SIMPLE[op], info
    if op in PSW:
        info['op'] = PSW[op]
        return 2, '%s $%02x' % (PSW[op], b1), info
    if hi == 0x14:
        info.update(op='retc', kind='ret')
        return 1, 'retc,%s' % CC[r], info
    if hi == 0x34:
        info.update(op='rete', kind='ret')
        return 1, 'rete,%s' % CC[r], info
    if op == 0x9B or op == 0xBB:
        t = b1 & 0x7F
        if t & 0x40:
            t = (t - 0x80) & 0x1FFF
        name = 'zbrr' if op == 0x9B else 'zbsr'
        info.update(op=name, kind='jmp' if op == 0x9B else 'call', target=t)
        return 2, '%s $%04x%s' % (name, t, '*' if b1 & 0x80 else ''), info
    if op == 0x9F or op == 0xBF:
        t = ((b1 & 0x7F) << 8) | b2
        name = 'bxa' if op == 0x9F else 'bsxa'
        info.update(op=name, kind='jmpx', target=t)
        return 3, '%s $%04x%s,r3' % (name, t, '*' if b1 & 0x80 else ''), info
    if hi in ONE:
        if op == 0x00 and False:
            pass
        info['op'] = ONE[hi]
        return 1, '%s,%s' % (ONE[hi], R[r]), info
    if hi in IMM:
        info.update(op=IMM[hi], imm=b1)
        return 2, '%s,%s $%02x' % (IMM[hi], R[r], b1), info
    if hi in REL:
        t, ind = rel(pc + 2, b1)
        info.update(op=REL[hi], addr=t, ind=bool(ind))
        return 2, '%s,%s $%04x%s' % (REL[hi], R[r], t, ind), info
    if hi in ABS:
        ind = '*' if b1 & 0x80 else ''
        ix = (b1 >> 5) & 3
        a = (pc & 0x6000) | (((b1 & 0x1F) << 8) | b2)
        info.update(op=ABS[hi], addr=a, ind=bool(ind), ix=ix)
        if ix == 0:
            return 3, '%s,%s $%04x%s' % (ABS[hi], R[r], a, ind), info
        mode = {1: '+', 2: '-', 3: ''}[ix]
        info['reg'] = 0
        info['ixreg'] = r
        return 3, '%s,r0 $%04x%s,%s%s' % (ABS[hi], a, ind, R[r], mode), info
    if hi in BREL:
        t, ind = rel(pc + 2, b1)
        k = 'call' if hi in (0x38, 0xB8) else 'jmp'
        info.update(op=BREL[hi], kind=k, target=t, cond=r)
        return 2, '%s,%s $%04x%s' % (BREL[hi], CC[r], t, ind), info
    if hi in BABS:
        t = ((b1 & 0x7F) << 8) | b2
        k = 'call' if hi in (0x3C, 0xBC) else 'jmp'
        info.update(op=BABS[hi], kind=k, target=t, cond=r)
        return 3, '%s,%s $%04x%s' % (BABS[hi], CC[r], t, '*' if b1 & 0x80 else ''), info
    if hi in RBREL:
        t, ind = rel(pc + 2, b1)
        k = 'call' if hi in (0x78,) else 'jmp'
        info.update(op=RBREL[hi], kind=k, target=t)
        return 2, '%s,%s $%04x%s' % (RBREL[hi], R[r], t, ind), info
    if hi in RBABS:
        t = ((b1 & 0x7F) << 8) | b2
        k = 'call' if hi in (0x7C,) else 'jmp'
        info.update(op=RBABS[hi], kind=k, target=t)
        return 3, '%s,%s $%04x%s' % (RBABS[hi], R[r], t, '*' if b1 & 0x80 else ''), info
    return 1, 'db $%02x' % op, info


def listing(mem, start, end, labels=None):
    pc = start
    out = []
    while pc < end:
        n, t, _ = dis(mem, pc)
        out.append('%04x  %-9s %s' % (pc, ' '.join('%02x' % mem[pc + i] for i in range(n)), t))
        pc += n
    return out


if __name__ == '__main__':
    mem = load(sys.argv[1])
    s = int(sys.argv[2], 16) if len(sys.argv) > 2 else 0
    e = int(sys.argv[3], 16) if len(sys.argv) > 3 else s + 0x100
    print('\n'.join(listing(mem, s, e)))
