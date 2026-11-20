/* Minimal SAM Coupe emulator core for headless testing.
   Z80 (documented ops + IXH/IXL), SAM paging (LMPR/HMPR/VMPR), CLUT,
   keyboard matrix, frame interrupt, rough mode-4 contention model.
   No ROM: section A with ROM0 paged reads 0xFF. */
#include <stdint.h>
#include <string.h>
#include <stdio.h>

typedef uint8_t u8; typedef uint16_t u16; typedef uint32_t u32;

u8 ram[32 * 16384];
u8 lmpr, hmpr, vmpr, border, lineint = 255, clut[16];
u8 keys[9];          /* rows: index 0..7 = A8..A15, 8 = extra row (0xFF) ; bit=0 pressed */
u32 saa_writes; u8 saa_reg, saa[32];
u32 tstate;          /* T within frame (effective) */
int int_pending;
u16 watch_pc = 0xFFFF; int watch_hits; u32 watch_t[64];
u32 frame_no;
int halted;
int bad_op; u16 bad_pc;
u32 dbg_out[256];

/* registers */
u8 A, F, B, C, D, E, H, L, A_, F_, B_, C_, D_, E_, H_, L_, I, R, IFF1, IFF2, IM;
u16 IX, IY, SP, PC;

#define FC 1
#define FN 2
#define FP 4
#define FX 8
#define FH 16
#define FY 32
#define FZ 64
#define FS 128
u8 sz53p[256], sz53[256], parity[256];

static inline int page_of(u16 a) {
  switch (a >> 14) {
  case 0: return (lmpr & 0x20) ? (lmpr & 31) : -1;
  case 1: return (lmpr + 1) & 31;
  case 2: return hmpr & 31;
  default: return (hmpr + 1) & 31;
  }
}
static inline u8 rd(u16 a) { int p = page_of(a); if (p < 0) return 0xFF; return ram[p * 16384 + (a & 0x3FFF)]; }
static inline void wr(u16 a, u8 v) {
  int p = page_of(a); if (p < 0) return;
  if ((a >> 14) == 0 && (lmpr & 0x80)) return;
  ram[p * 16384 + (a & 0x3FFF)] = v;
}
static inline u16 rd16(u16 a) { return rd(a) | (rd(a + 1) << 8); }
static inline void wr16(u16 a, u16 v) { wr(a, v & 255); wr(a + 1, v >> 8); }

u32 saalog[1<<20][2]; int saalog_n; long long total_t;
u8 in_port(u16 port) {
  u8 lo = port & 255, hi = port >> 8;
  if (lo == 0xFE) {
    u8 v = 0x1F;
    if (hi == 0xFF) return 0xE0 | (keys[8] & 0x1F);
    for (int i = 0; i < 8; i++) if (!(hi & (1 << i))) v &= keys[i];
    return 0xE0 | v;
  }
  if (lo == 0xF9) { /* status: bit3 low during frame int */
    u8 v = 0xFF; if (int_pending) v &= ~8; return v;
  }
  if (lo == 0xFA) return lmpr;
  if (lo == 0xFB) return hmpr;
  if (lo == 0xFC) return vmpr;
  return 0xFF;
}
void out_port(u16 port, u8 v) {
  u8 lo = port & 255;
  if (lo == 0xFA) lmpr = v;
  else if (lo == 0xFB) hmpr = v;
  else if (lo == 0xFC) vmpr = v;
  else if (lo == 0xFE) border = v;
  else if (lo == 0xF8) clut[(port >> 8) & 15] = v & 127;
  else if (lo == 0xF9) lineint = v;
  else if (lo == 0xFF) { if (port & 0x100) saa_reg = v & 31; else { saa[saa_reg] = v; saa_writes++; if (saalog_n < (1<<20)) { saalog[saalog_n][0] = (u32)((frame_no * 119808ULL + tstate) >> 4); saalog[saalog_n][1] = (saa_reg << 8) | v; saalog_n++; } } }
  dbg_out[lo]++;
}

