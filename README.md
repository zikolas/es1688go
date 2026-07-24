# ES1688GO

**One DOS enabler for ES1688 PCMCIA sound cards — three host backends, one
8086 `.COM`.**

ES1688GO merges our three sibling enablers into a single binary:

| Mode | Host path | Lineage | Proven on |
|---|---|---|---|
| `/PCIC` | Intel 82365-class controller, programmed directly | the original ES1688GO (C) | IBM PC110, ThinkPad 235 |
| `/CS` | PCMCIA Card Services 2.1 client, stays TSR | CS1688GO | HP OmniBook 530 (SystemSoft stack) |
| `/OB` | Socket Services v1.00 direct, polite window allocator | OB1688GO | HP OmniBook 425 (300/430 same architecture) |

With no mode switch the host is auto-detected: **Card Services first** (when
an arbiter is loaded we must go through it), then the `'SS'` Socket Services
signature, then an 82365 probe at `3E0h`.

> **Status: freshly merged, not yet re-verified on hardware.** The code is a
> faithful port/merge of the three parents (each verified on its machine),
> assembles byte-stable, and passes emulator smoke tests of every non-hardware
> path — but no card has been enabled by *this* binary yet. Treat it as a
> release candidate until the on-box matrix below is run.

## Supported cards

Cards are identified by `CISTPL_MANFID`, plus a `CISTPL_VERS_1` substring
where models share an ID (the two RATOCs do). COR config indices are
**curated per card, never read from the CIS** — the REX-5572's CIS default
entry (22h) selects its SCSI side, and its sound index 20h appears nowhere
in its CIS at all (probe-derived fact, verified live on two machines).

| Card | MANFID | SB | FM 388 | MPU-401 | Gameport | Notes |
|---|---|---|---|---|---|---|
| RATOC REX-5572 | C015/0001 "CARD 72" | ✅ | ✅ | ✅ | ✅ | sound+SCSI combo; index 20h pinned |
| RATOC REX-5571 | C015/0001 "CARD 71" | ✅ | ✅ | ✅ | ✅ | |
| Panasonic/KME KXL-C101 | 0032/0204 | ✅ | ✅ | ❌ | ❌ | a.k.a. KXL-D20/D745; OB-mode index 24h (self-decode, on-box verified) |
| Eiger Labs EPX-AA2000 | 0004/2000 | ✅ | ✅ | ❌ | ❌ | COR base 3F0h (read from its CIS) |
| IBM Portable CD-ROM | 00A4/002D | ✅ | ✅ | ❌ | ❌ | GPO0 amp gate; MPU aliases; 201h lands on its FM data reg — use CD20XGO for the CD side |

Unknown ES1688 cards: `/FORCE /S=n [/C=index]`. Adding a card to the
manifest is one 12-byte table entry.

## Usage

```
ES1688GO [/PCIC|/CS|/OB] [/SB=220] [/FM=388] [/NOFM] [/MPU[=330]] [/NOMPU]
       [/JOY] [/I=5] [/S=n] [/W=D000] [/C=20] [/G=nn] [/TONE] [/P]
       [/FORCE] [/OFF]
```

| Switch | Meaning |
|---|---|
| `/PCIC` `/CS` `/OB` | force the host backend (default: auto-detect) |
| `/SB=hex` | SB base, always enabled (default 220) |
| `/FM=hex` | dedicated AdLib/ESFM port (default 388); `/NOFM` skips it (SB-base FM still works) |
| `/MPU[=hex]` | MPU-401 UART port (300/310/320/330; default 330); `/NOMPU` never claims it |
| `/JOY` | gameport at 201 — PCIC/CS: folded into the SB range (200h–22Fh as one range); OB: own window |
| `/I=dec` | IRQ (default 5; MPU routing needs 5/7/9/10). Decimal everywhere — OB users note: what was `/I:A` is now `/I=10` |
| `/S=dec` | socket: PCIC 0–7, OB 1–4, CS restricts the probe (and hot-plug) to that socket |
| `/W=hex` | attribute-window segment for the CIS/COR access (PCIC mode; default D000, auto-relocated if another card has a memory window there) |
| `/C=hex` | config index for `/FORCE` (default 20) |
| `/G=hex` | write this byte to the ES1688 GPO port (base+7) — amp-gate probing for combo cards; overrides the manifest value |
| `/TONE` | ~1 s OPL test tone after enabling (self-terminating) |
| `/P` | pulse-mode IREQ (OB mode; default level, COR bit 6) |
| `/FORCE` | configure without the CIS identity check (needs `/S`) |
| `/OFF` | PCIC: power the socket down; CS: release resources, resident copy goes dormant |

