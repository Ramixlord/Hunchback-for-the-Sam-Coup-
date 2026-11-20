/* Minimal MCS-48 (i8035) emulator for the Donkey Kong / Hunchback sound board.
   Clock 6 MHz, 15 clocks per machine cycle -> 400,000 cycles/s.
   P1 drives the 8-bit DAC; BUS reads the command latch (P2 bit 6 set) as on the DK board. */
#include <stdint.h>
#include <string.h>
typedef uint8_t u8; typedef uint16_t u16; typedef uint32_t u32;

u8 rom[4096];
static u8 ram[64];
static u8 A, PSW, P1 = 0xff, P2 = 0xff, T, F1, MBF, TF, tirq_en, xirq_en, in_irq, tmr_on, cnt_on, pre;
static u16 PC;
int irq_line;        /* external /INT asserted (latched until taken or cleared) */
int t0_in, t1_in;
u8 latch_w = 0xff;   /* value the main CPU wrote to the 7C00 latch */
long long cyc;
/* DAC log */
u32 dac_t[1 << 22]; u8 dac_v[1 << 22], dac_p2[1 << 22]; int dac_n;

#define CY 0x80
#define AC 0x40
#define F0 0x20
#define BS 0x10
static inline u8 *Rn(int n) { return &ram[((PSW & BS) ? 24 : 0) + n]; }
static inline u8 fetch(void) { u8 v = rom[PC & 0xfff]; PC = (PC & 0x800) | ((PC + 1) & 0x7ff); return v; }
static u8 bus_read(void) {
  if (P2 & 0x40) return ((latch_w ^ 0x0f) & 0x0f);
  return 0xff;   /* no external sample ROM on this board */
}
static void push(void) {
  int sp = PSW & 7;
  ram[8 + sp * 2] = PC & 0xff;
  ram[9 + sp * 2] = ((PC >> 8) & 0x0f) | (PSW & 0xf0);
  PSW = (PSW & 0xf8) | ((sp + 1) & 7);
}
static void pop(int restore_psw) {
  int sp = (PSW - 1) & 7;
  PSW = (PSW & 0xf8) | sp;
  PC = ram[8 + sp * 2] | ((ram[9 + sp * 2] & 0x0f) << 8);
  if (restore_psw) PSW = (PSW & 0x0f) | (ram[9 + sp * 2] & 0xf0);
}
static void add(u8 v, int c) {
  int r = A + v + c;
  int h = (A & 15) + (v & 15) + c;
  PSW = (PSW & ~(CY | AC)) | (r > 255 ? CY : 0) | (h > 15 ? AC : 0);
  A = r;
}
static void p1_out(u8 v) {
  P1 = v;
  if (dac_n < (1 << 22)) { dac_t[dac_n] = (u32)cyc; dac_v[dac_n] = v; dac_p2[dac_n] = P2; dac_n++; }
}
static void p2_out(u8 v) {
  P2 = v;
  if (dac_n < (1 << 22)) { dac_t[dac_n] = (u32)cyc; dac_v[dac_n] = P1; dac_p2[dac_n] = P2; dac_n++; }
}
static void jcc(int cond) { u8 a = fetch(); if (cond) PC = (PC & 0xf00) | a; }
static void jmp_abs(u8 op) {
  u8 a = fetch();
  PC = ((in_irq ? 0 : MBF) << 11) | ((op >> 5) << 8) | a;
}

void reset(void) {
  memset(ram, 0, sizeof ram); A = 0; PSW = 0x08; PC = 0; P1 = P2 = 0xff; T = 0; F1 = 0; MBF = 0; TF = 0;
  tirq_en = xirq_en = in_irq = tmr_on = cnt_on = 0; pre = 0; irq_line = 0; cyc = 0; dac_n = 0;
}

