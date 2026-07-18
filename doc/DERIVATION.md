# ES1688GO (unified) derivation log — clean-room provenance of the merge

(The project was developed under the working name CARDGO — the 2026-07-18
log entries below use it — and renamed ES1688GO at first commit, inheriting
the name of the original PCIC-only C enabler it subsumes.  TSR signature
changed 'CDGO' → 'ESGO' at the rename; stale CARDGO-era and CS1688GO
residents are detected and refused as version mismatches.)

Rule, inherited from all three parent projects: **every fact in the enabler
traces to (a) a published specification/document, (b) a probe transcript
from the target machine, or (c) a card's own CIS read off the hardware.**
No vendor software, vendor ROM, or vendor driver was read, disassembled, or
otherwise consulted at any point — in the parents or in this merge.

## Parent projects (all our own, all clean-room)

| Backend | Parent | Where | Verified on |
|---|---|---|---|
| `/PCIC` | ES1688GO (`ES1688GO.C`) | `~/Projects/rex5571-enabler` | IBM PC110 (82365-class), ThinkPad 235 (CardBus-era bridge) |
| `/CS` | CS1688GO 1.6 (`CS1688GO.ASM`) | `~/Projects/cs1688go` | HP OmniBook 530, SystemSoft OBSS + CS.EXE 2.06 / CS level 2.10, REX-5572 |
| `/OB` | OB1688GO 1.0 (`OB1688GO.ASM`) | `~/Projects/ob1688go` | HP OmniBook 425, KXL-C101 + REX-5572, incl. cold boot |

The PCIC backend is a hand port of the C parent to 8086 assembly (register
values, sequencing and delays preserved; power-good polling kept for the
CardBus-era Vcc ramp). The CS and OB backends are near-verbatim transcriptions
of their parents with shared code factored out. Spec grounding carried over:

1. PCMCIA Socket Services v1.00 INT 1A — RBIL entries for AH=80h..90h,
   distilled in `doc/SS-SPEC-NOTES.md`; OmniBook 425 deviations probed live,
   full transcripts in `doc/RECON-425.md` (both inherited from ob1688go).
2. PCMCIA Card Services 2.1 — function codes and packet layouts from RBIL61
   (INT 1A/AH=AFh); the DOS register binding and callback convention from the
   SystemSoft CardSoft Technical Guide (SWM-640020018 rev A, App. B/D).
3. Intel 82365SL PCIC register set — public ExCA/82365 documentation.
4. PC Card CIS metaformat — tuple codes/layouts (VERS_1 15h, CONFIG 1Ah,
   MANFID 20h; TPCC_SZ/TPCC_RADR; COR at even attribute addresses; COR bits:
   5-0 index, 6 LevlREQ, 7 SRESET) — PC Card standard, public.
5. ES1688 / Sound Blaster / AdLib programming — public references (DSP reset
   handshake, E1h version, SB Pro mixer, ESS ext-mode C6h + mixer reg 40h,
   OPL timer detect, GPO port at base+7).

## Card manifest facts and their sources