`:` and `=` both work as value separators. Afterwards:
`SET BLASTER=A220 I5 T3` (match the IRQ the summary reports — on the
OmniBook 530 that is I7). PCMCIA has no DMA: FM/AdLib and apps with PIO/IRQ
paths work; DMA-only digitized sound does not.

### Per-mode feature defaults (preserved from each verified parent)

* **PCIC** — with none of `/FM` `/MPU` `/JOY` named: FM + MPU. Naming any
  gives exactly the named set.
* **CS** — SB + FM; `/MPU` opts in, `/JOY` folds the gameport into range 1
  (stretched down to 200h — SB + gameport as one resource, leaving range 2
  for the MPU..FM span: all four features inside Card Services' two I/O
  ranges). Whether the span and the stretch are granted is up to the
  stack's resource map: IBM's Play At Will on the PC110 grants both (full
  house verified); SystemSoft on the OmniBook 530 refuses the span (its
  pool reserves 370–377 for secondary ATA and 378–37F for LPT1), so `/MPU`
  falls back to MPU-only there — FM still works at the SB base. Refused
  stretches degrade automatically to the plain SB block.
* **OB** — everything the card supports, degrading politely when the four
  16-byte I/O windows run out (priority SB > FM > MPU > JOY), refusing
  cleanly if an occupied window overlaps a needed range.

MPU is auto-dropped (with a note) on cards flagged as having none.

### CS mode is a TSR

Run it with the card inserted, or beforehand — it stays resident and
configures the card on insertion (hot-plug via the CS event callback;
removal releases the resources). **Re-running switches the live
configuration**: a later run finds the resident copy (MCB scan for the
`ESGO` signature at PSP:103h), hands it the new switches, and far-calls its
control entry so the owning client swaps its own CS resources. `ES1688GO /MPU`
flips a running AdLib setup to MIDI on the spot; `/OFF` releases everything
and goes dormant. TSR copies never stack, and a resident legacy CS1688GO is
detected and reported (reboot to replace it).

## How each backend works

* **PCIC** — scans up to four 82365-class chips (3E0/3E2/3E4/3E6, two
  sockets each), powers the socket (polling power-good: CardBus-era bridges
  like the ThinkPad 235 ramp Vcc slowly), maps a 16 KB attribute window on a
  segment **no other card has a memory window over**, reads the CIS, writes
  the COR, then programs the two I/O windows — win0 = SB block (stretched
  down to 201h for `/JOY`), win1 = the FM/MPU span above the base.
* **CS** — RegisterClient → active socket probe (SystemSoft CS generates
  **no** artificial CARD_INSERTION events — waiting on the callback, the
  spec-blessed flow, silently does nothing) → RequestIO / RequestIRQ ladder
  / RequestConfiguration (walking ArgLengths until the stack stops saying
  1Bh — SystemSoft rejects the documented size) → chip bring-up → TSR.
* **OB** — Socket Services in the OmniBook 300/425/430 ROM, with the probed
  quirks honoured: **1-based** Vcc/Vpp power-table indices, SetWindow DH
  bit 0 **inverted** from the common documentation (memory windows want it
  clear, I/O windows set), card-status RDY/WP bits that float (a socket is
  "the OS's drive" iff an enabled common-memory window maps it). Four
  16-byte I/O windows are surveyed and allocated politely: free = disabled ∨
  ours ∨ enabled-but-cardless; an enabled window serving another socket's
  card is respected.

Shared across all three: the card manifest, CIS parsing, and the ES1688
bring-up — DSP reset (AAh handshake), DSP version, SB Pro mixer unmute,
extended-mode mixer reg 40h (OPL enable, legacy 388h/gameport decode, MPU
port + IRQ routing), MPU FEh ACK probe, per-card amp-GPO gate, OPL timer
detect, and the self-terminating test tone.

## Building

```
./build.sh        # host: NASM, flat -f bin
nasm -f bin ES1688GO.ASM -o ES1688GO.COM  # or by hand / on-box
```

