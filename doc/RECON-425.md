# OmniBook 425 PCMCIA host recon — clean-room, probe-derived (2026-07-18)

Method: every fact below was measured live on the OmniBook 425 with SSCALL.COM
(probes/SSCALL.ASM — raw INT 1A register caller) over the COMrade link, or read
from spec docs in doc/SS-SPEC-NOTES.md. No HP code was read or disassembled.
Machine: HP MS-DOS 5.00 E.00.00, BIOS date 07/31/93, model byte FCh.
CONFIG.SYS loads d:\omnibook\obmgm.com and d:\omnibook\obcic.exe /GEN 1
(environment fact only — contents never examined).

## Socket Services host

- `SSCALL 8000` → CF=0 AX=8001 CX=5353 ('SS'): Socket Services present, 1 adapter.
- `SSCALL 8300` → AX=0100 (SS spec v1.00), BX=0000, DS:SI=F000:8DA9 →
  implementor string "HP CVD slf" (in BIOS ROM segment — SS lives in ROM).
- `SSCALL 8400` (InquireAdapter) → BH=08 windows, BL=04 sockets, CX=0 EDCs,
  DH=08 (status-change interrupt present), DL=13h (vendor-specific routing).
- `SSCALL 8500` (GetAdapter) → DH=04 (status-change ints enabled, no power
  reduction active).

## Sockets (1-based, per spec)

Card status via `SSCALL 8F00 000n` (T00660: bit7=CD, bit6=RDY, bit0=WP).
**CORRECTED topology** (first reading below was misinterpreted — RDY/WP lines
FLOAT HIGH on unpowered sockets here, so status heuristics are meaningless;
per operator + window-map evidence):

| Socket | Status | Physical role |
|--------|--------|---------------|
| 1 | C1 (floating) | LEFT USER SLOT — KXL-C101 (unpowered; RDY/WP float) |
| 2 | 41 | RIGHT USER SLOT — empty (floats with no card) |
| 3 | 80 | storage slot (always populated; SunDisk; unpowered, not OS-mapped this boot) |
| 4 | C1 | storage/ROM slot — OS drive mappings live here (DO NOT TOUCH) |

The only reliable "in use by the OS" signal is an **enabled common-memory
window pointing at the socket** (true for socket 4 only — windows 1-3).
Status-byte heuristics (my original "READY+WP = system card" rule) are WRONG.

- InquireSocket(3) → DH=01, socket characteristics @F000:8DB8:
  card types = 0003 (memory+I/O), steerable IRQs bitmap 4CB8h =
  {3,4,5,7,10,11,14}, no NMI/other steering.
- Power table @F000:8DC4: 2 entries — [0x32,0xE0] = 5.0V Vcc+Vpp1+Vpp2,
  [0x78,0x60] = 12.0V Vpp1+Vpp2 only.
- **Power indices are 1-BASED in Get/SetSocket CH/CL** (spec-ambiguous, probed):
  - SetSocket CH=01 CL=11 accepted; card became functional at 5V ⇒ 1 = entry 1 = 5V.
  - SetSocket CH=00 → CF=1 AH=0Eh BAD_VCC ⇒ 0 is invalid, not "off".
  - No software Vcc-off encoding found (0Fh untried — not needed by enabler).
- SetSocket DOES take Vcc in CH (RBIL's v1.00 entry omits it; symmetric with
  GetSocket per probing: CH accepted and enforced).
- GetSocket(3) as-found: BH=C0, CH=01, CL=11, DH=00, SI=0001(memory), DI=0003
  (steering disabled, level bits 3).

## Windows

InquireWindow (`SSCALL 8700 0n00`):

- **Windows 0-3: memory windows.** caps BL=03 (common+attribute), sockets
  bitmap CX=000F (all 4, bit0=socket1), speeds DL=35 (WAIT,150,250,300ns).
  Characteristics @F000:9524: caps=00B1 (prog base, 16-bit, base align on size,
  card-offset align on size — size NOT programmable, no enable/disable cap),
  base A0h-100h pages (A0000h-FFFFFh), size fixed 4 pages = 16KB,
  granularity/alignment 16KB.
- **Windows 4-7: I/O windows.** caps BL=04 (I/O), sockets bitmap CX=0007
  (sockets 1-3 only), speeds DL=21 (WAIT, 300ns). Characteristics @F000:9534:
  caps=007F (prog base+size, en/disable, 8+16-bit, align, pow2 gran),
  base 0-400h, size 1-16 bytes, granularity 1.