void init_tables(void) {
  for (int i = 0; i < 256; i++) {
    int p = 0; for (int b = 0; b < 8; b++) p ^= (i >> b) & 1;
    parity[i] = p ? 0 : FP;
    sz53[i] = (i & (FS | FY | FX)) | (i ? 0 : FZ);
    sz53p[i] = sz53[i] | parity[i];
  }
}

#define BC ((B << 8) | C)
#define DE ((D << 8) | E)
#define HL ((H << 8) | L)
#define SETBC(v) do { u16 _v = (v); B = _v >> 8; C = _v; } while (0)
#define SETDE(v) do { u16 _v = (v); D = _v >> 8; E = _v; } while (0)
#define SETHL(v) do { u16 _v = (v); H = _v >> 8; L = _v; } while (0)

static inline u8 fetch(void) { return rd(PC++); }
static inline u16 fetch16(void) { u16 v = rd16(PC); PC += 2; return v; }
static inline void push16(u16 v) { SP -= 2; wr16(SP, v); }
static inline u16 pop16(void) { u16 v = rd16(SP); SP += 2; return v; }

static inline void add8(u8 v, int c) {
  int r = A + v + c;
  u8 f = (r & 0x100 ? FC : 0) | ((A ^ v ^ r) & FH) | sz53[r & 255];
  if (!((A ^ v) & 0x80) && ((A ^ r) & 0x80)) f |= FP;
  A = r; F = f;
}
static inline void sub8(u8 v, int c, int store) {
  int r = A - v - c;
  u8 f = FN | (r & 0x100 ? FC : 0) | ((A ^ v ^ r) & FH) | sz53[r & 255];
  if (((A ^ v) & 0x80) && ((A ^ r) & 0x80)) f |= FP;
  if (store) A = r; else f = (f & ~(FX | FY)) | (v & (FX | FY));
  F = f;
}
static inline void alu(int op, u8 v) {
  switch (op) {
  case 0: add8(v, 0); break;
  case 1: add8(v, F & FC); break;
  case 2: sub8(v, 0, 1); break;
  case 3: sub8(v, F & FC, 1); break;
  case 4: A &= v; F = sz53p[A] | FH; break;
  case 5: A ^= v; F = sz53p[A]; break;
  case 6: A |= v; F = sz53p[A]; break;
  case 7: sub8(v, 0, 0); break;
  }
}
static inline u8 inc8(u8 v) { u8 r = v + 1; F = (F & FC) | sz53[r] | ((r & 15) == 0 ? FH : 0) | (r == 0x80 ? FP : 0); return r; }
static inline u8 dec8(u8 v) { u8 r = v - 1; F = (F & FC) | FN | sz53[r] | ((v & 15) == 0 ? FH : 0) | (v == 0x80 ? FP : 0); return r; }
static inline u16 add16(u16 a, u16 b) {
  u32 r = a + b;
  F = (F & (FS | FZ | FP)) | (r & 0x10000 ? FC : 0) | (((a ^ b ^ r) >> 8) & FH) | ((r >> 8) & (FX | FY));
  return r;
}
static inline void adc16(u16 v) {
  u16 hl = HL; u32 r = hl + v + (F & FC);
  u8 f = (r & 0x10000 ? FC : 0) | (((hl ^ v ^ r) >> 8) & FH) | ((r >> 8) & (FS | FX | FY)) | ((r & 0xFFFF) ? 0 : FZ);
  if (!((hl ^ v) & 0x8000) && ((hl ^ r) & 0x8000)) f |= FP;
  SETHL(r); F = f;
}
static inline void sbc16(u16 v) {
  u16 hl = HL; u32 r = hl - v - (F & FC);
  u8 f = FN | (r & 0x10000 ? FC : 0) | (((hl ^ v ^ r) >> 8) & FH) | ((r >> 8) & (FS | FX | FY)) | ((r & 0xFFFF) ? 0 : FZ);
  if (((hl ^ v) & 0x8000) && ((hl ^ r) & 0x8000)) f |= FP;
  SETHL(r); F = f;
}
static inline u8 rot(int op, u8 v) {
  u8 r, c;
  switch (op) {
  case 0: c = v >> 7; r = (v << 1) | c; break;
  case 1: c = v & 1; r = (v >> 1) | (c << 7); break;
  case 2: c = v >> 7; r = (v << 1) | (F & FC); break;
  case 3: c = v & 1; r = (v >> 1) | ((F & FC) << 7); break;
  case 4: c = v >> 7; r = v << 1; break;
  case 5: c = v & 1; r = (v >> 1) | (v & 0x80); break;
  case 6: c = v >> 7; r = (v << 1) | 1; break;
  default: c = v & 1; r = v >> 1; break;
  }
  F = sz53p[r] | c; return r;
}
static inline int cond(int cc) {
  switch (cc) {
  case 0: return !(F & FZ); case 1: return F & FZ; case 2: return !(F & FC); case 3: return F & FC;
  case 4: return !(F & FP); case 5: return F & FP; case 6: return !(F & FS); default: return F & FS;
  }
}