| Card | Fact | Source |
|---|---|---|
| REX-5571/5572 | MANFID C015/0001, VERS_1 "CARD 71"/"CARD 72" discriminator | cards' own CISes (PC110 + 425 reads; 5572 CIS archived in `dumps/CIS1-rex5572.bin`) |
| REX-5572 | sound COR index **20h**, pinned — CIS default 22h = SCSI side; 20h appears NOWHERE in its CIS | probe-derived (PC110), re-proven live on the 425 (see ob1688go DERIVATION 2026-07-18) |
| KXL-C101 | MANFID 0032/0204; no MPU (no 330h range in any CFTABLE entry); config regs at attr 400h | its CIS (`dumps/CIS1-kxlc101.bin`, read on the 425) |
| KXL-C101 | **no gameport** (operator-corrected: the old ES1688GO manifest's no_joy=0 was wrong) | ob1688go correction 2026-07-18; carried into this merge |
| KXL-C101 | OB-mode index **24h** (self-decoded fixed 220h — independent of the OB's small fixed windows); 20h relocatable used in PCIC/CS modes; COR bit3 = CIS-write-enable, both 24h|40h and 20h|40h keep it clear | 425 probe + C101 CIS-repair project fact |
| Eiger EPX-AA2000 | MANFID 0004/2000, VERS "EPX-AA2000"; COR base 3F0h read from its CIS at runtime; no MPU, no gameport | its CIS (PC110 era) |
| IBM Portable CD-ROM | MANFID 00A4/002D "CD-ROM"; COR index 01h; GPO0 (base+7 <- 01h) gates the box amp; MPU aliases onto IDE/SB (A8 not decoded); 201h lands on its FM DATA register so no gameport | its CIS + PC110/235 probing (cd20x-enabler project) |

## Merge decisions (deltas vs the parents)

* **One switch surface.** `/T`≡`/TONE`, `/F`≡`/FORCE`, `/G`≡`/GPO=`, `:`/`=`
  both accepted. `/I` is **decimal in every mode** (OB 1.0 parsed hex — its
  documented `/I:A` is now `/I=10`). `/S` gains CS-mode meaning (pin the
  probe + hot-plug to one socket). `/C` force-index default is now **20h in
  all modes** (OB 1.0 defaulted to 1).
* **Per-mode feature defaults preserved** from each verified parent (PCIC:
  FM+MPU unless add-ons are named; CS: FM, `/MPU` opts in; OB: everything the
  card supports, degrade politely). `/NOMPU` added as the uniform opt-out.
* **Chip bring-up unified as the superset**: the SB Pro mixer unmute
  (22h/26h/04h <- DDh) and the OPL timer detect from OB1688GO now run in all
  modes (chip-level, host-independent); the MPU probe is OB1688GO's DRR-aware
  version; the test tone is CS1688GO's self-terminating one (release rate 0 =
  infinite sustain — a bare key-off drones forever; learned the loud way).
  The PCIC parent's endless `/TONE` (for cross-run GPO hunting) is gone: a
  1 s tone per run answers the same question.
* **COR level bit per parent behavior**: PCIC writes the plain index (as the
  C parent always did), CS and OB set LevlREQ (bit 6), OB's `/P` selects
  pulse. KXL-C101 keeps the per-mode index split (20h PCIC/CS, 24h OB) via a
  second index byte in each manifest record.
* **CS result/identity block widened** so a handoff run can print the full
  ES1688GO-style summary (VERS string, COR base/index travel back from the
  resident copy). Signature block is now `CDGO`/0100h; a resident legacy
  `CS68` (CS1688GO) is detected and reported instead of being fought with.
* **CS-mode output format** is now the shared ES1688GO summary block
  (CS1688GO 1.6 had its own layout).
* **PCIC `/W` window hunt, socket-restore politeness, and the 3E0h/COM1
  range guards** carried over unchanged (PC110 lesson: a window over
  3F8h/3E0h kills the machine's serial link — never map one there).

## Facts pending on-box verification (this binary)

| Item | Plan |
|---|---|
| PCIC regression (PC110: KXL-C101, REX-5572 via `/FORCE /S`) | run CARDGO /PCIC, compare against ES1688GO.EXE output + audible check |
| CS regression (OB530: REX-5572; hot-plug, handoff, `/OFF`, legacy-TSR detect) | run CARDGO /CS with CS1688GO's test list |
| OB regression (OB425: C101 + 5572; polite-window matrix 1-4) | re-run the ob1688go 0.5 window test matrix |
| `/S` pinning in CS mode (new behavior) | pin to wrong socket, verify refusal; pin to right one, verify enable |
| Unified decimal `/I` in OB mode | `/I=10` steers IRQ 10 (was `/I:A`) |

## Validation log

- 2026-07-18 merged from the three parents; assembles with NASM 3.02
  (11,240 bytes; resident image 0ADh paragraphs ~ 2.7 KB); sig block
  verified at PSP:103h (`E9 xx xx 'CDGO' 00 01`).
- 2026-07-18 **CS backend verified on the OmniBook 530** (CARDGO 1.0,
  REX-5572, SystemSoft stack, operator at the machine): auto-detect picked
  CS; enable good; `/T` tone audible; `/MPU` handoff to the resident copy
  reconfigured live; plain re-run flipped back; `/OFF` released (port 220h
  reads 00 after); hot-plug reinsert reconfigured. **SB direct DAC + FM +
  MPU all working** (Monkey-class MIDI out confirmed by ear). FM showed no
  `(?)` — the OPL timer detect passes through the CS path.
- 2026-07-18 530 finding: `MPU 330(?)` false negative — the merged
  (OB-style) probe gates the FFh UART reset on DRR, and on the 530 the
  ES1688's MPU status never shows DRR ready before the first command, so
  the probe timed out without transmitting while the UART itself worked.
  CS1688GO 1.6's blind write had proven FEh ACK on this machine. **Fix in
  1.1**: DRR wait falls through to a blind send on timeout (superset of
  both proven behaviors). Re-verify pending.
- 2026-07-18 CARDGO 1.1: MPU probe fix above; test tone changed to the
  OB1688GO "ding" (silent modulator, carrier attack F / decay 5 / sustain
  7 / release 7 — nonzero release lets a bare key-off ring out; the old
  sustained-organ patch is gone). Resident-protocol version bumped to
  0101h via the new CGVER equ — the handoff copies blocks by offset, so
  every release must bump it; a mismatched resident is refused.
- 2026-07-18 530 retest of 1.1: ding good; `MPU 330(?)` persisted — the
  blind-send fix was not it.  Live diagnosis over COMrade (probes/MPUTEST):
  manual port pokes see a textbook FEh ACK (status 80h → FFh → status 00h →
  data FEh) and mixer 40h reads exactly the DAh CARDGO wrote (IRQ 7 + port
  330 + OPL on), so hardware, routing, and grant were all correct.  MPUTEST
  replicating CARDGO's full chip tail at CPU speed (DSP reset AAh, E1,
  unmute, C6h, 40h rewrite, immediate probe) ACKs instantly in steady
  state — zero status polls.  TESTMPU.BAT (CARDGO /MPU then MPUTEST
  back-to-back): CARDGO's in-reconfigure probe fails, MPUTEST ~200 ms
  later ACKs the first FFh instantly.  Conclusion: after the CS
  Release/RequestConfiguration + mixer-40h routing change, the ES1688's
  MPU engine needs a settle (tens-to-hundreds of ms) before it answers;
  the 1.0/1.1 probe budget (~40 ms) was too short.  **Fix in 1.2**:
  mpu_probe retries the FFh reset up to five times ~60 ms apart (~500 ms
  worst case on a truly silent port; success stays instant).  CGVER 0102h.
- 2026-07-18 530 retest of 1.2 after reboot: **still `330(?)`** — the retry
  ladder did not help.  probes/MPUTST2 lab results overturned both timing
  theories: calibration says IN AL,80h = 2.4 us on this box (58C8h reads
  per tick), so the 1.2 ladder actually spanned ~1 s and still failed; and
  the mixer-40h routing flip (03h → DAh, the failing transition) followed
  by an immediate FFh ACKs **instantly** — routing change needs no settle
  at all.  Conclusion: elapsed time is not the variable; something about
  the in-configure state is (prime suspect: the freshly-granted range-2
  I/O window at 330h not passing cycles yet — FFh status reads would also
  explain 1.0's DRR timeout).  **1.3** instruments instead of guessing:
  the probe records the raw status byte at entry (S0) and after the last
  retry (SL) and prints them in the failure note (FF = window dead, 80 =
  alive but command vanished, C0 = DRR stuck), and CS mode re-verifies the
  MPU once more at report time after ~330 ms of silence — the exact
  condition MPUTEST wins at — updating the summary if it ACKs.  CGVER
  0103h.
- 2026-07-18 1.3 diag run + follow-ups: `[S0=80 SL=80]` — the 330h window
  passes cycles (this machine's open bus reads 00h, so 80h is the real MPU
  status), DRR reads ready, the FFh vanishes.  1.3b lab build (transient-
  only change, same CGVER — a deliberate loophole in the version guard
  that allows no-reboot iteration when the resident image is byte-
  identical): INT 28h idle-pumped late re-probe, 30 rounds ~2 s — still no
  ACK in-process.  Every timing/ordering theory eliminated; discriminator
  is literally "the process that called RequestConfiguration" vs any
  other process.  **Bug logged and parked** (operator call): reverted to
  the 1.0 probe (single DRR-gated attempt), kept the ding tone; shipped as
  **1.1 final, CGVER 0104h**.  The `(?)` on the 530/CS path is documented
  as a cosmetic known issue in README; MPUTEST/MPUTST2 remain in probes/
  for whoever picks the mystery up again (candidate suspects for that
  day: SystemSoft CS/CARDID/CS_APM deferred completion, OBMGM/OBSS SMI
  interaction, VL82C717 write posting).
- 2026-07-18 **OmniBook 425**: the `(?)` reproduced on the OB backend too —
  and OB1688GO 1.0, run back-to-back on the same boot/card, showed a clean
  `MPU 330`.  First controlled A/B: the bug follows CARDGO, not the host.
  Manual pokes: mixer 40h = BBh exactly as written (routing perfect), FFh →
  FEh instant.  A lab-build series (CARDGOL L1-L8) chased phantom patterns
  (DRR gate, DOS-call pumping, code position, addressing mode, timing
  windows) — each theory died within a run because, as it turned out, the
  observable depended on whether the *reading* code discarded its answer.
- 2026-07-18 **PC110**: reproduced there too — `ES1688GO.EXE` (C parent)
  clean, CARDGO `(?)`, same boot, no HP BIOS/CS in the path.  Endgame
  method: put a known-passing probe next to the failing one in ONE binary
  (both disagree in the same run), then morph the passing routine toward
  the failing one an instruction at a time (M1-M3).  The flip never came —
  because the morphs converged on identical send/poll code and still
  disagreed, which finally forced a byte-level read of the one remaining
  difference: **the `.rd` verdict tail**.
- 2026-07-18 **ROOT CAUSE (fixed in 1.2, CGVER 0105h)**: in the port of
  OB1688GO's mpu_probe, the DX reload between `cmp al,0FEh` and `jne` was
  written as `mov dx,[o_mpu]` + **`inc dx` — INC rewrites ZF**, so the
  branch tested INC's result (always nonzero → always "not FE").  The
  probe received the FEh ACK on every machine every time, READ it
  (consuming it from the FIFO), discarded the verdict, and timed out
  polling the now-empty port — which also manufactured every downstream
  illusion (SL=80h, watch-only silence, "any second prober succeeds",
  "process identity").  OB1688GO used flag-preserving `mov dx,imm`
  reloads; ES1688GO-C used structured C; MPUTEST/MPUTST2 accidentally
  copied the OB shape — so every reference implementation was immune and
  the shipped probe alone was blind.  Fix: branch (`je .got`) immediately
  after the compare, before touching DX.  **Verified on the PC110: clean
  `MPU 330`, side-by-side identical with the C parent's output.**
  Lessons recorded: (1) when porting immediates to variables, an innocent
  `inc`/`add` between a compare and its branch is a loaded gun — keep
  conditional jumps adjacent to their compares; (2) a diagnostic that
  "proves the hardware fine" while the program disagrees means the
  *verdict path*, not the stimulus, deserves the microscope; (3) the
  passing-vs-failing morph bisect converges when theorizing does not.
- 2026-07-18 1.2 re-verify pending on the OB425 (OB backend) and OB530
  (CS backend, needs its usual reboot to swap the resident copy).
- 2026-07-18 **IBM Play At Will CS on the PC110** (DOS Card Services
  Driver 2.22, CS Release 2.10 — third CS implementation): auto-detect
  prefers the CS arbiter over the raw 82365 beneath it (correct);
  REGISTRATION_COMPLETE is not delivered by this stack either, the active
  socket probe carries it; RequestConfiguration accepted without the
  SystemSoft ArgLength dance being visible.  `/MPU`: the 330-389 span IS
  granted (the 530's refusal is SystemSoft resource-map policy, not a CS
  limitation).  **1.3 (CGVER 0106h)**: /JOY in CS mode folds the gameport
  into range 1 by stretching it to 200h-22Fh (the PCIC win0 trick;
  refused stretches replan automatically to the plain SB block) - IBM
  grants it: full house `SB 220 FM 388 MPU 330 JOY 201 IRQ 5`, clean MPU
  ACK, on the PC110 through Card Services.  Neither parent could produce
  this combination through a CS stack.
- 2026-07-18 **OmniBook 530 closure** (1.3): empty-socket scan reports
  cleanly and arms the resident; real hot-plug insert configured the
  REX-5572; `/MPU` handoff shows **`SB 220 MPU 330 IRQ 7` — clean, no
  `(?)`** on the machine where the ghost hunt began (the flag-clobber fix
  closing the loop).  FM correctly falls back to SB-base per SystemSoft's
  span refusal.  Lab debris swept from the box.
- 2026-07-18 **OmniBook 425 closure** (1.3, pushed over a moody serial
  link via chunked base64 appends, CRC-verified; CARDGO-era files swept):
  **REX-5571** — the card whose lost driver started this project family —
  first-ever exercise of its manifest entry: VERS_1 "CARD 71" match,
  full house `SB 220 FM 388 MPU 330 JOY 201 IRQ 5`, windows 4-7, clean
  MPU ACK.  All three machines now run 1.3.
- 2026-07-18 **Game verification, OB425 + REX-5571 (1.3)**: Monkey Island
  with Roland MIDI (MPU-401 UART out to the CM-32L) and with AdLib FM;
  Another World on SB direct-DAC.  All working by ear - MPU, FM and DSP
  paths proven end-to-end under real games, not just probes.
- 2026-07-18 **Toshiba T2130CT (ToPIC)**: the ToPIC controller answers the
  82365 ID probe and the whole PCIC backend passes first try - scan,
  power-good poll, D000 attr window, CIS/manifest (REX-5571), COR, both
  I/O windows, DSP v3.01, clean MPU ACK.  Fourth machine, fifth host
  flavor (true 82365, ToPIC-as-ExCA, SystemSoft CS, IBM CS, HP SS), all
  via auto-detect.  (IRQ delivery still unproven end-to-end anywhere -
  nothing we run uses it.)
- 2026-07-18 T2130CT field notes (both benign, neither enabler-related):
  (1) transient LEFT-ONLY audio on FM + DAC with the 5571, cleared by
  reseating and absent on the 5572 and the reseated 5571 - contact/seating
  class (a marginal ground pin through the socket can break one channel's
  analog return); first-check for any one-sided PCMCIA sound card.
  (2) Monkey Island 1 garbled CM-32L instruments on the DX4 while Monkey
  Island 2 is perfect - MI1's 1990 Roland driver paces its SysEx patch
  upload with CPU-bound delay loops (the classic MT-32-family fast-machine
  overflow); MI2's iMUSE paces correctly.  Same card/module/enabler both
  ways: the MIDI path is exonerated.  **Confirmed same night: CPU speed =
  Low fixes MI1's CM-32L output on the T2130CT.**
- 2026-07-18 **Phoenix CS stack on the T2130CT** (Toshiba-bundled Phoenix
  SS/CS): CS backend passes, operator-verified - the FOURTH Card Services
  implementation (SystemSoft, IBM Play At Will, Phoenix) and sixth host
  flavor overall (those three CS stacks + HP SS + true 82365 + ToPIC
  direct), all via auto-detect, one binary, no switches.
- 2026-07-18 DOSBox-X smoke tests (no PCMCIA hardware — plumbing only):
  auto-detect prints the no-host message and survives DOSBox's INT 1A
  oddities (AH=AFh undefined; AH=80h is a Tandy call there — the zeroed-CX
  'SS' signature check rejects it correctly); `/PCIC` `/CS` `/OB` forced
  modes fail with the right per-backend messages; `/PCIC /S=2` addresses
  port 3E2 (chip/bank math); `/FORCE` without `/S` refused; `/MPU=331`
  refused; unknown switches echoed and ignored; `/PCIC /OFF` handles a
  missing controller cleanly. PASS.