Everything is 8086-clean. `probes/` carries the recon tools the parent
projects were built with: `SSCALL` (raw INT 1A register caller), `CISDUMP`
(power a socket + archive its CIS), `CSINFO` (Card Services
signature/socket-count probe), and `MPUTEST` (ES1688 MPU ACK
timing diagnostic — born of the great `MPU 330(?)` hunt).
`dumps/` holds the reference CIS archives for the KXL-C101 and REX-5572.

## Verification status

- [x] Assembles (NASM 3.x, byte-stable), resident image ~2.7 KB
- [x] Emulator smoke tests: auto-detect fallthrough, all three forced-mode
      failure paths, switch parsing/validation, `/OFF` handling
- [x] **CS regression on the OmniBook 530** (2026-07-18, REX-5572, v1.0–1.3):
      SB direct-DAC + FM + MPU all working; auto-detect, `/T` (ding), `/MPU`
      live handoff, `/OFF`, hot-plug (incl. arming on an empty scan and
      configuring a later real insert) all pass; 1.3 shows the clean
      `MPU 330` that closes the probe-bug saga below.
- [x] **PCIC regression on the PC110** (2026-07-18, REX-5572, v1.2): full
      summary incl. **clean `MPU 330`**, tone audible; side-by-side match
      with the parent `ES1688GO.EXE` output.
- [x] **PCIC on a Toshiba ToPIC, T2130CT** (2026-07-18, REX-5571, v1.3):
      the ToPIC answers the 82365 probe and the full PCIC path passes
      first try — clean MPU, both windows, auto-detected.
- [x] **CS on the Toshiba/Phoenix stack, T2130CT** (2026-07-18, v1.3):
      fourth Card Services implementation verified.
- [x] **CS on IBM Play At Will, PC110** (2026-07-18, REX-5572, v1.2/1.3):
      third Card Services implementation verified (DOS CS driver 2.22, CS
      2.10). Auto-detect correctly prefers the CS arbiter over the raw
      PCIC beneath it; this stack also delivers no REGISTRATION_COMPLETE
      (the active probe carries it); `/MPU` gets the 330–389 span and
      `/MPU /JOY` the **full house** — `SB 220 FM 388 MPU 330 JOY 201`.
- [x] **OB regression on the OmniBook 425** (2026-07-18, v1.1–1.3):
      REX-5572 full enable/windows/FM on 1.1; 1.3 closure with the
      **REX-5571** (first exercise of its manifest entry, "CARD 71"
      VERS_1 match): full house SB/FM/MPU/JOY, clean MPU — then proven
      under real games: Monkey Island via Roland MIDI (CM-32L) and AdLib,
      Another World on SB direct-DAC. KXL-C101 + polite-window matrix
      re-run still to do.

## Provenance

Built entirely clean-room, merging three clean-room parents. Sources: each
card's own CIS (read off the hardware); the public Intel 82365SL register
set; the PCMCIA CS/SS interfaces as publicly documented (RBIL61) plus the
SystemSoft CardSoft Technical Guide's API binding; OmniBook 425 behavior
probed live; public ESS AudioDrive / Sound Blaster / AdLib documentation.
No HP, RATOC, Panasonic, Eiger, IBM or other vendor driver was read or
disassembled at any point. `doc/DERIVATION.md` traces the merge and every
per-card fact to its source project; `doc/RECON-425.md` and
`doc/SS-SPEC-NOTES.md` carry the OmniBook host recon.

## Credits

- **[COMrade](https://github.com/yyzkevin/COMrade)** by **yyzkevin** — the
  serial/MCP bridge that made remote, real-hardware development of the
  parent projects possible.
- **[The PCMCIA Sound Card Spreadsheet](https://docs.google.com/spreadsheets/d/181yznQ-DEMQRVl0X3s09NH7WD87eM3ui16isHKjIz5c)**
  maintained by **Bondi**.

## License

Copyright (c) 2026 zikolas. MIT — see [LICENSE](LICENSE).

## Disclaimer

A hobby project, shared in the spirit of retro tinkering. It pokes PCMCIA
controller and sound-chip registers directly on 30-year-old hardware.
Provided as-is, no guarantees, no warranty, no responsibility for any
damage — to hardware, data, software, or sanity. You run it entirely at
your own risk.