/* register access by index for main table; idx: 0 = HL, 1 = IX, 2 = IY */
static u8 *r8p(int r, int idx) {
  switch (r) {
  case 0: return &B; case 1: return &C; case 2: return &D; case 3: return &E;
  case 4: return idx == 0 ? &H : idx == 1 ? ((u8 *)&IX) + 1 : ((u8 *)&IY) + 1;
  case 5: return idx == 0 ? &L : idx == 1 ? ((u8 *)&IX) : ((u8 *)&IY);
  case 7: return &A;
  }
  return 0;
}

static int cb_op(u16 addr, int indexed, u8 op) {
  int x = op >> 6, y = (op >> 3) & 7, z = op & 7;
  u8 v;
  if (indexed || z == 6) v = rd(addr); else v = *r8p(z, 0);
  if (x == 1) { /* BIT */
    u8 r = v & (1 << y);
    F = (F & FC) | FH | (r ? 0 : (FZ | FP)) | (r & FS) | (v & (FX | FY));
    return indexed ? 20 : (z == 6 ? 12 : 8);
  }
  u8 r;
  if (x == 0) r = rot(y, v); else if (x == 2) r = v & ~(1 << y); else r = v | (1 << y);
  if (indexed) { wr(addr, r); if (z != 6) *r8p(z, 0) = r; return 23; }
  if (z == 6) { wr(addr, r); return 15; }
  *r8p(z, 0) = r; return 8;
}

static u16 getrp(int p, int idx) {
  switch (p) { case 0: return BC; case 1: return DE; case 2: return idx == 0 ? HL : idx == 1 ? IX : IY; default: return SP; }
}
static void setrp(int p, int idx, u16 v) {
  switch (p) { case 0: SETBC(v); break; case 1: SETDE(v); break;
  case 2: if (idx == 0) SETHL(v); else if (idx == 1) IX = v; else IY = v; break; default: SP = v; }
}