static int step(void) {
  u8 op = fetch();
  int c = 1;
  switch (op) {
  case 0x00: break;
  case 0x02: c = 2; break;                         /* OUTL BUS,A */
  case 0x03: add(fetch(), 0); c = 2; break;
  case 0x04: case 0x24: case 0x44: case 0x64: case 0x84: case 0xa4: case 0xc4: case 0xe4: jmp_abs(op); c = 2; break;
  case 0x05: xirq_en = 1; break;
  case 0x07: A--; break;
  case 0x08: A = bus_read(); c = 2; break;
  case 0x09: A = P1; c = 2; break;
  case 0x0a: A = P2; c = 2; break;
  case 0x10: case 0x11: ram[*Rn(op & 1) & 63]++; break;
  case 0x12: case 0x32: case 0x52: case 0x72: case 0x92: case 0xb2: case 0xd2: case 0xf2: jcc(A & (1 << (op >> 5))); c = 2; break;
  case 0x13: add(fetch(), (PSW & CY) ? 1 : 0); c = 2; break;
  case 0x14: case 0x34: case 0x54: case 0x74: case 0x94: case 0xb4: case 0xd4: case 0xf4: {
    u8 a = fetch(); push(); PC = ((in_irq ? 0 : MBF) << 11) | ((op >> 5) << 8) | a; c = 2; break; }
  case 0x15: xirq_en = 0; break;
  case 0x16: jcc(TF); TF = 0; c = 2; break;
  case 0x17: A++; break;
  case 0x18: case 0x19: case 0x1a: case 0x1b: case 0x1c: case 0x1d: case 0x1e: case 0x1f: (*Rn(op & 7))++; break;
  case 0x20: case 0x21: { u8 *p = &ram[*Rn(op & 1) & 63]; u8 t = *p; *p = A; A = t; break; }
  case 0x23: A = fetch(); c = 2; break;
  case 0x25: tirq_en = 1; break;
  case 0x26: jcc(!t0_in); c = 2; break;
  case 0x27: A = 0; break;
  case 0x28: case 0x29: case 0x2a: case 0x2b: case 0x2c: case 0x2d: case 0x2e: case 0x2f: { u8 *p = Rn(op & 7); u8 t = *p; *p = A; A = t; break; }
  case 0x30: case 0x31: { u8 *p = &ram[*Rn(op & 1) & 63]; u8 t = *p; *p = (t & 0xf0) | (A & 15); A = (A & 0xf0) | (t & 15); break; }
  case 0x35: tirq_en = 0; break;
  case 0x36: jcc(t0_in); c = 2; break;
  case 0x37: A = ~A; break;
  case 0x39: p1_out(A); c = 2; break;
  case 0x3a: p2_out(A); c = 2; break;
  case 0x3c: case 0x3d: case 0x3e: case 0x3f: c = 2; break;
  case 0x40: case 0x41: A |= ram[*Rn(op & 1) & 63]; break;
  case 0x42: A = T; break;
  case 0x43: A |= fetch(); c = 2; break;
  case 0x45: cnt_on = 1; tmr_on = 0; break;
  case 0x46: jcc(!t1_in); c = 2; break;
  case 0x47: A = (A << 4) | (A >> 4); break;
  case 0x48: case 0x49: case 0x4a: case 0x4b: case 0x4c: case 0x4d: case 0x4e: case 0x4f: A |= *Rn(op & 7); break;
  case 0x50: case 0x51: A &= ram[*Rn(op & 1) & 63]; break;
  case 0x53: A &= fetch(); c = 2; break;
  case 0x55: tmr_on = 1; cnt_on = 0; pre = 0; break;
  case 0x56: jcc(t1_in); c = 2; break;
  case 0x57: { int a = A; if ((a & 15) > 9 || (PSW & AC)) a += 6; if (a > 255) PSW |= CY;
               if (((a >> 4) & 15) > 9 || (PSW & CY) || a > 255) { a += 0x60; if (a > 255) PSW |= CY; } A = a; break; }
  case 0x58: case 0x59: case 0x5a: case 0x5b: case 0x5c: case 0x5d: case 0x5e: case 0x5f: A &= *Rn(op & 7); break;
  case 0x60: case 0x61: add(ram[*Rn(op & 1) & 63], 0); break;
  case 0x62: T = A; break;
  case 0x65: tmr_on = cnt_on = 0; break;
  case 0x67: { int cy = A & 1; A = (A >> 1) | ((PSW & CY) ? 0x80 : 0); PSW = (PSW & ~CY) | (cy ? CY : 0); break; }
  case 0x68: case 0x69: case 0x6a: case 0x6b: case 0x6c: case 0x6d: case 0x6e: case 0x6f: add(*Rn(op & 7), 0); break;
  case 0x70: case 0x71: add(ram[*Rn(op & 1) & 63], (PSW & CY) ? 1 : 0); break;
  case 0x75: break;
  case 0x76: jcc(F1); c = 2; break;
  case 0x77: A = (A >> 1) | (A << 7); break;
  case 0x78: case 0x79: case 0x7a: case 0x7b: case 0x7c: case 0x7d: case 0x7e: case 0x7f: add(*Rn(op & 7), (PSW & CY) ? 1 : 0); break;
  case 0x80: case 0x81: A = bus_read(); c = 2; break;
  case 0x83: pop(0); c = 2; break;
  case 0x85: PSW &= ~F0; break;
  case 0x86: jcc(irq_line); c = 2; break;          /* JNI: jump if /INT low (asserted) */
  case 0x88: fetch(); c = 2; break;
  case 0x89: p1_out(P1 | fetch()); c = 2; break;
  case 0x8a: p2_out(P2 | fetch()); c = 2; break;
  case 0x8c: case 0x8d: case 0x8e: case 0x8f: c = 2; break;
  case 0x90: case 0x91: c = 2; break;
  case 0x93: pop(1); in_irq = 0; c = 2; break;
  case 0x95: PSW ^= F0; break;
  case 0x96: jcc(A != 0); c = 2; break;
  case 0x97: PSW &= ~CY; break;
  case 0x98: fetch(); c = 2; break;
  case 0x99: p1_out(P1 & fetch()); c = 2; break;
  case 0x9a: p2_out(P2 & fetch()); c = 2; break;
  case 0x9c: case 0x9d: case 0x9e: case 0x9f: c = 2; break;
  case 0xa0: case 0xa1: ram[*Rn(op & 1) & 63] = A; break;
  case 0xa3: A = rom[(PC & 0xf00) | A]; c = 2; break;
  case 0xa5: F1 = 0; break;
  case 0xa7: PSW ^= CY; break;
  case 0xa8: case 0xa9: case 0xaa: case 0xab: case 0xac: case 0xad: case 0xae: case 0xaf: *Rn(op & 7) = A; break;
  case 0xb0: case 0xb1: { u8 v = fetch(); ram[*Rn(op & 1) & 63] = v; c = 2; break; }
  case 0xb3: PC = (PC & 0xf00) | rom[(PC & 0xf00) | A]; c = 2; break;
  case 0xb5: F1 ^= 1; break;
  case 0xb6: jcc(PSW & F0); c = 2; break;
  case 0xb8: case 0xb9: case 0xba: case 0xbb: case 0xbc: case 0xbd: case 0xbe: case 0xbf: *Rn(op & 7) = fetch(); c = 2; break;
  case 0xc5: PSW &= ~BS; break;
  case 0xc6: jcc(A == 0); c = 2; break;
  case 0xc7: A = PSW | 0x08; break;
  case 0xc8: case 0xc9: case 0xca: case 0xcb: case 0xcc: case 0xcd: case 0xce: case 0xcf: (*Rn(op & 7))--; break;
  case 0xd0: case 0xd1: A ^= ram[*Rn(op & 1) & 63]; break;
  case 0xd3: A ^= fetch(); c = 2; break;
  case 0xd5: PSW |= BS; break;
  case 0xd7: PSW = A | 0x08; break;
  case 0xd8: case 0xd9: case 0xda: case 0xdb: case 0xdc: case 0xdd: case 0xde: case 0xdf: A ^= *Rn(op & 7); break;
  case 0xe3: A = rom[0x300 | A]; c = 2; break;
  case 0xe5: MBF = 0; break;
  case 0xe6: jcc(!(PSW & CY)); c = 2; break;
  case 0xe7: A = (A << 1) | (A >> 7); break;
  case 0xe8: case 0xe9: case 0xea: case 0xeb: case 0xec: case 0xed: case 0xee: case 0xef: { u8 *p = Rn(op & 7); (*p)--; jcc(*p != 0); c = 2; break; }
  case 0xf0: case 0xf1: A = ram[*Rn(op & 1) & 63]; break;
  case 0xf5: MBF = 1; break;
  case 0xf6: jcc(PSW & CY); c = 2; break;
  case 0xf7: { int cy = A >> 7; A = (A << 1) | ((PSW & CY) ? 1 : 0); PSW = (PSW & ~CY) | (cy ? CY : 0); break; }
  case 0xf8: case 0xf9: case 0xfa: case 0xfb: case 0xfc: case 0xfd: case 0xfe: case 0xff: A = *Rn(op & 7); break;
  default: break;  /* illegal: treat as NOP */
  }
  return c;
}

static void timer_tick(int c) {
  if (!tmr_on) return;
  for (int i = 0; i < c; i++) {
    if (++pre == 32) { pre = 0; T++; if (T == 0) { TF = 1; } }
  }
}

int tirq_pending;
/* run n machine cycles */
void run(long long n) {
  long long end = cyc + n;
  while (cyc < end) {
    if (!in_irq) {
      if (irq_line && xirq_en) { push(); PC = 3; in_irq = 1; irq_line = 0; cyc += 2; continue; }
    }
    int c = step();
    timer_tick(c);
    cyc += c;
  }
}
u32 *get_dac_t(void) { return dac_t; }
u8 *get_dac_v(void) { return dac_v; }
u8 *get_dac_p2(void) { return dac_p2; }
int get_dac_n(void) { return dac_n; }
void clear_dac(void) { dac_n = 0; }
u8 *get_rom(void) { return rom; }
void set_latch(int v) { latch_w = v; }
void set_irq(int v) { irq_line = v; }
long long get_cyc(void) { return cyc; }
int get_pc(void) { return PC; }
u8 *get_ram(void) { return ram; }
int get_p2(void) { return P2; }