GetWindow (`SSCALL 8800 0n00`) as-found state:

| Win | Socket | Base | Size | Attrs | Notes |
|-----|--------|-------|------|-------|-------|
| 0 | 3 | D0000 | 16K | 0E (attr,en,16b) | idle attribute window onto socket 3 |
| 1 | 4 | D4000 | 16K | 0C (common,en,16b) | system drive mapping — DO NOT TOUCH |
| 2 | 4 | D8000 | 16K | 0C | system drive mapping — DO NOT TOUCH |
| 3 | 4 | DC000 | 16K | 0C | system drive mapping — DO NOT TOUCH |

**DH attribute bit0 is INVERTED from RBIL T00678 on this implementation**:
memory windows idle/accept bit0=0 (attr window byte = 0Eh; 07h → BAD_TYPE 0Dh),
I/O windows idle with DH=01h and require bit0=1 (05h = I/O+enable works;
04h/0Ch → BAD_TYPE). GetWindow 4/5 as-found: socket 1, base 100h/101h, size 1,
DH=01, disabled — dormant modem-recognizer probe windows.

## CIS access path (proven end-to-end)

Socket 3 (SunDisk flash card present during recon):
SetSocket(mask C0, Vcc=1, Vpp=11h, type=memory) → ResetCard → status 80→C0
(READY) → attribute memory visible at D000:0000 through window 0: even bytes
carry the CIS (odd bytes float 0x50). Read+parsed a full valid SunDisk SDP5
CIS (MANFID 0045/0401, FUNCID 04 fixed-disk, VERS_1 "SunDisk SDP5 1.0") —
validates power-up recipe, window path, and even-byte convention on this host.

## Hazards / rules for the enabler

1. Never touch a socket mapped by an enabled common-memory window (OS drive
   mapping — socket 4 here). This is the ONLY valid in-use signal; card-status
   bits float and must not be used to classify sockets.
2. Never touch memory windows 1-3 (socket-4 drive mappings). Use window 0 for
   CIS reads; save its GetWindow state and restore it afterwards.
3. I/O windows are 16 bytes max, base ≤ 400h ⇒ ES1688 base 220h/16B fits in one
   window; FM 388h/4B and MPU 330h/2B need their own windows (4,5,6 free).
4. Serial console can garble typed commands — state-changing sequences must run
   atomically inside a .COM, not as interactive SSCALL chains.
5. COM link lives on a COM port (3F8/2F8/3E8 per BDA) — no I/O windows there
   (targets 220/330/388 are all clear).
6. Status-change interrupt is enabled at adapter level (vendor routing 13h) —
   OBCIC gets notified of card events; expect it may probe freshly-inserted
   cards. Enabler runs after insertion settles.

## Current deviation from as-found state

Socket 3 SunDisk left POWERED (5V, memory IF) after CIS validation — no
software Vcc-off exists; harmless, clears on card removal/reboot.

## KXL-C101 (socket 1) — CIS captured on this box (dumps/CIS1-kxlc101.bin)

MANFID 0032/0204, FUNCID 00 (multifunction: audio + CD-ROM interface),
VERS_1 "KME","KXLC101","00". CONFIG: regs at attr 0400h, RMSK 03 (COR+CCSR),
last index 27h. CFTABLE: default entry 20h = I/O 16-bit, Vcc 5V, ranges
[relocatable 32B] + [0388h/4], level IRQ any line; entries 24h/25h/26h/27h =
fixed 0220h/0240h/0260h/0280h (32 bytes) + 0388h/4, 10 addr lines.
**Index 24h = classic SB layout.** No MPU-401 range — card has none, and no
usable gameport either (corrected 2026-07-18; the ES1688GO manifest's
no_joy=0 for this card is wrong). The upper half of the 32-byte block
(230h-23Fh) is the CD-ROM interface side — deliberately NOT mapped by the
enabler (sound needs only 220h/16).
COR value 64h (24h | LevlREQ 40h) — bit3 stays clear (bit3 is this card's
CIS-write-enable; never set it outside deliberate CIS repair).
Bring-up verified on this box: DSP reset → AAh, ESS ident E7h → 68 8Bh,
FM present at 388h (AdLib timer test). Warm + cold-boot runs identical.

## Open items

- REX-5572: identity + CFTABLE facts pending physical insertion (add to
  idtable from a CISDUMP on this box when available).