static int ed_op(void) {
  u8 op = fetch(); R++;
  int x = op >> 6, y = (op >> 3) & 7, z = op & 7, p = y >> 1, q = y & 1;
  if (x == 1) {
    switch (z) {
    case 0: { u8 v = in_port(BC); if (y != 6) *r8p(y, 0) = v; F = (F & FC) | sz53p[v]; return 12; }
    case 1: out_port(BC, y == 6 ? 0 : *r8p(y, 0)); return 12;
    case 2: if (q == 0) sbc16(getrp(p, 0)); else adc16(getrp(p, 0)); return 15;
    case 3: { u16 a = fetch16(); if (q == 0) wr16(a, getrp(p, 0)); else setrp(p, 0, rd16(a)); return 20; }
    case 4: { u8 a = A; A = 0; sub8(a, 0, 1); return 8; }
    case 5: IFF1 = IFF2; PC = pop16(); return 14;
    case 6: IM = (y & 3) == 0 ? 0 : (y & 3) == 2 ? 1 : 2; if ((y & 3) == 1) IM = 0; return 8;
    case 7:
      switch (y) {
      case 0: I = A; return 9;
      case 1: R = A; return 9;
      case 2: A = I; F = (F & FC) | sz53[A] | (IFF2 ? FP : 0); return 9;
      case 3: A = R; F = (F & FC) | sz53[A] | (IFF2 ? FP : 0); return 9;
      case 4: { u8 m = rd(HL); wr(HL, (A << 4) | (m >> 4)); A = (A & 0xF0) | (m & 15); F = (F & FC) | sz53p[A]; return 18; } /* RRD */
      case 5: { u8 m = rd(HL); wr(HL, (m << 4) | (A & 15)); A = (A & 0xF0) | (m >> 4); F = (F & FC) | sz53p[A]; return 18; } /* RLD */
      default: return 8;
      }
    }
  }
  if (x == 2 && z <= 3 && y >= 4) {
    int inc = (y & 1) ? -1 : 1, rep = y >= 6;
    switch (z) {
    case 0: { u8 v = rd(HL); wr(DE, v); SETHL(HL + inc); SETDE(DE + inc); SETBC(BC - 1);
      F = (F & (FS | FZ | FC)) | (BC ? FP : 0);
      if (rep && BC) { PC -= 2; return 21; } return 16; }
    case 1: { u8 v = rd(HL); u8 r = A - v; SETHL(HL + inc); SETBC(BC - 1);
      F = (F & FC) | FN | sz53[r] | ((A ^ v ^ r) & FH) | (BC ? FP : 0); F &= ~(FX|FY);
      if (rep && BC && r) { PC -= 2; return 21; } return 16; }
    case 2: { u8 v = in_port(BC); wr(HL, v); SETHL(HL + inc); B--; F = (B ? 0 : FZ) | FN;
      if (rep && B) { PC -= 2; return 21; } return 16; }
    case 3: { u8 v = rd(HL); B--; out_port(BC, v); SETHL(HL + inc); F = (B ? 0 : FZ) | FN;
      if (rep && B) { PC -= 2; return 21; } return 16; }
    }
  }
  bad_op = 0x100 | op; bad_pc = PC - 2;
  return 8;
}

