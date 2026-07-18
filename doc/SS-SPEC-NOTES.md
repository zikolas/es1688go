# PCMCIA Socket Services — INT 1A interface notes (clean spec source)

Source: Ralf Brown's Interrupt List (public interface documentation) — INT 1A
AH=80h..90h entries and tables 00656-00686, as mirrored at ctyme.com (fetched
2026-07-18; archived locally in `doc/rbil/`, not committed). This file + live
probing on the OmniBook 425 are the ONLY host-side sources for this project.
No vendor code was read.

All calls: INT 1A, AH = function, AL = adapter number (except 80h/81h/82h).
Return: CF clear = OK (AH destroyed), CF set = error code in AH (Table 00656).

## Functions

| AH  | Name                | In                                            | Out |
|-----|---------------------|-----------------------------------------------|-----|
| 80h | GetAdapterCount     | —                                             | CX=5353h 'SS', AL=# adapters (0-16) |
| 83h | GetSSInfo (version) | AL=adapter                                    | AX=BCD SS ver, BX=BCD impl ver, CX=5353h, DS:SI→ASCIZ implementor |
| 84h | InquireAdapter      | AL                                            | BH=#windows, BL=#sockets(1-16), CX=#EDCs, DH=caps(T00670), DL=stschg int |
| 85h | GetAdapter          | AL                                            | DH=adapter attrs (T00672) |
| 86h | SetAdapter          | AL, DH=attrs (T00672)                         | — |
| 87h | InquireWindow       | AL, BH=window                                 | BL=caps(T00673), CX=assignable-socket bitmap, DL=speeds(T00674), DS:SI→mem char (T00675), DS:DI→I/O char (T00676) |
| 88h | GetWindow           | AL, BH=window                                 | BL=socket(0=unassigned), CX=size, DH=attrs(T00678), DL=speed, SI=base, DI=card offset |
| 89h | SetWindow           | AL, BH=win, BL=socket, CX=size, DH=attrs(T00678), DL=speed(1 bit), SI=base, DI=card offs | — |
| 8Ah | GetPage             | AL, BH=window                                 | (T00679 attrs, DI=offset) |
| 8Bh | SetPage             | AL, BH=win, BL=page, DX=attrs(T00679), DI=card offset 4K units | — |
| 8Ch | InquireSocket       | AL, BL=socket                                 | DH=caps(T00680), DL=indicators(T00681), DS:SI→socket char (T00682), DS:DI→power mgmt table (T00684) |
| 8Dh | GetSocket           | AL, BL=socket                                 | BH=stschg mask(T00658), CH=Vcc level idx (low nyb), CL=Vpp1(hi)/Vpp2(lo) idx, DH=socket status(T00659), DL=indicators, SI=card type(T00685), DI=IRQ steering(T00686) |
| 8Eh | SetSocket           | AL, BL=socket, BH=stschg mask, CL=Vpp1/Vpp2, [CH=Vcc idx — RBIL omits, symmetric w/ 8Dh, VERIFY BY READBACK], DH=socket status, DL=indicators, SI=card type, DI=IRQ steering | — |
| 8Fh | GetCard (status)    | AL, BL=socket                                 | DL=card status (T00660) |
| 90h | ResetCard           | AL, BL=socket                                 | toggles RESET pin; caller must wait for ready itself |

Units: memory windows = 4K pages (base, size, card offset); I/O windows = bytes.

## Key tables

T00656 errors: 01 BAD_ADAPTER, 02 BAD_ATTRIBUTE, 03 BAD_BASE, 05 BAD_INDICATOR,
06 BAD_IRQ, 07 BAD_OFFSET, 08 BAD_PAGE, 0A BAD_SIZE, 0B BAD_SOCKET, 0D BAD_TYPE,
0E BAD_VCC, 0F BAD_VPP, 10 BAD_WAIT, 11 BAD_WINDOW, 13 NO_ADAPTERS, 14 NO_CARD,
15 unsupported, 16 bad mode, 17 bad speed, 18 busy.

T00658 status-change mask bits: 7=card-detect change, 6=ready change, 5=batt warn,
4=batt dead, 3=insertion req, 2=ejection req.

T00659 socket status bits: 7=card changed, 5=insertion complete, 4=ejection complete,
3=insertion pending, 2=ejection pending, 1=card locked.

T00660 card status bits: 7=card detect, 6=ready, 5=BVD2 warn, 4=BVD1 dead, 0=WP.

T00673 window caps (BL): 0=common mem, 1=attribute mem, 2=I/O space.

T00674 speeds (bitmap): 0=WAIT monitoring, 1=100ns, 2=150ns, 3=200ns, 4=250ns,
5=300ns, 6=600ns.

T00675 mem window characteristics @DS:SI (words): caps(T00677), min base(4K),
max base(4K), min size(4K), max size(4K), size granularity(4K), base align(4K),
card offset align(4K).

T00676 I/O window characteristics @DS:DI (words): caps(T00677), min base(bytes),
max base, min size, max size, size granularity.

T00677 window caps word: 0=prog base, 1=prog size, 2=en/disable, 3=8-bit, 4=16-bit,
5=base align on size boundary, 6=pow2 granularity; mem only: 7=card offs align on
size boundary, 8=paging hw, 9=paging shared, 10=page en/disable.

T00678 window attrs (DH for SetWindow): 0=memory-mapped (vs I/O), 1=attribute mem
(vs common), 2=enabled, 3=16-bit data path, 4=paged (mem only).

T00680 socket caps (DH): 0=card change, 1=card lock, 2=insert motor, 3=eject motor.
T00681 indicators (DL): 0=busy, 1=WP, 2=battery, 3=lock, 4=XIP.
T00682 socket characteristics @DS:SI (words): card types(T00683), steerable IRQ
bitmap (bit0=IRQ0..bit15=IRQ15), extra steerable (bit0=NMI,1=IOCHK,2=buserr,3=vendor).
T00683 card types: bit0=memory, bit1=I/O.
T00684 power table @DS:DI: word N entries (0=no PM); then N × 2 bytes:
byte0 = voltage in 0.1V units, byte1 = supply bits: 7=Vcc, 6=Vpp1, 5=Vpp2.
Vcc/Vpp values in Get/SetSocket are INDICES into this table.
T00685 card type (SI): bit0=memory, bit1=I/O.
T00686 IRQ steering (DI): bit15=enable, bits4-0=IRQ level (0-15=IRQ, 16=NMI...).

## Timing responsibilities (from spec notes)

- ResetCard (90h) toggles RESET but does NOT wait — caller must poll card status
  (8Fh, ready bit) / delay before touching the card.
- After Vcc application, PC Card standard requires waiting for Vcc to stabilize
  (≥ 100 ms conservative) before asserting/deasserting RESET, then waiting for
  READY before any CIS access.
