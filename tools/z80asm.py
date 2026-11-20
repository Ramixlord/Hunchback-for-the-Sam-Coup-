#!/usr/bin/env python3
"""Small two-pass Z80 assembler (pasmo/sjasm-like syntax subset).

Features: labels (name: ), local labels (.name -> lastglobal.name), EQU, ORG,
DB/DEFB/DM, DW/DEFW, DS/DEFS, INCBIN, INCLUDE, ALIGN, expressions with
+ - * / % & | ^ << >> ~ ( ), $ for current address, hex #ff $ff 0xff ffh,
binary %0101 0b0101, chars 'a'. IX/IY with displacement, IXH/IXL/IYH/IYL.
"""
import sys, os, re

R8 = {'b': 0, 'c': 1, 'd': 2, 'e': 3, 'h': 4, 'l': 5, '(hl)': 6, 'a': 7}
R16 = {'bc': 0, 'de': 1, 'hl': 2, 'sp': 3}
R16AF = {'bc': 0, 'de': 1, 'hl': 2, 'af': 3}
CC = {'nz': 0, 'z': 1, 'nc': 2, 'c': 3, 'po': 4, 'pe': 5, 'p': 6, 'm': 7}
ALU = {'add': 0, 'adc': 1, 'sub': 2, 'sbc': 3, 'and': 4, 'xor': 5, 'or': 6, 'cp': 7}
ROT = {'rlc': 0, 'rrc': 1, 'rl': 2, 'rr': 3, 'sla': 4, 'sra': 5, 'sll': 6, 'sl1': 6, 'srl': 7}
SIMPLE = {
    'nop': [0x00], 'halt': [0x76], 'di': [0xF3], 'ei': [0xFB], 'exx': [0xD9],
    'rlca': [0x07], 'rrca': [0x0F], 'rla': [0x17], 'rra': [0x1F], 'daa': [0x27],
    'cpl': [0x2F], 'scf': [0x37], 'ccf': [0x3F], 'neg': [0xED, 0x44],
    'reti': [0xED, 0x4D], 'retn': [0xED, 0x45], 'rld': [0xED, 0x6F], 'rrd': [0xED, 0x67],
    'ldi': [0xED, 0xA0], 'cpi': [0xED, 0xA1], 'ini': [0xED, 0xA2], 'outi': [0xED, 0xA3],
    'ldd': [0xED, 0xA8], 'cpd': [0xED, 0xA9], 'ind': [0xED, 0xAA], 'outd': [0xED, 0xAB],
    'ldir': [0xED, 0xB0], 'cpir': [0xED, 0xB1], 'inir': [0xED, 0xB2], 'otir': [0xED, 0xB3],
    'lddr': [0xED, 0xB8], 'cpdr': [0xED, 0xB9], 'indr': [0xED, 0xBA], 'otdr': [0xED, 0xBB],
}


class AsmError(Exception):
    pass


def split_operands(s):
    out, depth, cur, q = [], 0, '', None
    for ch in s:
        if q:
            cur += ch
            if ch == q:
                q = None
            continue
        if ch in '"\'':
            # apostrophe after af is part of register name
            if ch == "'" and cur.strip().lower() == 'af':
                cur += ch
                continue
            q = ch
            cur += ch
            continue
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
        if ch == ',' and depth == 0:
            out.append(cur.strip())
            cur = ''
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def strip_comment(line):
    q = None
    for i, ch in enumerate(line):
        if q:
            if ch == q:
                q = None
            continue
        if ch in '"\'':
            if ch == "'" and line[max(0, i - 2):i].lower() == 'af':
                continue
            q = ch
        elif ch == ';':
            return line[:i]
    return line