static int step(void) {
  int idx = 0;
  u8 op = fetch(); R = (R & 0x80) | ((R + 1) & 0x7F);
  int extra = 0;
  while (op == 0xDD || op == 0xFD) { idx = op == 0xDD ? 1 : 2; op = fetch(); extra += 4; }
  if (op == 0xED) return ed_op() + 4;
  if (op == 0xCB) {
    if (idx) { int8_t d = fetch(); u8 o = fetch(); u16 base = idx == 1 ? IX : IY; return cb_op(base + d, 1, o) + 3; }
    return cb_op(HL, 0, fetch());
  }
  int x = op >> 6, y = (op >> 3) & 7, z = op & 7, p = y >> 1, q = y & 1;
  /* memory operand address for (HL)/(IX+d) */
#define MADDR() (idx == 0 ? HL : (u16)((idx == 1 ? IX : IY) + (int8_t)fetch()))
  if (x == 1) {
    if (op == 0x76) { halted = 1; PC--; return 4; }
    if (z == 6) { u16 a = MADDR(); *r8p(y, 0) = rd(a); return idx ? 19 : 7; }
    if (y == 6) { u16 a = MADDR(); wr(a, *r8p(z, 0)); return idx ? 19 : 7; }
    *r8p(y, idx) = *r8p(z, idx); return 4 + extra;
  }
  if (x == 2) {
    if (z == 6) { u16 a = MADDR(); alu(y, rd(a)); return idx ? 19 : 7; }
    alu(y, *r8p(z, idx)); return 4 + extra;
  }
  if (x == 0) {
    switch (z) {
    case 0:
      switch (y) {
      case 0: return 4;
      case 1: { u8 t = A; A = A_; A_ = t; t = F; F = F_; F_ = t; return 4; }
      case 2: { int8_t d = fetch(); B--; if (B) { PC += d; return 13; } return 8; }
      case 3: { int8_t d = fetch(); PC += d; return 12; }
      default: { int8_t d = fetch(); if (cond(y - 4)) { PC += d; return 12; } return 7; }
      }
    case 1:
      if (q == 0) { setrp(p, idx, fetch16()); return 10 + extra; }
      { u16 v = add16(getrp(2, idx), getrp(p, idx)); setrp(2, idx, v); return 11 + extra; }
    case 2:
      switch (y) {
      case 0: wr(BC, A); return 7;
      case 1: A = rd(BC); return 7;
      case 2: wr(DE, A); return 7;
      case 3: A = rd(DE); return 7;
      case 4: wr16(fetch16(), getrp(2, idx)); return 16 + extra;
      case 5: setrp(2, idx, rd16(fetch16())); return 16 + extra;
      case 6: wr(fetch16(), A); return 13;
      default: A = rd(fetch16()); return 13;
      }
    case 3:
      if (q == 0) setrp(p, idx, getrp(p, idx) + 1); else setrp(p, idx, getrp(p, idx) - 1);
      return 6 + extra;
    case 4: case 5:
      if (y == 6) { u16 a = MADDR(); u8 v = rd(a); wr(a, z == 4 ? inc8(v) : dec8(v)); return idx ? 23 : 11; }
      { u8 *r = r8p(y, idx); *r = z == 4 ? inc8(*r) : dec8(*r); return 4 + extra; }
    case 6:
      if (y == 6) { u16 a = MADDR(); wr(a, fetch()); return idx ? 19 : 10; }
      *r8p(y, idx) = fetch(); return 7 + extra;
    case 7:
      switch (y) {
      case 0: { u8 c = A >> 7; A = (A << 1) | c; F = (F & (FS | FZ | FP)) | c | (A & (FX | FY)); return 4; }
      case 1: { u8 c = A & 1; A = (A >> 1) | (c << 7); F = (F & (FS | FZ | FP)) | c | (A & (FX | FY)); return 4; }
      case 2: { u8 c = A >> 7; A = (A << 1) | (F & FC); F = (F & (FS | FZ | FP)) | c | (A & (FX | FY)); return 4; }
      case 3: { u8 c = A & 1; A = (A >> 1) | ((F & FC) << 7); F = (F & (FS | FZ | FP)) | c | (A & (FX | FY)); return 4; }
      case 4: { /* DAA */
        u8 a = A, c = F & FC, add = 0;
        if ((F & FH) || (a & 15) > 9) add = 6;
        if (c || a > 0x99) { add |= 0x60; c = FC; }
        if (F & FN) { A = a - add; F = FN | c | sz53p[A] | (((a & 15) < (add & 15)) && (F & FH) ? FH : 0); }
        else { A = a + add; F = c | sz53p[A] | (((a & 15) > 9) ? FH : 0); }
        return 4; }
      case 5: A = ~A; F = (F & (FS | FZ | FP | FC)) | FH | FN | (A & (FX | FY)); return 4;
      case 6: F = (F & (FS | FZ | FP)) | FC | (A & (FX | FY)); return 4;
      default: F = (F & (FS | FZ | FP)) | ((F & FC) ? FH : FC) | (A & (FX | FY)); return 4;
      }
    }
  }
  /* x == 3 */
  switch (z) {
  case 0: if (cond(y)) { PC = pop16(); return 11; } return 5;
  case 1:
    if (q == 0) { if (p == 3) { u16 v = pop16(); A = v >> 8; F = v; } else setrp(p, idx, pop16()); return 10 + extra; }
    switch (p) {
    case 0: PC = pop16(); return 10;
    case 1: { u8 t; t = B; B = B_; B_ = t; t = C; C = C_; C_ = t; t = D; D = D_; D_ = t; t = E; E = E_; E_ = t; t = H; H = H_; H_ = t; t = L; L = L_; L_ = t; return 4; }
    case 2: PC = getrp(2, idx); return 4 + extra;
    default: SP = getrp(2, idx); return 6 + extra;
    }
  case 2: { u16 a = fetch16(); if (cond(y)) PC = a; return 10; }
  case 3:
    switch (y) {
    case 0: PC = fetch16(); return 10;
    case 2: out_port((A << 8) | fetch(), A); return 11;
    case 3: { u8 n = fetch(); A = in_port((A << 8) | n); return 11; }
    case 4: { u16 t = rd16(SP); wr16(SP, getrp(2, idx)); setrp(2, idx, t); return 19 + extra; }
    case 5: { u16 t = DE; SETDE(HL); SETHL(t); return 4; }
    case 6: IFF1 = IFF2 = 0; return 4;
    case 7: IFF1 = IFF2 = 1; return 4;
    }
    break;
  case 4: { u16 a = fetch16(); if (cond(y)) { push16(PC); PC = a; return 17; } return 10; }
  case 5:
    if (q == 0) { u16 v = p == 3 ? ((A << 8) | F) : getrp(p, idx); push16(v); return 11 + extra; }
    if (p == 0) { u16 a = fetch16(); push16(PC); PC = a; return 17; }
    break;
  case 6: alu(y, fetch()); return 7;
  case 7: push16(PC); PC = y * 8; return 11;
  }
  bad_op = op; bad_pc = PC - 1;
  return 4;
}