class Assembler:
    def __init__(self):
        self.symbols = {}
        self.pass_no = 1
        self.out = {}
        self.pc = 0
        self.lastglobal = ''
        self.errors = []
        self.listing = []

    # ---------- expressions ----------
    def eval(self, expr):
        e = expr.strip()
        if not e:
            raise AsmError('empty expression')
        toks = []
        i = 0
        while i < len(e):
            ch = e[i]
            if ch.isspace():
                i += 1
                continue
            if ch == "'" and i + 2 < len(e) and e[i + 2] == "'":
                toks.append(str(ord(e[i + 1])))
                i += 3
                continue
            m = re.match(r'(0x[0-9a-fA-F]+|#[0-9a-fA-F]+|\$[0-9a-fA-F]+|[0-9][0-9a-fA-F]*[hH]\b|%[01]+|0b[01]+|[01]+[bB]\b|[0-9]+)', e[i:])
            if m and not (ch == '$' and not re.match(r'\$[0-9a-fA-F]', e[i:])):
                t = m.group(0)
                if t.startswith('0x'):
                    v = int(t[2:], 16)
                elif t[0] in '#$':
                    v = int(t[1:], 16)
                elif t[-1] in 'hH':
                    v = int(t[:-1], 16)
                elif t[0] == '%':
                    v = int(t[1:], 2)
                elif t.startswith('0b'):
                    v = int(t[2:], 2)
                elif t[-1] in 'bB':
                    v = int(t[:-1], 2)
                else:
                    v = int(t)
                toks.append(str(v))
                i += len(t)
                continue
            if ch == '$':
                toks.append(str(self.pc))
                i += 1
                continue
            m = re.match(r'\.?[A-Za-z_][A-Za-z0-9_.]*', e[i:])
            if m:
                name = m.group(0)
                toks.append(str(self.lookup(name)))
                i += len(name)
                continue
            for op in ('<<', '>>', '<=', '>=', '==', '!=', '<', '>', '+', '-', '*', '/', '%', '&', '|', '^', '~', '(', ')'):
                if e.startswith(op, i):
                    toks.append('//' if op == '/' else op)
                    i += len(op)
                    break
            else:
                raise AsmError('bad char in expression: %r' % e)
        try:
            return int(eval(' '.join(toks), {'__builtins__': {}}))
        except AsmError:
            raise
        except Exception as ex:
            raise AsmError('cannot evaluate %r (%s)' % (expr, ex))

    def fullname(self, name):
        if name.startswith('.'):
            return self.lastglobal + name
        return name

    def lookup(self, name):
        n = self.fullname(name)
        if n in self.symbols:
            return self.symbols[n]
        if self.pass_no == 1:
            return 0
        raise AsmError('undefined symbol ' + n)

    def define(self, name, val):
        n = self.fullname(name)
        if self.pass_no == 1 and n in self.symbols:
            raise AsmError('duplicate symbol ' + n)
        self.symbols[n] = val

    # ---------- emit ----------
    def emit(self, bs):
        for b in bs:
            if self.pass_no == 2:
                if not (-256 <= b <= 255):
                    raise AsmError('byte out of range %d' % b)
                self.out[self.pc] = b & 0xFF
            self.pc += 1

    def byte(self, v):
        if self.pass_no == 2 and not (-128 <= v <= 255):
            raise AsmError('byte value out of range: %d' % v)
        return v & 0xFF

    def word(self, v):
        if self.pass_no == 2 and not (-32768 <= v <= 65535):
            raise AsmError('word value out of range: %d' % v)
        v &= 0xFFFF
        return [v & 0xFF, v >> 8]

    # ---------- operand classification ----------
    def is_ind(self, op):
        if not (op.startswith('(') and op.endswith(')')):
            return False
        d = 0
        for i, ch in enumerate(op):
            if ch == '(':
                d += 1
            elif ch == ')':
                d -= 1
                if d == 0 and i != len(op) - 1:
                    return False
        return True

    def idx(self, op):
        """(ix+d) -> (prefix, d) or None"""
        o = op.lower().replace(' ', '')
        if self.is_ind(o) and (o[1:3] in ('ix', 'iy')) and (len(o) == 4 or o[3] in '+-'):
            pre = 0xDD if o[1:3] == 'ix' else 0xFD
            inner = op.strip()[1:-1].strip()[2:].strip()
            d = self.eval(inner) if inner else 0
            if self.pass_no == 2 and not -128 <= d <= 127:
                raise AsmError('index displacement out of range')
            return pre, d & 0xFF
        return None

    def r8(self, op):
        o = op.lower().replace(' ', '')
        return R8.get(o)

    def r8x(self, op):
        o = op.lower()
        m = {'ixh': (0xDD, 4), 'ixl': (0xDD, 5), 'iyh': (0xFD, 4), 'iyl': (0xFD, 5)}
        return m.get(o)

    # ---------- instruction ----------
    def instr(self, mn, ops):
        m = mn.lower()
        lo = [o.lower().replace(' ', '') for o in ops]
        n = len(ops)
        E = self.emit
        if m in SIMPLE and n == 0:
            return E(SIMPLE[m])
        if m == 'ld':
            return self.ld(ops, lo)
        if m in ('push', 'pop'):
            base = 0xC5 if m == 'push' else 0xC1
            for o in lo:
                if o in ('ix', 'iy'):
                    E([0xDD if o == 'ix' else 0xFD, base + 0x20])
                elif o in R16AF:
                    E([base | R16AF[o] << 4])
                else:
                    raise AsmError('bad push/pop operand')
            return
        if m == 'ex':
            if lo == ['de', 'hl']:
                return E([0xEB])
            if lo in (["af", "af'"], ["af'", "af"], ['af', 'af']):
                return E([0x08])
            if lo[0] == '(sp)':
                if lo[1] == 'hl':
                    return E([0xE3])
                if lo[1] == 'ix':
                    return E([0xDD, 0xE3])
                if lo[1] == 'iy':
                    return E([0xFD, 0xE3])
            raise AsmError('bad EX')
        if m in ALU:
            a = ALU[m]
            if m in ('add', 'adc', 'sbc') and n == 2 and lo[0] in ('hl', 'ix', 'iy'):
                if lo[0] == 'hl':
                    if lo[1] not in R16:
                        raise AsmError('bad 16-bit op')
                    p = R16[lo[1]]
                    if m == 'add':
                        return E([0x09 | p << 4])
                    if m == 'adc':
                        return E([0xED, 0x4A | p << 4])
                    return E([0xED, 0x42 | p << 4])
                if m != 'add':
                    raise AsmError('bad ix op')
                pre = 0xDD if lo[0] == 'ix' else 0xFD
                t = {'bc': 0, 'de': 1, lo[0]: 2, 'sp': 3}
                if lo[1] not in t:
                    raise AsmError('bad add ix')
                return E([pre, 0x09 | t[lo[1]] << 4])
            if n == 2:
                if lo[0] != 'a':
                    raise AsmError('ALU first operand must be A')
                src = ops[1]
                lsrc = lo[1]
            elif n == 1:
                src = ops[0]
                lsrc = lo[0]
            else:
                raise AsmError('bad ALU operands')
            r = self.r8(lsrc)
            if r is not None:
                return E([0x80 | a << 3 | r])
            x = self.r8x(lsrc)
            if x:
                return E([x[0], 0x80 | a << 3 | x[1]])
            ix = self.idx(src)
            if ix:
                return E([ix[0], 0x86 | a << 3, ix[1]])
            return E([0xC6 | a << 3, self.byte(self.eval(src))])
        if m in ('inc', 'dec'):
            o = lo[0]
            d = 0 if m == 'inc' else 1
            if o in R16:
                return E([(0x03 if d == 0 else 0x0B) | R16[o] << 4])
            if o in ('ix', 'iy'):
                return E([0xDD if o == 'ix' else 0xFD, 0x23 if d == 0 else 0x2B])
            r = self.r8(o)
            if r is not None:
                return E([0x04 | r << 3 | d])
            x = self.r8x(o)
            if x:
                return E([x[0], 0x04 | x[1] << 3 | d])
            ix = self.idx(ops[0])
            if ix:
                return E([ix[0], 0x34 | d, ix[1]])
            raise AsmError('bad inc/dec')
        if m in ROT or m in ('bit', 'set', 'res'):
            if m in ROT:
                base = ROT[m] << 3
                tgt = ops[0]
                if n != 1:
                    raise AsmError('bad rotate')
            else:
                b = self.eval(ops[0])
                if not 0 <= b <= 7:
                    raise AsmError('bit number out of range')
                base = {'bit': 0x40, 'res': 0x80, 'set': 0xC0}[m] | b << 3
                tgt = ops[1]
            r = self.r8(tgt)
            if r is not None:
                return E([0xCB, base | r])
            ix = self.idx(tgt)
            if ix:
                return E([ix[0], 0xCB, ix[1], base | 6])
            raise AsmError('bad CB operand')
        if m == 'jp':
            if n == 1:
                if lo[0] in ('(hl)', 'hl'):
                    return E([0xE9])
                if lo[0] in ('(ix)', 'ix'):
                    return E([0xDD, 0xE9])
                if lo[0] in ('(iy)', 'iy'):
                    return E([0xFD, 0xE9])
                return E([0xC3] + self.word(self.eval(ops[0])))
            return E([0xC2 | CC[lo[0]] << 3] + self.word(self.eval(ops[1])))
        if m in ('jr', 'djnz'):
            if m == 'djnz':
                op, tgt = 0x10, ops[0]
            elif n == 1:
                op, tgt = 0x18, ops[0]
            else:
                if lo[0] not in ('nz', 'z', 'nc', 'c'):
                    raise AsmError('bad JR condition')
                op, tgt = 0x20 | CC[lo[0]] << 3, ops[1]
            t = self.eval(tgt)
            d = t - (self.pc + 2)
            if self.pass_no == 2 and not -128 <= d <= 127:
                raise AsmError('relative jump out of range (%d)' % d)
            return E([op, d & 0xFF])
        if m == 'call':
            if n == 1:
                return E([0xCD] + self.word(self.eval(ops[0])))
            return E([0xC4 | CC[lo[0]] << 3] + self.word(self.eval(ops[1])))
        if m == 'ret':
            if n == 0:
                return E([0xC9])
            return E([0xC0 | CC[lo[0]] << 3])
        if m == 'rst':
            v = self.eval(ops[0])
            if v not in (0, 8, 16, 24, 32, 40, 48, 56):
                raise AsmError('bad rst')
            return E([0xC7 | v])
        if m == 'im':
            v = self.eval(ops[0])
            return E([0xED, {0: 0x46, 1: 0x56, 2: 0x5E}[v]])
        if m == 'in':
            if n == 2 and lo[1] == '(c)':
                r = self.r8(lo[0])
                if r is None or r == 6:
                    raise AsmError('bad in')
                return E([0xED, 0x40 | r << 3])
            if lo[0] == 'a' and self.is_ind(ops[1]):
                return E([0xDB, self.byte(self.eval(ops[1][1:-1]))])
            raise AsmError('bad in')
        if m == 'out':
            if lo[0] == '(c)':
                if lo[1] == '0':
                    return E([0xED, 0x71])
                r = self.r8(lo[1])
                if r is None or r == 6:
                    raise AsmError('bad out')
                return E([0xED, 0x41 | r << 3])
            if lo[1] == 'a' and self.is_ind(ops[0]):
                return E([0xD3, self.byte(self.eval(ops[0][1:-1]))])
            raise AsmError('bad out')
        raise AsmError('unknown instruction %s %s' % (mn, ','.join(ops)))

    def ld(self, ops, lo):
        E = self.emit
        if len(ops) != 2:
            raise AsmError('LD needs 2 operands')
        d, s = lo
        D, S = ops
        rd, rs = self.r8(d), self.r8(s)
        xd, xs = self.r8x(d), self.r8x(s)
        if rd is not None and rs is not None:
            if rd == 6 and rs == 6:
                raise AsmError('ld (hl),(hl)')
            return E([0x40 | rd << 3 | rs])
        # undocumented ixh/ixl
        if xd or xs:
            if xd and xs:
                if xd[0] != xs[0]:
                    raise AsmError('mixed ix/iy')
                return E([xd[0], 0x40 | xd[1] << 3 | xs[1]])
            if xd:
                if rs is not None and rs not in (4, 5, 6):
                    return E([xd[0], 0x40 | xd[1] << 3 | rs])
                if rs is None:
                    return E([xd[0], 0x06 | xd[1] << 3, self.byte(self.eval(S))])
            if xs and rd is not None and rd not in (4, 5, 6):
                return E([xs[0], 0x40 | rd << 3 | xs[1]])
            raise AsmError('bad ld with ixh/ixl')
        # special regs
        if d == 'a' and s == 'i':
            return E([0xED, 0x57])
        if d == 'a' and s == 'r':
            return E([0xED, 0x5F])
        if d == 'i' and s == 'a':
            return E([0xED, 0x47])
        if d == 'r' and s == 'a':
            return E([0xED, 0x4F])
        if d == 'a' and s == '(bc)':
            return E([0x0A])
        if d == 'a' and s == '(de)':
            return E([0x1A])
        if d == '(bc)' and s == 'a':
            return E([0x02])
        if d == '(de)' and s == 'a':
            return E([0x12])
        if d == 'sp' and s == 'hl':
            return E([0xF9])
        if d == 'sp' and s in ('ix', 'iy'):
            return E([0xDD if s == 'ix' else 0xFD, 0xF9])
        ixd, ixs = self.idx(D), self.idx(S)
        if ixd:
            if rs is not None and rs != 6:
                return E([ixd[0], 0x70 | rs, ixd[1]])
            return E([ixd[0], 0x36, ixd[1], self.byte(self.eval(S))])
        if ixs:
            if rd is not None and rd != 6:
                return E([ixs[0], 0x46 | rd << 3, ixs[1]])
            raise AsmError('bad ld from (ix+d)')
        if rd is not None:
            if rd == 7 and self.is_ind(S):
                return E([0x3A] + self.word(self.eval(S[1:-1])))
            if self.is_ind(S):
                raise AsmError('bad indirect load into r8')
            return E([0x06 | rd << 3, self.byte(self.eval(S))])
        if self.is_ind(D) and s == 'a':
            return E([0x32] + self.word(self.eval(D[1:-1])))
        if d in R16 or d in ('ix', 'iy'):
            if self.is_ind(S):
                v = self.word(self.eval(S[1:-1]))
                if d == 'hl':
                    return E([0x2A] + v)
                if d in ('ix', 'iy'):
                    return E([0xDD if d == 'ix' else 0xFD, 0x2A] + v)
                return E([0xED, 0x4B | R16[d] << 4] + v)
            v = self.word(self.eval(S))
            if d in ('ix', 'iy'):
                return E([0xDD if d == 'ix' else 0xFD, 0x21] + v)
            return E([0x01 | R16[d] << 4] + v)
        if self.is_ind(D) and (s in R16 or s in ('ix', 'iy')):
            v = self.word(self.eval(D[1:-1]))
            if s == 'hl':
                return E([0x22] + v)
            if s in ('ix', 'iy'):
                return E([0xDD if s == 'ix' else 0xFD, 0x22] + v)
            return E([0xED, 0x43 | R16[s] << 4] + v)
        raise AsmError('bad LD %s,%s' % (D, S))

    # ---------- driver ----------
    def read_lines(self, path, depth=0):
        if depth > 10:
            raise AsmError('include too deep')
        lines = []
        base = os.path.dirname(path)
        for i, line in enumerate(open(path, encoding='latin1')):
            s = strip_comment(line.rstrip('\n'))
            m = re.match(r'\s*include\s+"([^"]+)"', s, re.I)
            if m:
                lines += self.read_lines(os.path.join(base, m.group(1)), depth + 1)
            else:
                lines.append((path, i + 1, s))
        return lines

    def assemble(self, path):
        lines = self.read_lines(path)
        for p in (1, 2):
            self.pass_no = p
            self.pc = 0
            self.lastglobal = ''
            for fname, ln, s in lines:
                try:
                    self.line(s, os.path.dirname(fname))
                except AsmError as ex:
                    if p == 2 or 'duplicate' in str(ex):
                        self.errors.append('%s:%d: %s\n    %s' % (fname, ln, ex, s.strip()))
            if self.errors:
                break
        return self.errors

    def line(self, s, base):
        if not s.strip():
            return
        m = re.match(r'^([.A-Za-z_][A-Za-z0-9_.]*)\s*:?\s*(equ|=)\s*(.*)$', s.strip(), re.I)
        if m and (s[0] not in ' \t' or ':' in s.split()[0] or True) and m.group(2):
            name = m.group(1)
            if not name.startswith('.'):
                pass
            self.define(name, self.eval(m.group(3)))
            return
        m = re.match(r'^([.A-Za-z_][A-Za-z0-9_.]*):(.*)$', s.strip())
        if m:
            name = m.group(1)
            if not name.startswith('.'):
                self.lastglobal = name
            self.define(name, self.pc)
            s = m.group(2)
            if not s.strip():
                return
        s = s.strip()
        parts = s.split(None, 1)
        mn = parts[0]
        rest = parts[1] if len(parts) > 1 else ''
        ml = mn.lower()
        if ml == 'org':
            self.pc = self.eval(rest)
            return
        if ml in ('db', 'defb', 'dm', 'defm', 'byte'):
            for op in split_operands(rest):
                if op[0] in '"' or (op[0] == "'" and len(op) > 3):
                    q = op[0]
                    end = op.rindex(q)
                    txt = op[1:end]
                    self.emit([ord(c) for c in txt])
                    tail = op[end + 1:].strip()
                    if tail:
                        raise AsmError('junk after string')
                else:
                    self.emit([self.byte(self.eval(op))])
            return
        if ml in ('dw', 'defw', 'word'):
            for op in split_operands(rest):
                self.emit(self.word(self.eval(op)))
            return
        if ml in ('ds', 'defs'):
            o = split_operands(rest)
            cnt = self.eval(o[0])
            fill = self.eval(o[1]) if len(o) > 1 else 0
            self.emit([fill & 0xFF] * cnt)
            return
        if ml == 'align':
            a = self.eval(rest)
            while self.pc % a:
                self.emit([0])
            return
        if ml == 'incbin':
            fn = rest.strip().strip('"')
            data = open(os.path.join(base, fn), 'rb').read()
            self.emit(list(data))
            return
        if ml in ('assert',):
            if self.pass_no == 2 and not self.eval(rest):
                raise AsmError('assertion failed: ' + rest)
            return
        self.instr(mn, split_operands(rest))

    def image(self, start, end):
        return bytes(self.out.get(a, 0) for a in range(start, end))


def assemble_file(path):
    a = Assembler()
    errs = a.assemble(path)
    if errs:
        raise SystemExit('\n'.join(errs[:30]))
    return a


if __name__ == '__main__':
    a = assemble_file(sys.argv[1])
    lo, hi = min(a.out), max(a.out) + 1
    open(sys.argv[2], 'wb').write(a.image(lo, hi))
    print('assembled %04X-%04X (%d bytes)' % (lo, hi - 1, hi - lo))