static void take_int(void) {
  if (!IFF1) return;
  if (halted) { halted = 0; PC++; }
  IFF1 = IFF2 = 0;
  push16(PC);
  if (IM == 2) PC = rd16((I << 8) | 0xFF);
  else PC = 0x38;
  tstate += 13;
}

int cont_disp = 32, cont_border = 19;
void set_contention(int d, int b) { cont_disp = d; cont_border = b; }
/* contention factor in 1/16 units */
static inline int cfactor(void) {
  u32 line = (tstate / 384);
  u32 lpos = tstate % 384;
  int mode4 = ((vmpr >> 5) & 3) >= 2;
  /* frame: interrupt at tstate 0 which we treat as start of line 192 (bottom border).
     display lines are 120..311 relative to the interrupt */
  if (!mode4) return 16;
  if (line >= 120 && lpos < 256) return cont_disp;
  return cont_border;
}

#define FRAME_T 119808
u32 prof[65536];
u32 *get_prof(void) { return prof; }
void clear_prof(void) { memset(prof, 0, sizeof(prof)); }
u32 max_steps_frame = 10000000;

/* run one frame. returns 0 ok, else bad opcode */
u16 minsp = 0xffff;
int get_minsp(void){return minsp;}
void reset_minsp(void){minsp=0xffff;}
int run_frame(void) {
  tstate = 0;
  int_pending = 1;
  watch_hits = 0;
  while (tstate < FRAME_T) {
    if (int_pending && tstate >= 128) int_pending = 0;
    if (int_pending && IFF1) take_int();
    if (PC == watch_pc && watch_hits < 64) watch_t[watch_hits++] = tstate;
    u16 pc0 = PC;
    int t = step();
    if (SP < minsp && SP > 0x4000) minsp = SP;
    int te = (t * cfactor()) >> 4;
    tstate += te;
    if (pc0 < 0x8000) prof[pc0] += te;
    total_t += t;
    if (bad_op) return bad_op;
  }
  frame_no++;
  return 0;
}

/* accessors for ctypes */
u8 *get_ram(void) { return ram; }
u8 *get_clut(void) { return clut; }
u8 *get_keys(void) { return keys; }
u8 *get_saa(void) { return saa; }
void set_paging(int l, int h, int v) { lmpr = l; hmpr = h; vmpr = v; }
int get_vmpr(void) { return vmpr; }
int get_lmpr(void) { return lmpr; }
int get_hmpr(void) { return hmpr; }
void set_pc_sp(int pc, int sp) { PC = pc; SP = sp; }
int get_pc(void) { return PC; }
int get_sp(void) { return SP; }
int get_bad_pc(void) { return bad_pc; }
void set_watch(int pc) { watch_pc = pc; }
int get_watch_hits(void) { return watch_hits; }
u32 *get_watch_t(void) { return watch_t; }
u32 get_frame(void) { return frame_no; }
int get_iff(void) { return IFF1 | (IM << 4); }
void reset(void) {
  init_tables(); memset(keys, 0x1F, 9); A = F = B = C = D = E = H = L = 0; IX = IY = 0; I = R = 0;
  IFF1 = IFF2 = 0; IM = 1; halted = 0; bad_op = 0; frame_no = 0;
}
u16 get_reg(int i) {
  switch (i) { case 0: return (A << 8) | F; case 1: return BC; case 2: return DE; case 3: return HL;
  case 4: return IX; case 5: return IY; case 6: return SP; default: return PC; }
}

/* snapshot support for look-ahead test bots */
typedef struct {
  u8 ram[32 * 16384]; u8 lmpr, hmpr, vmpr, border, lineint, clut[16], keys[9], saa_reg, saa[32];
  u8 A, F, B, C, D, E, H, L, A_, F_, B_, C_, D_, E_, H_, L_, I, R, IFF1, IFF2, IM;
  u16 IX, IY, SP, PC; int halted, int_pending; u32 frame_no, saa_writes;
} snap_t;
#define NSNAP 128
static snap_t snaps[NSNAP];
#define CP(x) d->x = x
#define RS(x) x = d->x
void snap_save(int i) { snap_t *d = &snaps[i]; memcpy(d->ram, ram, sizeof ram); memcpy(d->clut, clut, 16); memcpy(d->keys, keys, 9); memcpy(d->saa, saa, 32);
  CP(lmpr); CP(hmpr); CP(vmpr); CP(border); CP(lineint); CP(saa_reg); CP(A); CP(F); CP(B); CP(C); CP(D); CP(E); CP(H); CP(L);
  CP(A_); CP(F_); CP(B_); CP(C_); CP(D_); CP(E_); CP(H_); CP(L_); CP(I); CP(R); CP(IFF1); CP(IFF2); CP(IM);
  CP(IX); CP(IY); CP(SP); CP(PC); CP(halted); CP(int_pending); CP(frame_no); CP(saa_writes); }
void snap_load(int i) { snap_t *d = &snaps[i]; memcpy(ram, d->ram, sizeof ram); memcpy(clut, d->clut, 16); memcpy(saa, d->saa, 32);
  RS(lmpr); RS(hmpr); RS(vmpr); RS(border); RS(lineint); RS(saa_reg); RS(A); RS(F); RS(B); RS(C); RS(D); RS(E); RS(H); RS(L);
  RS(A_); RS(F_); RS(B_); RS(C_); RS(D_); RS(E_); RS(H_); RS(L_); RS(I); RS(R); RS(IFF1); RS(IFF2); RS(IM);
  RS(IX); RS(IY); RS(SP); RS(PC); RS(halted); RS(int_pending); RS(frame_no); RS(saa_writes); }

u32 *get_saalog(void){return &saalog[0][0];}
int get_saalog_n(void){return saalog_n;}
void clear_saalog(void){saalog_n=0;}
