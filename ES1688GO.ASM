;==========================================================================
;  ES1688GO 1.2 - unified clean-room DOS enabler for ES1688-based PCMCIA
;               (developed as CARDGO 1.0-1.2; renamed at first commit -
;               the name is inherited from the original PCIC-only C
;               enabler this project subsumes)
;               sound cards, with three host backends in one .COM:
;
;    /PCIC  Intel 82365-class point enabler (direct PCIC programming).
;           Lineage: our ES1688GO (C, PC110 / ThinkPad 235), ported to asm.
;    /CS    PCMCIA Card Services 2.1 client, stays TSR (hot-plug, live
;           reconfigure via resident handoff).  Lineage: our CS1688GO
;           (OmniBook 530, SystemSoft CardSoft stack).
;    /OB    HP OmniBook 300/425/430 Socket Services v1.00 direct, with the
;           polite 4-window I/O allocator.  Lineage: our OB1688GO.
;
;  With no mode switch the host is auto-detected: Card Services first (if a
;  CS arbiter is loaded we must go through it), then the 'SS' Socket
;  Services signature (OmniBook ROM), then an 82365 probe at 3E0h.
;
;  Card manifest (shared by all backends; identified by CISTPL_MANFID plus
;  a CISTPL_VERS_1 substring where models share an ID):
;    RATOC REX-5571 / REX-5572   sound (+SCSI on the 5572; its CIS default
;                                index 22h selects the SCSI side - the sound
;                                index 20h appears NOWHERE in its CIS and is
;                                a curated, probe-derived fact)
;    Panasonic/KME KXL-C101      no MPU, no gameport; OB-mode index 24h
;                                (self-decode, on-box verified on the 425)
;    Eiger Labs EPX-AA2000       no MPU, no gameport; COR base from its CIS
;    IBM Portable CD-ROM         ES1688 combo; GPO0 amp gate; MPU aliases;
;                                gameport not at 201h (use CD20XGO for CD)
;
;  Usage:
;    ES1688GO [/PCIC|/CS|/OB] [/SB=220] [/FM=388] [/NOFM] [/MPU[=330]]
;           [/NOMPU] [/JOY] [/I=5] [/S=n] [/W=D000] [/C=20] [/G=nn]
;           [/T[ONE]] [/P] [/F[ORCE]] [/OFF]
;
;    /SB=hex   SB base (always enabled; default 220)
;    /FM=hex   dedicated AdLib/ESFM FM port (default 388)
;    /NOFM     don't claim the dedicated FM port (SB-base FM still works)
;    /MPU[=hex] MPU-401 UART port (300/310/320/330; default 330)
;    /NOMPU    never claim the MPU port
;    /JOY      gameport at 201 (PCIC: folded into the SB window; OB: own
;              window; not possible through CS - only two I/O ranges)
;    /I=dec    IRQ (default 5; MPU routing needs 5/7/9/10)
;    /S=dec    socket (PCIC 0-7, OB 1-4, CS: probe only this socket)
;    /W=hex    attr-window segment for the CIS/COR access (PCIC; def D000)
;    /C=hex    config index for /FORCE (default 20)
;    /G=hex    write this byte to the ES1688 GPO port (base+7): amp-gate
;              probing for combo cards; overrides the manifest value
;    /TONE     play a ~1 s OPL test tone after enabling (self-terminating)
;    /P        pulse-mode IREQ (OB mode; default level, COR bit6)
;    /FORCE    configure without the CIS identity check (needs /S)
;    /OFF      PCIC: power the socket down; CS: release + go dormant
;
;  Per-mode feature defaults (each preserved from its verified parent):
;    PCIC: with none of /FM /MPU /JOY named -> FM + MPU; naming any gives
;          exactly the named set.  /NOFM //NOMPU then subtract.
;    CS:   SB + FM; /MPU opts in (span MPU..FM tried first, MPU-only
;          fallback on hosts whose I/O pool has holes - OmniBook 530).
;    OB:   everything the card supports, degrading politely when the four
;          16-byte I/O windows run out (priority SB > FM > MPU > JOY).
;
;  Build (host or on-box):  nasm -f bin ES1688GO.ASM -o ES1688GO.COM
;
;  (C) 2026 zikolas, MIT.  Clean-room provenance (doc/DERIVATION.md):
;  each card's own CIS, the public Intel 82365SL register set, the PCMCIA
;  CS/SS specs via RBIL61 + the SystemSoft CardSoft technical guide (API
;  binding), OmniBook 425 behavior probed live (doc/RECON-425.md via the
;  ob1688go project), and the public ESS ES1688 / Sound Blaster / AdLib
;  register models.  No vendor driver was read or disassembled.
;==========================================================================
        cpu  8086
        org  100h

; ---- feature flags (manifest + runtime) ----------------------------------
F_MPU   equ 01h                       ; card has a usable MPU-401
F_JOY   equ 02h                       ; card decodes a gameport at 201h

M_FM    equ 01h                       ; what actually got mapped this run
M_MPU   equ 02h
M_JOY   equ 04h

MODE_CS   equ 1
MODE_OB   equ 2
MODE_PCIC equ 3

; Resident-handoff protocol version.  The handoff copies the option/result
; blocks BY OFFSET between two runs of the same binary, so bump this on
; EVERY release - offsets shift with any rebuild, and a mismatched resident
; copy must be refused (reboot to replace), never driven.
CGVER     equ 0105h

TDMAX   equ 40h                       ; CS tuple-data buffer size
VBMAX   equ 40h                       ; VERS_1 capture buffer size
CISLEN  equ 256                       ; dense CIS bytes pulled per probe

PCIC_BASE equ 3E0h

; OB (OmniBook 300/425/430) probed constants - see doc/RECON-425.md
OB_WIN_ATTR equ 0Eh                   ; mem window attrs (DH bit0 INVERTED here)
OB_WIN_IO   equ 05h                   ; I/O window attrs
OB_SPEED    equ 20h                   ; 300 ns
OB_ATTRSEG  equ 0D000h                ; window 0 host base (probed idle/free)

start:  jmp  init                     ; 3 bytes: sig block lands at 103h

;==========================================================================
;  RESIDENT DATA  (kept when /CS mode goes TSR)
;==========================================================================
; Control-channel signature at fixed offset 103h: a later run finds the
; resident copy by scanning MCBs for this, copies fresh options in, and
; far-calls sigentry so the RESIDENT client swaps its own CS resources.
sig      db 'ESGO'                    ; @103 (CARDGO builds used 'CDGO')
sigver   dw CGVER                     ; @107 must match exactly for a handoff
sigentry dw cs_reconfig               ; @109

handle   dw 0                         ; CS client handle
live     db 0                         ; 0 = queue events, 1 = act on them
inbusy   db 0                         ; re-entrancy guard
regdone  db 0                         ; saw REGISTRATION_COMPLETE
cfged    db 0                         ; card is configured
oursock  dw 0FFFFh
n_sock   db 2                         ; CS socket count

; ---- option block (contiguous: a CS handoff copies o_sb..O_LEN in one
;      sweep; en_* are derived per mode BEFORE install/handoff) -----------
o_sb     dw 0220h
o_fm     dw 0388h
o_mpu    dw 0330h
o_irq    db 5
o_sock   db 0FFh                      ; FFh = auto
o_cfg    db 20h                       ; /C force config index
o_gpoval db 0
o_gpoov  db 0                         ; /G given
o_tone   db 0
o_force  db 0
o_pulse  db 0
o_off    db 0
en_fm    db 0                         ; effective feature plan (per mode)
en_mpu   db 0
en_joy   db 0
O_LEN    equ $-o_sb

; ---- identity / result block (contiguous: handoff copies R_LEN back) ----
arg_sock dw 0                         ; input to cs_configure
r_stage  db 0                         ; 0=ok 2=io 4=cfg 5=dsp 6=wrongcard 7=nocard
r_code   dw 0                         ; CS status of the failing call
manfid   dw 0                         ; CISTPL_MANFID: TPLMID_MANF
         dw 0                         ;                TPLMID_CARD
r_vmaj   db 0                         ; DSP version
r_vmin   db 0
r_irq    db 0FFh                      ; CS granted IRQ (FFh = none)
r_fm     db 0                         ; CS: FM window granted
r_mpu    db 0                         ; CS: MPU window granted
r_mpuok  db 0                         ; MPU FEh ACK seen
r_fmok   db 0                         ; OPL timer detect passed
r_ir1    dw 0                         ; CS IRQ ladder step-1 refusal status
r_ir2    dw 0                         ; CS IRQ ladder step-2 refusal status
r_nompu  db 0                         ; 1 = MPU dropped: card has no usable MPU
matched  db 0                         ; 1 = manifest hit (0 = forced/unknown)
k_name   dw n_unk                     ; matched card's name
k_cor    db 20h                       ; COR config index (relocatable)
k_ob     db 20h                       ; COR index for OB mode (C101: 24h)
k_flags  db 0                         ; F_MPU / F_JOY
k_gpo    db 0FFh                      ; amp-enable GPO byte (FFh = none)
cfgbase  dw 0400h                     ; COR base from CISTPL_CONFIG
mapflags db 0                         ; M_FM/M_MPU/M_JOY mapped this run
essirq   db 0                         ; ES1688 reg40 MPU IRQ code (0 = none)
verslen  dw 0                         ; VERS_1 strings length in versbuf
versbuf  times VBMAX db 0             ; VERS_1 strings (0-separated)
R_LEN    equ $-arg_sock

em_mpu   db 0                         ; CS: effective MPU request this card

qcnt     db 0                         ; CS event queue (registration window)
queue    times 16 db 0                ; 8 x (event, socket)

; ---- Card Services function codes ----------------------------------------
CS_DEREG        equ 02h
CS_FIRSTTUPLE   equ 07h
CS_NEXTTUPLE    equ 0Ah
CS_INFO         equ 0Bh
CS_TUPLEDATA    equ 0Dh
CS_REGISTER     equ 10h
CS_RELIO        equ 1Bh
CS_RELIRQ       equ 1Ch
CS_RELCFG       equ 1Eh
CS_REQIO        equ 1Fh
CS_REQIRQ       equ 20h
CS_REQCFG       equ 30h

EV_REMOVAL      equ 05h
EV_CLIENTINFO   equ 14h
EV_INSERT       equ 40h
EV_REGCOMPLETE  equ 82h

; ---- CS argument packets -------------------------------------------------
p_reg:   dw 0004h                     ; attributes: I/O client
         dw 0080h                     ; event mask: card-detect change
         dw 0                         ; client data word  (-> DI)
p_regsel dw 0                         ; client data selector (-> DS), = our CS
         dw 0                         ; client data offset (-> SI)
         dw 0                         ; reserved
         dw 0210h                     ; expected CS version 2.10
P_REG_LEN equ 0Eh

p_tup:   dw 0                         ; +00 socket
         dw 0                         ; +02 attributes
         db 0                         ; +04 desired tuple code
         db 0                         ; +05 tuple offset (GetTupleData)
         dw 0                         ; +06 flags
         dd 0                         ; +08 Link state
         dd 0                         ; +0C CIS state
         dw 0                         ; +10 first/next: ret code+link / data: maxlen
         dw 0                         ; +12 data: (ret) length
tdata:   times TDMAX db 0             ; +14 tuple data
P_TUP1_LEN equ 12h
P_TUPD_LEN equ 14h + TDMAX

p_io:    dw 0                         ; +00 socket
         dw 0                         ; +02 base port 1 (SB block)
         db 0                         ; +04 size 1
         db 0                         ; +05 attrs 1 (0 = 8-bit)
p_io_b2  dw 0                         ; +06 base port 2 (FM/MPU cluster)
p_io_s2  db 0                         ; +08 size 2
         db 0                         ; +09 attrs 2
         db 10                        ; +0A address lines decoded
P_IO_LEN equ 0Bh

p_irq:   dw 0                         ; +00 socket
         dw 0                         ; +02 attributes
         db 0                         ; +04 (ret) assigned IRQ
p_irq_i1 db 0                         ; +05 IRQ info 1
p_irq_i2 dw 0                         ; +06 IRQ info 2 (bitmap)
P_IRQ_LEN equ 8

p_cfg:   dw 0                         ; +00 socket
p_cfg_at dw 0002h                     ; +02 attrs: bit1 = IRQ active
p_cfg_vc db 50                        ; +04 Vcc  (tenths of a volt)
p_cfg_v1 db 50                        ; +05 Vpp1
p_cfg_v2 db 50                        ; +06 Vpp2
         db 02h                       ; +07 interface: I/O+memory
p_cfg_cb dd 00000400h                 ; +08 config register base
         db 0                         ; +0C status reg
         db 0                         ; +0D pin reg
         db 0                         ; +0E copy reg
p_cfg_op db 60h                       ; +0F option reg: COR index | level IRQ
         db 01h                       ; +10 present regs: option only
         db 0                         ; +11 ext status
P_CFG_LEN equ 12h

p_rel:   dw 0                         ; ReleaseConfiguration: socket
P_REL_LEN equ 2

p_rirq:  dw 0                         ; ReleaseIRQ: socket
         dw 0                         ;   attributes
p_rirq_i db 0                         ;   IRQ to release
P_RIRQ_LEN equ 5

;==========================================================================
;  KNOWN-CARD MANIFEST (shared by every backend; resident for CS hot-plug)
;
;  The RATOC REX-5571/5572 share MANFID C015/0001; a VERS_1 substring picks
;  the model.  Indices are CURATED per card, never read from the CIS: the
;  5572's CIS default (22h) selects its SCSI side.  k_ob is the OB-mode
;  index (C101: 24h = self-decoded fixed 220h, on-box verified on the 425;
;  20h relocatable everywhere else).  The COR *base* does come from each
;  card's CISTPL_CONFIG at runtime (Eiger: 3F0h).  gpo: combo cards gating
;  their output amp off an ES1688 GPO at base+7 (IBM: GPO0 high or silent).
;  C101/Eiger carry NO F_JOY: the C101 cannot do joystick (operator-
;  corrected vs the old ES1688GO manifest), and the IBM box's glue decodes
;  201h onto its FM DATA register - a game's trigger writes would scribble
;  on the OPL.
;
;  record: +0 manf, +2 card, +4 vers-substring ptr (0 = any), +6 index,
;          +7 OB index, +8 flags, +9 gpo (FFh = none), +10 name ptr
KREC     equ 12
ktab:
        dw 0C015h, 00001h, v_c72
        db 20h, 20h, F_MPU|F_JOY, 0FFh
        dw n_5572
        dw 0C015h, 00001h, v_c71
        db 20h, 20h, F_MPU|F_JOY, 0FFh
        dw n_5571
        dw 0C015h, 00001h, 0
        db 20h, 20h, F_MPU|F_JOY, 0FFh
        dw n_rato
        dw 00032h, 00204h, 0
        db 20h, 24h, 0, 0FFh
        dw n_c101
        dw 00004h, 02000h, v_epx
        db 20h, 20h, 0, 0FFh
        dw n_epx
        dw 000A4h, 0002Dh, v_ibm
        db 01h, 01h, 0, 01h
        dw n_ibm
        dw 0, 0                       ; end of table
v_c72:  db 'CARD 72',0
v_c71:  db 'CARD 71',0
v_epx:  db 'EPX-AA2000',0
v_ibm:  db 'CD-ROM',0
n_5572: db 'RATOC REX-5572',0
n_5571: db 'RATOC REX-5571',0
n_rato: db 'RATOC REX-5571/5572',0
n_c101: db 'Panasonic/KME KXL-C101',0
n_epx:  db 'Eiger Labs EPX-AA2000',0
n_ibm:  db 'IBM Portable CD-ROM (ES1688)',0
n_unk:  db 'Unknown card',0

;==========================================================================
;  identify - match [manfid] + versbuf against the manifest.
;  CF clear = hit (k_* and [matched] filled).  CF set = miss.
;==========================================================================
identify:
        push si
        push ax
        mov  si, ktab
.next:  mov  ax, [si]
        or   ax, [si+2]
        jz   .unk
        mov  ax, [manfid]
        cmp  ax, [si]
        jne  .miss
        mov  ax, [manfid+2]
        cmp  ax, [si+2]
        jne  .miss
        mov  ax, [si+4]
        or   ax, ax
        jz   .hit
        call vers_has
        jc   .miss
.hit:   mov  al, [si+6]
        mov  [k_cor], al
        mov  al, [si+7]
        mov  [k_ob], al
        mov  al, [si+8]
        mov  [k_flags], al
        mov  al, [si+9]
        mov  [k_gpo], al
        mov  ax, [si+10]
        mov  [k_name], ax
        mov  byte [matched], 1
        pop  ax
        pop  si
        clc
        ret
.miss:  add  si, KREC
        jmp  .next
.unk:   pop  ax
        pop  si
        stc
        ret

; ---- force_ident: /FORCE identity for an unknown/unreadable card --------
force_ident:
        push ax
        mov  al, [o_cfg]
        mov  [k_cor], al
        mov  [k_ob], al
        mov  byte [k_flags], F_MPU|F_JOY
        mov  byte [k_gpo], 0FFh
        mov  word [k_name], n_unk
        mov  byte [matched], 0
        pop  ax
        ret

; ---- vers_has: is the ASCIIZ needle at AX a substring of
;      versbuf[0..verslen)?  CF clear = found. ----------------------------
vers_has:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        mov  dx, ax                   ; needle
        xor  bx, bx                   ; haystack start index
.outer: cmp  bx, [verslen]
        jae  .no
        mov  si, dx
        mov  di, bx
.inner: mov  al, [si]
        or   al, al
        jz   .yes                     ; needle exhausted = match
        cmp  di, [verslen]
        jae  .adv
        cmp  al, [versbuf+di]
        jne  .adv
        inc  si
        inc  di
        jmp  .inner
.adv:   inc  bx
        jmp  .outer
.no:    stc
        jmp  .r
.yes:   clc
.r:     pop  di
        pop  si
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

;==========================================================================
;  cs_call - invoke Card Services (INT 1Ah, AH=AFh; SystemSoft binding).
;  in:  AL=function, BX=packet offset, CX=ArgLength, DX=handle
;  out: CF + AX status.  Preserves BX/CX/DX/SI/DI/ES.
;==========================================================================
cs_call:
        push es
        push bx
        push cx
        push dx
        push si
        push di
        mov  ah, 0AFh
        push cs
        pop  es
        int  1Ah
        pop  di
        pop  si
        pop  dx
        pop  cx
        pop  bx
        pop  es
        ret

;==========================================================================
;  cs_callback - Card Services event handler (FAR).
;  AL=event, CX=socket, ES:BX=buffer.  Returns AX=0, CF clear.
;==========================================================================
cs_callback:
        pushf
        push bx
        push cx
        push dx
        push si
        push di
        push bp
        push ds
        push es
        push cs
        pop  ds

        cmp  al, EV_REGCOMPLETE
        jne  .n1
        mov  byte [regdone], 1
        jmp  .done
.n1:
        cmp  al, EV_CLIENTINFO
        jne  .n2
        mov  word [es:bx+2], 0        ; returned-info length = 0
        jmp  .done
.n2:
        cmp  al, EV_INSERT
        je   .ins
        cmp  al, EV_REMOVAL
        je   .rem
        jmp  .done
.ins:
        cmp  byte [live], 0
        je   .queue
        cmp  byte [inbusy], 0
        jne  .done
        cmp  byte [o_off], 0
        jne  .done                    ; /OFF'd: stay dormant until re-enabled
        cmp  byte [cfged], 0
        jne  .done                    ; already driving a card
        mov  al, [o_sock]             ; /S pins hot-plug to one socket too
        cmp  al, 0FFh
        je   .insgo
        xor  ah, ah
        cmp  ax, cx
        jne  .done
.insgo: mov  [arg_sock], cx
        call cs_configure             ; resident, no DOS calls inside
        jmp  .done
.rem:
        cmp  byte [live], 0
        je   .queue
        cmp  byte [cfged], 0
        je   .done
        cmp  cx, [oursock]
        jne  .done
        call release_all
        mov  byte [cfged], 0
        jmp  .done
.queue:
        mov  dl, [qcnt]
        cmp  dl, 8
        jae  .done
        xor  dh, dh
        mov  si, dx
        shl  si, 1
        mov  [queue+si], al           ; event
        mov  [queue+si+1], cl         ; socket (low byte)
        inc  byte [qcnt]
.done:
        pop  es
        pop  ds
        pop  bp
        pop  di
        pop  si
        pop  dx
        pop  cx
        pop  bx
        popf
        clc
        xor  ax, ax
        retf

;==========================================================================
;  cs_configure - full CS bring-up of the card in [arg_sock].
;  Resident-safe: INT 1A + port I/O only.  Results in r_*; r_stage=0 ok.
;==========================================================================
cs_configure:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        mov  byte [inbusy], 1
        mov  byte [r_stage], 0
        mov  byte [r_mpuok], 0
        mov  byte [r_fmok], 0
        mov  byte [r_fm], 0
        mov  byte [r_mpu], 0
        mov  byte [r_nompu], 0
        mov  byte [r_irq], 0FFh
        mov  byte [mapflags], 0
        mov  byte [matched], 0

        mov  ax, [arg_sock]           ; stamp the socket into every packet
        mov  [p_tup], ax
        mov  [p_io], ax
        mov  [p_irq], ax
        mov  [p_cfg], ax
        mov  [p_rel], ax
        mov  [p_rirq], ax

        ; ---- CIS identity: MANFID + VERS_1 against the manifest -----------
        mov  byte [p_tup+4], 20h      ; CISTPL_MANFID
        call tup_get
        jnc  .midok
        jmp  .nocard
.midok: mov  ax, [tdata]
        mov  [manfid], ax
        mov  ax, [tdata+2]
        mov  [manfid+2], ax

        mov  word [verslen], 0        ; CISTPL_VERS_1 strings
        mov  byte [p_tup+4], 15h
        call tup_get
        jc   .novers
        mov  cx, [p_tup+12h]          ; returned data length
        cmp  cx, 2
        jbe  .novers
        sub  cx, 2                    ; skip the major/minor bytes
        cmp  cx, VBMAX
        jbe  .vc
        mov  cx, VBMAX
.vc:
        mov  [verslen], cx
        push es
        push cs
        pop  es
        mov  si, tdata+2
        mov  di, versbuf
        cld
        rep  movsb
        pop  es
.novers:
        call identify
        jnc  .known
        mov  byte [r_stage], 6        ; not one of ours
        jmp  .out
.known:
        mov  al, [k_cor]
        or   al, 40h                  ; COR index | level-mode IRQ
        mov  [p_cfg_op], al

        ; effective MPU: the plan's en_mpu, unless this card can't do it
        mov  al, [en_mpu]
        mov  [em_mpu], al
        test byte [k_flags], F_MPU
        jnz  .emok
        cmp  al, 0
        je   .emok
        mov  byte [em_mpu], 0
        mov  byte [r_nompu], 1        ; report the drop
.emok:

        ; ---- CISTPL_CONFIG -> COR base (default 400h on any trouble) -----
        mov  word [cfgbase], 0400h
        mov  byte [p_tup+4], 1Ah
        call tup_get
        jc   .cfb
        mov  al, [tdata]              ; TPCC_SZ: bits1:0 = RADR size - 1
        and  ax, 3
        mov  dl, [tdata+2]            ; RADR low
        xor  dh, dh
        test ax, ax
        jz   .cfs
        mov  dh, [tdata+3]            ; RADR high (rasz >= 2)
.cfs:
        mov  [cfgbase], dx
.cfb:
        mov  ax, [cfgbase]
        mov  [p_cfg_cb], ax
        mov  word [p_cfg_cb+2], 0

        ; ---- RequestIO: range1 = SB block, range2 = FM/MPU cluster -------
        mov  ax, [o_sb]
        mov  [p_io+2], ax
        mov  byte [p_io+4], 16
        mov  byte [p_io+5], 0
        ; plan range 2.  FM by default; MPU swaps it in (after first trying
        ; a span covering both, which works on hosts whose I/O pool has no
        ; holes between them).
        cmp  byte [em_mpu], 0
        je   .r2_fmq
        cmp  byte [en_fm], 0
        je   .r2_mpu
        mov  ax, [o_fm]               ; span only if the geometry is sane
        sub  ax, [o_mpu]
        jbe  .r2_mpu                  ; FM not above MPU
        cmp  ax, 0F0h
        ja   .r2_mpu                  ; size byte would overflow
        mov  ax, [o_mpu]
        mov  [p_io_b2], ax
        mov  cx, [o_fm]
        add  cx, 2
        sub  cx, ax
        mov  [p_io_s2], cl
        call req_io
        jnc  .io_fm_mpu
        jmp  .r2_mpu                  ; span refused: fall back to MPU only
.r2_fmq:
        cmp  byte [en_fm], 0
        je   .r2_none
        mov  ax, [o_fm]               ; FM only
        mov  [p_io_b2], ax
        mov  byte [p_io_s2], 2
        call req_io
        jnc  .io_fm
        jmp  .r2_none
.r2_mpu:
        mov  ax, [o_mpu]
        mov  [p_io_b2], ax
        mov  byte [p_io_s2], 2
        call req_io
        jnc  .io_mpu
.r2_none:
        mov  word [p_io_b2], 0
        mov  byte [p_io_s2], 0
        call req_io
        jnc  .io_done
        mov  byte [r_stage], 2        ; even the bare SB block was refused
        mov  [r_code], ax
        jmp  .out
.io_fm_mpu:
        mov  byte [r_fm], 1
        mov  byte [r_mpu], 1
        jmp  .io_done
.io_fm:
        mov  byte [r_fm], 1
        jmp  .io_done
.io_mpu:
        mov  byte [r_mpu], 1
.io_done:

        ; ---- RequestIRQ ladder: (1) specific /I IRQ, (2) a bitmap holding
        ;      ONLY that IRQ - separates "bad packet format" from "IRQ
        ;      unavailable", (3) any MPU-capable IRQ. ----------------------
        mov  word [p_irq+2], 0
        mov  word [r_ir1], 0
        mov  word [r_ir2], 0
        mov  al, [o_irq]
        and  al, 0Fh
        or   al, 20h                  ; level + specific IRQ
        mov  [p_irq_i1], al
        mov  word [p_irq_i2], 0
        mov  al, CS_REQIRQ
        mov  bx, p_irq
        mov  cx, P_IRQ_LEN
        mov  dx, [handle]
        call cs_call
        jnc  .irqok
        mov  [r_ir1], ax
        mov  byte [p_irq_i1], 30h     ; level + use bitmap
        mov  cl, [o_irq]
        mov  ax, 1
        shl  ax, cl
        mov  [p_irq_i2], ax           ; bitmap = only the preferred IRQ
        mov  al, CS_REQIRQ
        mov  cx, P_IRQ_LEN
        call cs_call
        jnc  .irqok
        mov  [r_ir2], ax
        mov  byte [p_irq_i1], 30h
        mov  word [p_irq_i2], 06A0h   ; IRQs 5,7,9,10
        mov  al, CS_REQIRQ
        call cs_call
        jc   .noirq
.irqok:
        mov  al, [p_irq+4]
        mov  [r_irq], al
.noirq:

        ; ---- RequestConfiguration ----------------------------------------
        mov  word [p_cfg_at], 0002h   ; IRQ active
        cmp  byte [r_irq], 0FFh
        jne  .cat
        mov  word [p_cfg_at], 0
.cat:
        mov  byte [p_cfg_vc], 50
        mov  byte [p_cfg_v1], 50
        mov  byte [p_cfg_v2], 50
        call try_cfg                  ; walks candidate ArgLengths (1Bh dance)
        jnc  .cfgok
        mov  byte [p_cfg_v1], 0       ; some stacks reject Vpp=Vcc
        mov  byte [p_cfg_v2], 0
        call try_cfg
        jnc  .cfgok
        mov  [r_code], ax
        mov  byte [r_stage], 4
        call rel_io_irq               ; undo the partial claim
        jmp  .out
.cfgok:

        ; ---- ES1688 bring-up (shared chip path) --------------------------
        mov  al, [r_irq]
        call essirq_calc              ; FFh -> essirq 0 (no MPU routing)
        xor  al, al
        cmp  byte [r_fm], 0
        je   .mf1
        or   al, M_FM
.mf1:   cmp  byte [r_mpu], 0
        je   .mf2
        or   al, M_MPU
.mf2:   mov  [mapflags], al
        call chip_init                ; CF = DSP never answered
        jnc  .alive
        mov  byte [r_stage], 5        ; configured but silent - report it
.alive:
        mov  ax, [arg_sock]
        mov  [oursock], ax
        mov  byte [cfged], 1
.out:
        mov  byte [inbusy], 0
        pop  di
        pop  si
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret
.nocard:
        mov  [r_code], ax
        mov  byte [r_stage], 7
        jmp  .out

; ---- tup_get: GetFirstTuple (code in p_tup+4) then GetTupleData ---------
;      out: CF set if either failed (AX = status); data in tdata
tup_get:
        mov  word [p_tup+2], 0        ; attributes
        mov  byte [p_tup+5], 0        ; tuple offset
        mov  al, CS_FIRSTTUPLE
        mov  bx, p_tup
        mov  cx, P_TUP1_LEN
        mov  dx, [handle]
        call cs_call
        jc   .r
        mov  word [p_tup+10h], TDMAX  ; max data to return
        mov  al, CS_TUPLEDATA
        mov  cx, P_TUPD_LEN
        call cs_call
.r:
        ret

; ---- try_cfg: RequestConfiguration, walking candidate ArgLengths --------
;      RBIL says 12h but SystemSoft 2.06 rejects it with 1Bh (bad length);
;      keep trying plausible packet sizes until the answer isn't 1Bh.
try_cfg:
        push si
        mov  si, cfglens
.t:
        lodsb
        test al, al
        jz   .exhaust
        mov  cl, al
        xor  ch, ch
        mov  al, CS_REQCFG
        mov  bx, p_cfg
        mov  dx, [handle]
        call cs_call
        jnc  .out                     ; success (CF clear)
        cmp  ax, 1Bh
        je   .t                       ; wrong length - next candidate
        stc                           ; a real refusal - surface it
        jmp  .out
.exhaust:
        mov  ax, 1Bh
        stc
.out:
        pop  si
        ret

cfglens: db 12h, 11h, 13h, 14h, 10h, 16h, 1Ah, 0Eh, 0

; ---- req_io: RequestIO with the current p_io ----------------------------
req_io:
        mov  al, CS_REQIO
        mov  bx, p_io
        mov  cx, P_IO_LEN
        mov  dx, [handle]
        call cs_call
        ret

; ---- release_all / rel_io_irq -------------------------------------------
release_all:
        mov  al, CS_RELCFG
        mov  bx, p_rel
        mov  cx, P_REL_LEN
        mov  dx, [handle]
        call cs_call
rel_io_irq:
        mov  al, CS_RELIO
        mov  bx, p_io                 ; same packet we requested with
        mov  cx, P_IO_LEN
        mov  dx, [handle]
        call cs_call
        mov  al, [r_irq]
        cmp  al, 0FFh
        je   .r
        mov  [p_rirq_i], al
        mov  word [p_rirq+2], 0
        mov  al, CS_RELIRQ
        mov  bx, p_rirq
        mov  cx, P_RIRQ_LEN
        mov  dx, [handle]
        call cs_call
.r:
        ret

;==========================================================================
;  cs_reconfig - FAR control entry for a later ES1688GO run (found via the
;  sig block).  The caller has copied fresh options in.  Release whatever
;  we hold, then - unless /OFF - probe and reconfigure with the new
;  options.  Results land in the r_* block for the caller to copy back.
;==========================================================================
cs_reconfig:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push ds
        push es
        push cs
        pop  ds
        cmp  byte [cfged], 0
        je   .go
        call release_all
        mov  byte [cfged], 0
.go:
        cmp  byte [o_off], 0
        jne  .done                    ; /OFF: stay dormant (hot-plug re-arms)
        xor  dx, dx
.p:
        cmp  byte [cfged], 0
        jne  .done
        mov  al, [o_sock]             ; /S pins the probe to one socket
        cmp  al, 0FFh
        je   .any
        cmp  al, dl
        jne  .skip
.any:
        mov  [arg_sock], dx
        call cs_configure
.skip:
        inc  dx
        cmp  dl, [n_sock]
        jb   .p
.done:
        pop  es
        pop  ds
        pop  di
        pop  si
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        retf

;==========================================================================
;  SHARED ES1688 BRING-UP  (resident: the CS hot-plug path runs it too)
;  Register model proven in ES1688GO / CS1688GO / OB1688GO / LX1688GO.
;
;  in:  [o_sb]/[o_fm]/[o_mpu], [mapflags], [essirq], [k_gpo],
;       [o_gpoov]/[o_gpoval], [o_tone]
;  out: CF set = DSP reset failed (nothing else done);
;       [r_vmaj]/[r_vmin]/[r_mpuok]/[r_fmok]
;==========================================================================
chip_init:
        push ax
        push bx
        push cx
        push dx
        push si
        push bp
        call dsp_reset
        jnc  .up
        jmp  .dead
.up:
        mov  al, 0E1h                 ; DSP version
        call dsp_cmd
        call dsp_get
        mov  [r_vmaj], al
        call dsp_get
        mov  [r_vmin], al

        ; unmute: SB Pro mixer master/FM/voice
        mov  al, 22h
        mov  ah, 0DDh
        call mix_write
        mov  al, 26h
        mov  ah, 0DDh
        call mix_write
        mov  al, 04h
        mov  ah, 0DDh
        call mix_write

        ; ES1688 ext mode + mixer reg 40h: bit1=OPL enable, bit0=legacy
        ; 388h/gameport decode, bits[4:3]=MPU port, bits[7:5]=MPU IRQ.
        mov  al, 0C6h                 ; extended commands on
        call dsp_cmd
        mov  al, 40h
        call mix_read                 ; AL = current mixer 40h
        and  al, 04h                  ; preserve bit2
        or   al, 02h                  ; ESFM/OPL enable
        test byte [mapflags], M_FM|M_JOY
        jz   .no40leg
        or   al, 01h                  ; legacy 388h + gameport decode
.no40leg:
        test byte [mapflags], M_MPU
        jz   .no40mpu
        mov  ah, [essirq]
        or   ah, ah
        jz   .no40mpu
        mov  cl, 5
        shl  ah, cl                   ; IRQ code -> bits 7:5
        or   al, ah
        mov  bx, [o_mpu]
        and  bl, 0F0h
        shr  bl, 1                    ; (mpu & F0) >> 1 == port nibble << 3
        or   al, bl
.no40mpu:
        mov  ah, al
        mov  al, 40h
        call mix_write

        ; ---- MPU sanity: UART reset, expect FEh ACK ----------------------
        mov  byte [r_mpuok], 0
        test byte [mapflags], M_MPU
        jz   .nompu
        cmp  byte [essirq], 0
        je   .nompu
        call mpu_probe
        jc   .nompu
        mov  byte [r_mpuok], 1
.nompu:

        ; ---- box amp-enable via ES1688 GPO (port base+7) -----------------
        cmp  byte [o_gpoov], 0
        je   .gman
        mov  al, [o_gpoval]
        jmp  .gwr
.gman:
        mov  al, [k_gpo]
        cmp  al, 0FFh
        je   .gdone
.gwr:
        mov  dx, [o_sb]
        add  dx, 7
        out  dx, al
.gdone:

        ; ---- OPL presence at the dedicated FM port (timer test) ----------
        mov  byte [r_fmok], 0
        test byte [mapflags], M_FM
        jz   .nofm
        call fm_detect
        jc   .nofm
        mov  byte [r_fmok], 1
.nofm:
        cmp  byte [o_tone], 0
        je   .fine
        call fm_tone
.fine:
        pop  bp
        pop  si
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        clc
        ret
.dead:
        pop  bp
        pop  si
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        stc
        ret

; ---- essirq_calc: AL = IRQ -> [essirq] (ES1688 reg40 code; 0 = no MPU) --
essirq_calc:
        push ax
        mov  ah, 4
        cmp  al, 9
        je   .set
        mov  ah, 5
        cmp  al, 5
        je   .set
        mov  ah, 6
        cmp  al, 7
        je   .set
        mov  ah, 7
        cmp  al, 10
        je   .set
        mov  ah, 0
.set:   mov  [essirq], ah
        pop  ax
        ret

; ---- DSP helpers (base in [o_sb]) ---------------------------------------
dsp_reset:                            ; CF set = no AAh handshake
        mov  dx, [o_sb]
        add  dx, 6
        mov  al, 1
        out  dx, al
        mov  cx, 200
.d1:    loop .d1
        xor  al, al
        out  dx, al
        mov  bx, 4000
.poll:
        mov  dx, [o_sb]
        add  dx, 0Eh
        in   al, dx
        test al, 80h
        jnz  .avail
        dec  bx
        jnz  .poll
        stc
        ret
.avail:
        mov  dx, [o_sb]
        add  dx, 0Ah
        in   al, dx
        cmp  al, 0AAh
        jne  .bad
        clc
        ret
.bad:   stc
        ret

dsp_cmd:                              ; AL = command
        push bx
        push dx
        mov  bl, al
        mov  dx, [o_sb]
        add  dx, 0Ch
        push cx
        mov  cx, 10000
.w:
        in   al, dx
        test al, 80h
        jz   .go
        loop .w
.go:
        mov  al, bl
        out  dx, al
        pop  cx
        pop  dx
        pop  bx
        ret

dsp_get:                              ; -> AL (FFh on timeout)
        push cx
        push dx
        mov  cx, 10000
.w:
        mov  dx, [o_sb]
        add  dx, 0Eh
        in   al, dx
        test al, 80h
        jnz  .rd
        loop .w
        mov  al, 0FFh
        jmp  .r
.rd:
        mov  dx, [o_sb]
        add  dx, 0Ah
        in   al, dx
.r:
        pop  dx
        pop  cx
        ret

mix_read:                             ; AL = index -> AL = value
        push dx
        mov  dx, [o_sb]
        add  dx, 4
        out  dx, al
        call iod
        inc  dx
        in   al, dx
        pop  dx
        ret

mix_write:                            ; AL = index, AH = value
        push dx
        mov  dx, [o_sb]
        add  dx, 4
        out  dx, al
        call iod
        inc  dx
        mov  al, ah
        out  dx, al
        call iod
        pop  dx
        ret

iod:                                  ; short I/O settle delay
        push ax
        push cx
        mov  cx, 16
.l:
        in   al, 80h
        loop .l
        pop  cx
        pop  ax
        ret

iodn:                                 ; CX port-80h reads (AX/CX preserved)
        push ax
        push cx
.l:
        in   al, 80h
        loop .l
        pop  cx
        pop  ax
        ret

; ---- fm_write: AL = OPL reg, AH = value, at the dedicated port [o_fm] ---
fm_write:
        push cx
        push dx
        mov  dx, [o_fm]
        out  dx, al
        mov  cx, 8
        call iodn
        inc  dx
        mov  al, ah
        out  dx, al
        mov  cx, 30
        call iodn
        pop  dx
        pop  cx
        ret

; ---- fm_detect: classic AdLib timer-1 test at [o_fm].  CF clear = OPL. --
fm_detect:
        push bx
        push cx
        push dx
        mov  al, 04h
        mov  ah, 60h                  ; mask both timers
        call fm_write
        mov  al, 04h
        mov  ah, 80h                  ; reset IRQ flags
        call fm_write
        mov  dx, [o_fm]
        in   al, dx
        mov  bl, al                   ; status before
        mov  al, 02h
        mov  ah, 0FFh                 ; timer 1 preset
        call fm_write
        mov  al, 04h
        mov  ah, 21h                  ; start timer 1
        call fm_write
        mov  cx, 200
        call iodn
        mov  dx, [o_fm]
        in   al, dx
        mov  bh, al                   ; status after
        mov  al, 04h
        mov  ah, 60h
        call fm_write
        mov  al, 04h
        mov  ah, 80h
        call fm_write
        and  bl, 0E0h
        jnz  .no
        and  bh, 0E0h
        cmp  bh, 0C0h
        jne  .no
        clc
        jmp  .r
.no:    stc
.r:     pop  dx
        pop  cx
        pop  bx
        ret

; ---- fm_tone: the OB1688GO "ding" via SB-base FM.  Silent modulator +
;      full carrier with a bell envelope (attack F, decay 5, sustain 7,
;      RELEASE 7) - the nonzero release is what lets a bare key-off ring
;      out naturally instead of droning forever (the old sustained-organ
;      patch had release 0 - learned the loud way). ----------------------
fm_tone:
        push ax
        push bx
        push cx
        push dx
        push si
        mov  si, tonetab
        mov  cx, (tonetab_end - tonetab) / 2
        call fm_regs
        mov  bx, 25                   ; ~1 s: 25 x ~40 ms of port-80 reads
.td:
        mov  cx, 40000
.td2:
        in   al, 80h
        loop .td2
        dec  bx
        jnz  .td
        mov  si, toneoff
        mov  cx, (toneoff_end - toneoff) / 2
        call fm_regs
        pop  si
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

fm_regs:                              ; write CX (addr,data) pairs from SI
        mov  dx, [o_sb]
        lodsb
        out  dx, al                   ; FM address
        call iod
        inc  dx
        lodsb
        out  dx, al                   ; FM data
        call iod
        call iod
        call iod
        loop fm_regs
        ret

tonetab: db 20h,01h, 40h,3Fh, 60h,0F5h, 80h,77h    ; modulator: silent, mult 1
         db 23h,01h, 43h,00h, 63h,0F5h, 83h,77h    ; carrier: full, bell env
         db 0C0h,01h, 0BDh,00h                      ; additive, rhythm off
         db 0A0h,41h, 0B0h,32h                      ; F-num + key-on
tonetab_end:
toneoff: db 0B0h,12h                                ; key-off; release 7 rings out
toneoff_end:

; ---- mpu_probe: UART-mode reset at [o_mpu], expect FEh ACK.  CF=fail.
;      Historical note: CARDGO 1.0/1.1 shipped a one-instruction bug here
;      that impersonated a hardware mystery across three machines: the DX
;      reload between the FEh compare and its branch used INC, which
;      rewrites ZF, so the branch tested INC's flags - every ACK was read
;      (consumed!) and then discarded, and the probe timed out on the
;      now-empty FIFO.  OB1688GO's original used a flag-preserving MOV.
;      Full forensic log: doc/DERIVATION.md 2026-07-18.  Keep conditional
;      branches IMMEDIATELY after their compare. --------------------------
mpu_probe:
        mov  dx, [o_mpu]
        inc  dx
        mov  bp, 2000h
.dw:                                  ; wait for DRR (command register free)
        in   al, dx
        test al, 40h
        jz   .cmd
        dec  bp
        jnz  .dw
        stc
        ret
.cmd:
        mov  al, 0FFh                 ; UART reset
        out  dx, al
        mov  bp, 8000h
.dr:                                  ; wait for DSR (data ready)
        in   al, dx
        test al, 80h
        jz   .rd
        dec  bp
        jnz  .dr
        stc
        ret
.rd:
        mov  dx, [o_mpu]
        in   al, dx
        cmp  al, 0FEh
        je   .got                     ; branch FIRST: restoring DX with INC
        mov  dx, [o_mpu]              ; would clobber the compare's ZF (the
        inc  dx                       ; CARDGO 1.0/1.1 bug - every ACK was
        dec  bp                       ; read, consumed, and then discarded)
        jnz  .dr
        stc
        ret
.got:
        clc
        ret

RESEND:                               ; end of resident image

;==========================================================================
;  INIT  (transient: discarded when /CS mode goes TSR)
;==========================================================================
init:
        cld
        mov  si, m_banner
        call prstr

        mov  si, 81h
        call parse_args

        ; ---- global sanity ----------------------------------------------
        mov  ax, [o_mpu]              ; MPU port must be 3x0h
        and  ax, 0FF0Fh
        cmp  ax, 0300h
        je   .mpok
        mov  si, m_badmpu
        jmp  errout
.mpok:
        cmp  byte [o_irq], 15
        jbe  .irqok
        mov  si, m_badirq
        jmp  errout
.irqok:
        cmp  byte [o_force], 0        ; /FORCE needs /S in every mode
        je   .fok
        cmp  byte [o_sock], 0FFh
        jne  .fok
        mov  si, m_fneeds
        jmp  errout
.fok:

        ; ---- pick the host backend --------------------------------------
        mov  al, [o_mode]
        or   al, al
        jnz  .dispatch
        call chk_cs
        jnc  .a_cs
        call chk_ss
        jnc  .a_ob
        call chk_pcic
        jnc  .a_pc
        mov  si, m_nomode
        jmp  errout
.a_cs:  mov  al, MODE_CS
        jmp  .dset
.a_ob:  mov  al, MODE_OB
        jmp  .dset
.a_pc:  mov  al, MODE_PCIC
.dset:  mov  [o_mode], al
.dispatch:
        cmp  al, MODE_CS
        jne  .d2
        mov  si, m_hostcs
        call prstr
        jmp  cs_mode
.d2:
        cmp  al, MODE_OB
        jne  .d3
        mov  si, m_hostob
        call prstr
        jmp  ob_mode
.d3:
        mov  si, m_hostpc
        call prstr
        jmp  pc_mode

; ---- chk_cs: Card Services present?  CF clear = yes ([n_sock] filled) ---
chk_cs:
        mov  word [ibuf], 50h
        mov  word [ibuf+2], 0         ; scrub the signature slot first
        mov  al, CS_INFO
        mov  bx, ibuf
        mov  cx, 50h
        xor  dx, dx
        xor  si, si
        xor  di, di
        call cs_call
        jc   .no
        cmp  word [ibuf+2], 5343h     ; "CS"
        je   .yes
        cmp  word [ibuf+2], 4353h     ; "SC"
        je   .yes
.no:
        stc
        ret
.yes:
        mov  ax, [ibuf+4]
        cmp  ax, 8
        jbe  .ns
        mov  ax, 8
.ns:    mov  [n_sock], al
        clc
        ret

; ---- chk_ss: Socket Services 'SS' signature?  CF clear = yes ------------
chk_ss:
        push cx
        xor  cx, cx                   ; a stopped-clock BIOS must not fake it
        mov  ax, 8000h
        call ob_ssvc
        jc   .no
        cmp  cx, 5353h
        jne  .no
        pop  cx
        clc
        ret
.no:
        pop  cx
        stc
        ret

; ---- chk_pcic: any 82365-class controller at 3E0/3E2/3E4/3E6? -----------
chk_pcic:
        push cx
        mov  cx, 4
        mov  word [pc_idx], PCIC_BASE
        mov  byte [pc_off], 0
.c:
        call pc_present
        jnc  .yes
        add  word [pc_idx], 2
        loop .c
        pop  cx
        stc
        ret
.yes:
        pop  cx
        clc
        ret

;==========================================================================
;  CS MODE  (transient init; the resident half is above)
;==========================================================================
cs_mode:
        ; ---- feature plan: SB + FM by default; /MPU opts in --------------
        mov  al, 1
        cmp  byte [o_nofm], 0
        je   .f1
        xor  al, al
.f1:    mov  [en_fm], al
        mov  al, [o_mpuon]
        cmp  byte [o_nompu], 0
        je   .f2
        xor  al, al
.f2:    mov  [en_mpu], al
        mov  byte [en_joy], 0
        cmp  byte [o_joyon], 0
        je   .f3
        mov  si, m_csnojoy            ; only two I/O ranges through CS
        call prstr
.f3:
        cmp  byte [o_force], 0
        je   .f4
        mov  si, m_csnoforce
        call prstr
.f4:
        ; ---- CS present? (also true when auto-detected; cheap to redo) ---
        call chk_cs
        jnc  .csok
        mov  si, m_nocs
        jmp  errout
.csok:
        mov  si, m_cs
        call prstr
        mov  al, [n_sock]
        call prdec99
        call crlf

        ; ---- already resident?  Hand the new options to that copy -------
        call find_resident
        jnc  cs_handoff
        cmp  byte [res_badver], 0
        je   .nover
        mov  si, m_vermsg
        jmp  errout
.nover:
        cmp  byte [o_off], 0
        je   .fresh
        mov  si, m_offnone
        jmp  errout
.fresh:

        ; ---- RegisterClient (inline: the handle comes back in DX) --------
        mov  [p_regsel], cs           ; callback's DS
        mov  ah, 0AFh
        mov  al, CS_REGISTER
        push cs
        pop  es
        mov  bx, p_reg
        mov  cx, P_REG_LEN
        xor  dx, dx
        mov  di, cs                   ; ClientEntry = DI:SI
        mov  si, cs_callback
        int  1Ah
        jnc  .regok
        mov  [r_code], ax
        mov  si, m_regfail
        call prstr
        mov  ax, [r_code]
        call prhex4
        call crlf
        mov  ax, 4C03h
        int  21h
.regok:
        mov  [handle], dx

        ; ---- give CS a moment to deliver REGISTRATION_COMPLETE -----------
        xor  ax, ax
        mov  es, ax
        mov  bx, [es:46Ch]            ; BIOS tick count (low word)
.wait:
        int  28h                      ; DOS idle - let TSR stacks breathe
        call drain_queue
        cmp  byte [cfged], 0
        jne  .wend                    ; configured via a queued event - done
        cmp  byte [regdone], 0
        jne  .wend
        xor  ax, ax
        mov  es, ax
        mov  ax, [es:46Ch]
        sub  ax, bx
        cmp  ax, 36                   ; ~2 s
        jb   .wait
.wend:
        mov  si, m_reg
        call prstr
        mov  si, m_regyes
        cmp  byte [regdone], 0
        jne  .rp
        mov  si, m_regno
.rp:
        call prstr

        ; ---- actively probe the sockets: SystemSoft CS does NOT generate
        ;      artificial CARD_INSERTION events, so waiting for the
        ;      callback only works for a future physical insert -----------
        cmp  byte [cfged], 0
        jne  cs_report
        xor  dx, dx                   ; DX = socket number
.scan:
        cmp  byte [cfged], 0
        jne  cs_report
        mov  al, [o_sock]             ; /S pins the probe to one socket
        cmp  al, 0FFh
        je   .sgo
        cmp  al, dl
        jne  .snext
.sgo:
        mov  [arg_sock], dx
        push dx
        mov  si, m_probe
        call prstr
        mov  al, dl
        call prdec99
        call crlf
        call cs_configure
        call cs_repsock               ; per-socket verdict while we scan
        pop  dx
.snext:
        inc  dx
        cmp  dl, [n_sock]
        jb   .scan

; ---- CS report + TSR -----------------------------------------------------
cs_report:
        cmp  byte [cfged], 0
        je   .nocard
        cmp  byte [r_stage], 5
        jne  .good
        mov  si, m_nodsp
        call prstr
        mov  ax, [o_sb]
        call prhex3
        call crlf
        jmp  cs_tsr
.good:
        mov  ax, [arg_sock]
        mov  [rep_sock], al
        mov  al, [r_irq]
        mov  [rep_irq], al
        mov  al, [k_cor]
        mov  [rep_cor], al
        mov  byte [wcount], 0         ; no window line in CS mode
        call report
        jmp  cs_tsr
.nocard:
        mov  si, m_nocard
        call prstr
        cmp  byte [hndoff], 0
        jne  cs_tsr
        mov  si, m_resident
        call prstr
cs_tsr:
        cmp  byte [hndoff], 0
        jne  .exit                    ; handoff run: the OLD copy stays
        mov  byte [live], 1           ; callback now acts on events itself
        mov  dx, (RESEND - $$ + 100h + 15) >> 4   ; paragraphs incl. PSP
        mov  ax, 3100h
        int  21h
.exit:
        mov  ax, 4C00h
        int  21h

; ---- cs_handoff: drive the resident copy with the new options -----------
cs_handoff:
        cld
        mov  es, [res_seg]            ; options in (same binary = offsets)
        mov  si, o_sb
        mov  di, o_sb
        mov  cx, O_LEN
        rep  movsb
        mov  ax, [res_off]
        mov  [fptr], ax
        mov  ax, [res_seg]
        mov  [fptr+2], ax
        call far [fptr]               ; resident releases + reconfigures
        push ds                       ; results back: resident -> our vars
        push cs
        pop  es
        mov  si, arg_sock
        mov  di, arg_sock
        mov  ds, [res_seg]
        mov  cx, R_LEN
        rep  movsb
        mov  al, [cfged]
        mov  [es:cfged], al
        pop  ds
        mov  byte [hndoff], 1
        cmp  byte [o_off], 0
        jne  .offmsg
        mov  si, m_via
        call prstr
        jmp  cs_report
.offmsg:
        mov  si, m_offok
        call prstr
        mov  ax, 4C00h
        int  21h

; ---- find_resident: MCB walk for a process block carrying our sig -------
;      CF clear + res_seg/res_off set when found; res_badver notes a
;      version-mismatched copy (incl. a legacy CS1688GO 'CS68' resident).
find_resident:
        mov  ah, 52h
        int  21h                      ; ES:BX -> DOS List of Lists
        mov  ax, [es:bx-2]            ; first MCB segment
        mov  cx, 300                  ; chain-walk guard
.w:
        mov  es, ax
        mov  dl, [es:0]               ; 'M' = more, 'Z' = last
        cmp  dl, 'M'
        je   .chk
        cmp  dl, 'Z'
        jne  .no                      ; broken chain - stop
.chk:
        mov  si, [es:1]               ; owner PSP
        mov  di, ax
        inc  di                       ; block data = MCB + 1
        cmp  si, di                   ; a program block owns itself
        jne  .next
        mov  bx, cs
        cmp  di, bx                   ; skip our own image
        je   .next
        push es
        mov  es, di
        cmp  word [es:103h], 'ES'
        jne  .leg
        cmp  word [es:105h], 'GO'
        jne  .leg
        cmp  word [es:107h], CGVER    ; exact version match required
        jne  .bv
        mov  ax, [es:109h]
        pop  es
        mov  [res_seg], di
        mov  [res_off], ax
        clc
        ret
.leg:
        cmp  word [es:103h], 'CD'     ; a stale CARDGO-era resident?
        jne  .leg2
        cmp  word [es:105h], 'GO'
        je   .bv
.leg2:
        cmp  word [es:103h], 'CS'     ; a legacy CS1688GO resident?
        jne  .pn
        cmp  word [es:105h], '68'
        jne  .pn
.bv:
        mov  byte [res_badver], 1     ; note it, keep walking
.pn:
        pop  es
.next:
        cmp  dl, 'Z'
        je   .no
        mov  si, [es:3]               ; block size in paragraphs
        add  ax, si
        inc  ax                       ; next MCB
        dec  cx                       ; (chain-walk guard; the loop grew past
        jz   .no                      ;  short-jump range with the legacy-sig
        jmp  .w                       ;  checks, so no LOOP instruction here)
.no:
        stc
        ret

; ---- cs_repsock: one-line verdict for the socket just probed ------------
cs_repsock:
        mov  al, [r_stage]
        cmp  al, 0
        je   .r                       ; success: main summary reports it
        cmp  al, 5
        je   .r                       ; DSP verdict handled by main summary
        cmp  al, 7
        jne  .n6
        mov  si, m_s_tup              ; empty socket / unreadable CIS
        call prstr
        mov  ax, [r_code]
        call prhex4
        jmp  .nl
.n6:
        cmp  al, 6
        jne  .n2
        mov  si, m_s_wrong
        call prstr
        mov  ax, [manfid]
        call prhex4
        mov  al, '/'
        call prchar
        mov  ax, [manfid+2]
        call prhex4
        jmp  .nl
.n2:
        cmp  al, 2
        jne  .n4
        mov  si, m_s_io
        call prstr
        mov  ax, [r_code]
        call prhex4
        jmp  .nl
.n4:
        mov  si, m_s_cfg
        call prstr
        mov  ax, [r_code]
        call prhex4
.nl:
        call crlf
.r:
        ret

; ---- drain_queue: act on events queued during the registration window ---
drain_queue:
        push es
        cli
        mov  cl, [qcnt]
        mov  byte [qcnt], 0
        push cs                       ; snapshot the queue with events masked
        pop  es                       ; so a mid-drain callback can't clobber
        push cx                       ; entries we are still reading
        mov  si, queue
        mov  di, qcopy
        mov  cx, 8
        rep  movsw
        pop  cx
        sti
        pop  es
        xor  ch, ch
        jcxz .r
        mov  si, qcopy
.e:
        lodsw                         ; AL = event, AH = socket
        cmp  al, EV_INSERT
        jne  .skip
        cmp  byte [cfged], 0
        jne  .skip
        push cx
        push si
        mov  al, ah
        xor  ah, ah
        mov  [arg_sock], ax
        call cs_configure
        pop  si
        pop  cx
.skip:
        loop .e
.r:
        ret

;==========================================================================
;  OB MODE - HP OmniBook 300/425/430 Socket Services direct.
;  Quirks probed on the 425 (doc/RECON-425.md): Vcc/Vpp power-table
;  indices are 1-BASED; SetWindow DH bit0 is INVERTED from RBIL (memory
;  windows want it clear = 0Eh, I/O windows set = 05h); socket status
;  RDY/WP bits float - a socket is "in use by the OS" iff an enabled
;  COMMON-memory window maps it.  4 I/O windows (4-7, 16 bytes max, pow2
;  size), politely allocated: SB > FM > MPU > JOY degrade when they run out.
;==========================================================================
FW_NOCARD  equ 0
FW_DRIVE   equ 1
FW_UNKNOWN equ 2

ob_mode:
        mov  word [o_wseg], OB_ATTRSEG ; CIS/COR window fixed here (probed)
        cmp  byte [o_off], 0
        je   .noff
        mov  si, m_obnooff
        jmp  errout
.noff:
        ; ---- feature plan: everything on, card flags gate MPU/JOY --------
        mov  al, 1
        cmp  byte [o_nofm], 0
        je   .f1
        xor  al, al
.f1:    mov  [en_fm], al
        mov  al, 1
        cmp  byte [o_nompu], 0
        je   .f2
        xor  al, al
.f2:    mov  [en_mpu], al
        mov  byte [en_joy], 1

        ; ---- Socket Services present? ------------------------------------
        call chk_ss
        jnc  .ssok
        mov  si, m_noss
        jmp  errout
.ssok:
        ; ---- find + bring up a card --------------------------------------
        mov  al, [o_sock]
        cmp  al, 0FFh
        je   .scan
        cmp  al, 1
        jb   .badsock
        cmp  al, 4
        ja   .badsock
        mov  [sock], al
        call ob_try
        jc   .failx
        jmp  ob_got
.badsock:
        mov  si, m_obbadsock
        jmp  errout
.failx: jmp  ob_failx
.scan:
        mov  byte [sock], 1
.next:
        call ob_try
        jnc  ob_got
        inc  byte [sock]
        cmp  byte [sock], 4
        jbe  .next
        jmp  ob_fails

; ---------- card accepted: window 0 still mapped on attr space -----------
ob_got:
        mov  bx, [cfgbase]
        cmp  bx, 3FFEh
        jbe  .corok0
        mov  si, m_badcis
        call prstr
        call ob_restw0
        int  20h
.corok0:
        mov  al, [k_ob]               ; OB-mode index (C101: 24h self-decode)
        cmp  byte [matched], 0
        jne  .mi
        mov  al, [o_cfg]
.mi:
        mov  [rep_cor], al
        cmp  byte [o_pulse], 0
        jne  .nolevel
        or   al, 40h                  ; LevlREQ
.nolevel:
        mov  [corval], al
        mov  cx, [o_wseg]
        mov  es, cx
        mov  [es:bx], al              ; write the COR
        mov  cx, 1
        call ticks
        mov  ah, [es:bx]
        cmp  ah, [corval]             ; quiet unless the latch disagrees
        je   .corok
        mov  si, m_corbad
        call prstr
        mov  al, ah
        call prhex2
        call crlf
.corok:
        call ob_restw0

        ; ---- socket to I/O interface + IRQ steering ----------------------
        mov  bh, 0C0h
        mov  bl, [sock]
        mov  cx, 0111h                ; Vcc idx 1 (5V), Vpp 1/1 - 1-BASED
        xor  dx, dx
        mov  si, 0002h                ; I/O interface
        mov  di, 8000h                ; IRQ steering on, level
        mov  al, [o_irq]
        xor  ah, ah
        or   di, ax
        mov  ax, 8E00h
        call ob_ssvc
        jc   ob_esserr

        ; ---- I/O windows (politely) + chip ------------------------------
        call ob_map_all               ; degrades/exits internally

        mov  al, [o_irq]
        call essirq_calc
        call chip_init
        jnc  .chipok
        jmp  e_nodsp
.chipok:
        mov  al, [o_irq]
        mov  [rep_irq], al
        mov  al, [sock]
        mov  [rep_sock], al
        call report
        int  20h

; ---------- failure reporting --------------------------------------------
ob_failx:                             ; /S given; [failwhy] says what
        cmp  byte [failwhy], FW_UNKNOWN
        je   .unk
        cmp  byte [failwhy], FW_DRIVE
        je   .drv
        mov  si, m_socket
        call prstr
        mov  al, [sock]
        call prdec99
        mov  si, m_nocards
        call prstr
        int  20h
.drv:
        mov  si, m_socket
        call prstr
        mov  al, [sock]
        call prdec99
        mov  si, m_indrive
        call prstr
        int  20h
.unk:
        mov  si, m_socket
        call prstr
        mov  al, [sock]
        call prdec99
        mov  si, m_unrec
        call prstr
        call pr_lastid
        mov  si, m_addman
        call prstr
        int  20h

ob_fails:
        cmp  byte [sawunk], 0
        jne  .seen
        mov  si, m_noknown
        call prstr
        int  20h
.seen:
        mov  si, m_nomatch
        call prstr
        call pr_lastid
        mov  si, m_addman2
        call prstr
        int  20h

pr_lastid:                            ; 'MANFID xxxx/xxxx "vers".'
        mov  si, m_manf2
        call prstr
        mov  ax, [manfid]
        call prhex4
        mov  al, '/'
        call prchar
        mov  ax, [manfid+2]
        call prhex4
        mov  al, ' '
        call prchar
        mov  al, '"'
        call prchar
        call pr_vers
        mov  al, '"'
        call prchar
        mov  al, '.'
        call prchar
        call crlf
        ret

; ---- ob_try: probe socket [sock].  CF=0 accepted (window 0 left mapped,
;      identity set).  CF=1 rejected, [failwhy] = reason. -----------------
ob_try:
        mov  byte [failwhy], FW_NOCARD
        mov  bl, [sock]
        call ob_getstat
        test al, 80h                  ; card detect
        jz   .no
        call ob_chkdrive
        jnc  .safe
        mov  byte [failwhy], FW_DRIVE
.no:
        stc
        ret
.safe:
        mov  ax, 8E00h                ; power 5V, memory IF for CIS phase
        mov  bh, 0C0h
        mov  bl, [sock]
        mov  cx, 0111h
        xor  dx, dx
        mov  si, 0001h
        xor  di, di
        call ob_ssvc
        jc   .no
        mov  cx, 4                    ; ~220ms settle
        call ticks
        mov  ax, 9000h                ; ResetCard
        xor  bh, bh
        mov  bl, [sock]
        call ob_ssvc
        jc   .no
        mov  bp, 40
.rdy:
        mov  cx, 1
        call ticks
        mov  bl, [sock]
        call ob_getstat
        test al, 40h                  ; READY
        jnz  .rdyok
        dec  bp
        jnz  .rdy
        jmp  .no
.rdyok:
        mov  ax, 8800h                ; save window 0 state
        xor  bx, bx
        call ob_ssvc
        jc   .no
        mov  [w0_bl], bl
        mov  [w0_cx], cx
        mov  [w0_dx], dx
        mov  [w0_si], si
        mov  [w0_di], di
        mov  ax, 8900h                ; map window 0 on attr space @ D0000
        xor  bh, bh
        mov  bl, [sock]
        mov  cx, 0004h
        mov  dh, OB_WIN_ATTR
        mov  dl, OB_SPEED
        mov  si, 00D0h
        xor  di, di
        call ob_ssvc
        jc   .no
        call cis_even                 ; pull the even bytes
        call cis_parse
        jnc  .parsed
        call ob_restw0                ; no CONFIG tuple = not usable here
        stc
        ret
.parsed:
        call identify
        jnc  .ok
        mov  byte [sawunk], 1
        mov  byte [failwhy], FW_UNKNOWN
        cmp  byte [o_force], 0
        jne  .forced
        call ob_restw0
        stc
        ret
.forced:
        call force_ident
.ok:
        clc
        ret

; ---- ob_chkdrive: CF=1 if an enabled common-mem window maps [sock] ------
ob_chkdrive:
        mov  byte [gw_n], 1
.w:
        mov  ax, 8800h
        mov  bh, [gw_n]
        call ob_ssvc
        jc   .nx
        cmp  bl, [sock]
        jne  .nx
        test dh, 04h                  ; enabled
        jz   .nx
        test dh, 02h                  ; attribute space? then not a drive map
        jnz  .nx
        stc
        ret
.nx:
        inc  byte [gw_n]
        cmp  byte [gw_n], 3
        jbe  .w
        clc
        ret

ob_ssvc:
        push ds
        push es
        push bp
        int  1Ah
        pop  bp
        pop  es
        pop  ds
        ret

ob_getstat:                           ; BL = socket -> AL = card status
        push bx
        mov  ax, 8F00h
        xor  bh, bh
        call ob_ssvc
        pop  bx
        jc   ob_esserr
        mov  al, dl
        ret

ob_restw0:
        mov  ax, 8900h
        xor  bh, bh
        mov  bl, [w0_bl]
        mov  cx, [w0_cx]
        mov  dx, [w0_dx]
        mov  si, [w0_si]
        mov  di, [w0_di]
        call ob_ssvc
        ret

ob_esserr:
        mov  bl, ah
        mov  si, m_sserr
        call prstr
        mov  al, bl
        call prhex2
        call crlf
        int  20h

; ---- polite window allocation --------------------------------------------
; ob_classify: survey I/O windows 4-7 into q* tables.
; qstat: 0 = occupied (another socket, card present), 1 = free, 2 = claimed.
ob_classify:
        mov  byte [cw_i], 0
.next:
        mov  al, [cw_i]
        xor  ah, ah
        mov  di, ax
        mov  bh, al
        add  bh, 4
        mov  ax, 8800h                ; GetWindow
        call ob_ssvc
        jc   .busy                    ; unreadable: occupied, zero range
        push di
        shl  di, 1
        mov  [qbase+di], si
        mov  [qsize+di], cx
        pop  di
        test dh, 04h                  ; disabled -> free
        jz   .free
        cmp  bl, [sock]               ; ours from a previous run -> reclaim
        je   .free
        push di
        call ob_getstat               ; BL socket -> AL card status
        pop  di
        test al, 80h
        jz   .free                    ; enabled but socket empty -> stale
        mov  byte [qstat+di], 0
        jmp  .adv
.busy:
        push di
        shl  di, 1
        mov  word [qsize+di], 0       ; empty range: never matches overlap
        pop  di
        mov  byte [qstat+di], 0
        jmp  .adv
.free:
        mov  byte [qstat+di], 1
.adv:
        inc  byte [cw_i]
        cmp  byte [cw_i], 4
        jb   .next
        ret

; ob_alloc: SI=base, CX=size -> map into any free window.
; CF=0 done (recorded for the summary). CF=1: AL=0 conflict with an
; occupied window's range, AL=1 out of free windows.
ob_alloc:
        mov  [aw_base], si
        mov  [aw_size], cx
        mov  byte [aw_i], 0
.chk:
        mov  al, [aw_i]
        xor  ah, ah
        mov  di, ax
        cmp  byte [qstat+di], 0
        jne  .cnext
        shl  di, 1
        mov  ax, [qbase+di]
        add  ax, [qsize+di]
        cmp  si, ax                   ; desired base >= their end?
        jae  .cnext
        mov  ax, si
        add  ax, cx
        cmp  ax, [qbase+di]           ; desired end <= their base?
        jbe  .cnext
        mov  al, 0                    ; overlap
        stc
        ret
.cnext:
        inc  byte [aw_i]
        cmp  byte [aw_i], 4
        jb   .chk
        mov  byte [aw_i], 0
.find:
        mov  al, [aw_i]
        xor  ah, ah
        mov  di, ax
        cmp  byte [qstat+di], 1
        je   .take
        inc  byte [aw_i]
        cmp  byte [aw_i], 4
        jb   .find
        mov  al, 1                    ; no free window
        stc
        ret
.take:
        mov  bh, [aw_i]
        add  bh, 4
        mov  ax, 8900h
        mov  bl, [sock]
        mov  si, [aw_base]
        mov  cx, [aw_size]
        mov  dh, OB_WIN_IO            ; probed: I/O windows want DH bit0=1
        mov  dl, OB_SPEED
        xor  di, di
        call ob_ssvc
        jc   ob_esserr
        mov  al, [aw_i]
        xor  ah, ah
        mov  di, ax
        mov  byte [qstat+di], 2
        mov  al, [wcount]
        xor  ah, ah
        mov  bx, ax
        mov  al, [aw_i]
        add  al, 4
        mov  [wnum+bx], al
        shl  bx, 1
        mov  ax, [aw_base]
        mov  [wbase+bx], ax
        mov  ax, [aw_size]
        mov  [wsize+bx], ax
        inc  byte [wcount]
        clc
        ret

; ob_noteskip: BX -> feature name, AL = ob_alloc reason
ob_noteskip:
        push ax
        mov  si, m_note
        call prstr
        mov  si, bx
        call prstr
        pop  ax
        or   al, al
        jnz  .nowin
        mov  si, m_conflict
        call prstr
        ret
.nowin:
        mov  si, m_outwin
        call prstr
        ret

ob_map_all:
        mov  byte [wcount], 0
        mov  byte [mapflags], 0
        call ob_classify
        mov  si, [o_sb]               ; SB block: required
        mov  cx, 16
        call ob_alloc
        jnc  .sbok
        jmp  ob_sbfatal
.sbok:
        cmp  byte [en_fm], 0
        je   .mpu
        mov  si, [o_fm]
        mov  cx, 4
        call ob_alloc
        jnc  .fmok
        mov  bx, s_fm
        call ob_noteskip
        jmp  .mpu
.fmok:
        or   byte [mapflags], M_FM
.mpu:
        cmp  byte [en_mpu], 0
        je   .joy
        test byte [k_flags], F_MPU
        jnz  .mgo
        mov  byte [r_nompu], 1        ; card can't - note it in the summary
        jmp  .joy
.mgo:
        mov  si, [o_mpu]
        mov  cx, 2
        call ob_alloc
        jnc  .mpuok
        mov  bx, s_mpu
        call ob_noteskip
        jmp  .joy
.mpuok:
        or   byte [mapflags], M_MPU
.joy:
        cmp  byte [en_joy], 0
        je   .done
        test byte [k_flags], F_JOY
        jz   .done
        mov  si, 201h
        mov  cx, 1
        call ob_alloc
        jnc  .joyok
        mov  bx, s_joy
        call ob_noteskip
        ret
.joyok:
        or   byte [mapflags], M_JOY
.done:
        ret

ob_sbfatal:
        push ax
        mov  si, m_sbfail
        call prstr
        pop  ax
        or   al, al
        jnz  .nowin
        mov  si, m_conflict
        call prstr
        int  20h
.nowin:
        mov  si, m_outwin
        call prstr
        int  20h

;==========================================================================
;  PCIC MODE - Intel 82365-class point enabler (port of our ES1688GO.C).
;
;  Two I/O windows: win0 covers the SB block (with /JOY it stretches down
;  to the gameport at 201h, just below the SB base - folding the gameport
;  into win0 lets /JOY run alongside /FM and /MPU); win1 spans the FM/MPU
;  cluster above the base.  The CIS probe picks a host segment no other
;  card has a memory window on, so scanning never collides with a card
;  another enabler has running (ThinkPad 235 two-card lesson).
;==========================================================================
pc_mode:
        ; ---- /OFF: power the socket down and exit ------------------------
        cmp  byte [o_off], 0
        je   .noff
        mov  al, [o_sock]
        cmp  al, 0FFh
        jne  .osk
        xor  al, al
.osk:
        mov  [sock], al
        call pc_select
        call pc_present
        jnc  .offok
        jmp  pc_nochip
.offok:
        mov  al, 06h
        xor  ah, ah
        call pc_wr
        mov  al, 03h
        xor  ah, ah
        call pc_wr
        mov  al, 02h
        xor  ah, ah
        call pc_wr
        mov  si, m_socket
        call prstr
        mov  al, [sock]
        call prdec99
        mov  si, m_offdone
        call prstr
        int  20h
.noff:
        ; ---- feature plan: exactly the named add-ons, or FM+MPU ----------
        mov  al, [o_fmon]
        or   al, [o_mpuon]
        or   al, [o_joyon]
        jnz  .named
        mov  byte [en_fm], 1
        mov  byte [en_mpu], 1
        mov  byte [en_joy], 0
        jmp  .subs
.named:
        mov  al, [o_fmon]
        mov  [en_fm], al
        mov  al, [o_mpuon]
        mov  [en_mpu], al
        mov  al, [o_joyon]
        mov  [en_joy], al
.subs:
        cmp  byte [o_nofm], 0
        je   .s1
        mov  byte [en_fm], 0
.s1:
        cmp  byte [o_nompu], 0
        je   .s2
        mov  byte [en_mpu], 0
.s2:
        ; ---- plan the two I/O windows ------------------------------------
        mov  ax, [o_sb]
        mov  [p_w0s], ax
        add  ax, 15
        mov  [p_w0e], ax
        cmp  byte [en_joy], 0
        je   .nj
        mov  word [p_w0s], 200h       ; fold the gameport (201h) into win0
.nj:
        mov  byte [p_have1], 0
        cmp  byte [en_fm], 0
        jne  .w1
        cmp  byte [en_mpu], 0
        jne  .w1
        jmp  .wdone
.w1:
        mov  word [p_w1s], 3FFh
        mov  word [p_w1e], 200h
        cmp  byte [en_mpu], 0
        je   .w1f
        mov  ax, [o_mpu]
        cmp  ax, [p_w1s]
        jae  .a1
        mov  [p_w1s], ax
.a1:
        inc  ax
        cmp  ax, [p_w1e]
        jbe  .w1f
        mov  [p_w1e], ax
.w1f:
        cmp  byte [en_fm], 0
        je   .w1d
        mov  ax, [o_fm]
        cmp  ax, [p_w1s]
        jae  .a2
        mov  [p_w1s], ax
.a2:
        inc  ax
        cmp  ax, [p_w1e]
        jbe  .w1d
        mov  [p_w1e], ax
.w1d:
        mov  byte [p_have1], 1
.wdone:

        ; ---- validate before touching hardware ---------------------------
        mov  al, [o_sock]
        cmp  al, 0FFh
        je   .v1
        cmp  al, 7
        jbe  .v1
        mov  si, m_pcbadsock
        jmp  errout
.v1:
        mov  ax, [o_sb]
        cmp  ax, 200h
        jb   .badsb
        add  ax, 15
        cmp  ax, PCIC_BASE
        jb   .v2
.badsb:
        mov  si, m_badsb
        jmp  errout
.v2:
        cmp  byte [en_fm], 0
        je   .v3
        mov  ax, [o_fm]
        cmp  ax, 200h
        jb   .badfm
        inc  ax
        cmp  ax, PCIC_BASE
        jb   .v3
.badfm:
        mov  si, m_badfm
        jmp  errout
.v3:
        cmp  byte [p_have1], 0
        je   .v5
        mov  ax, [p_w1e]
        cmp  ax, PCIC_BASE
        jb   .v4
        mov  si, m_wclash
        jmp  errout
.v4:
        mov  ax, [p_w0s]              ; overlap: w0s <= w1e && w1s <= w0e
        cmp  ax, [p_w1e]
        ja   .v5
        mov  ax, [p_w1s]
        cmp  ax, [p_w0e]
        ja   .v5
        mov  si, m_wovl
        jmp  errout
.v5:

        ; ---- unless /W pinned it, pick a probe segment no other card has
        ;      a memory window on ----------------------------------------
        cmp  byte [o_wgiven], 0
        jne  .wok
        call pc_findfree
.wok:

        ; ---- identify the card; only the match is left powered + mapped --
        mov  al, [o_sock]
        cmp  al, 0FFh
        je   .scan
        mov  [sock], al
        call pc_select
        call pc_present
        jnc  .p1
        jmp  pc_nochip
.p1:
        call pc_probe
        jnc  pc_found
        cmp  word [manfid], 0
        je   .norc
        mov  si, m_socket
        call prstr
        mov  al, [sock]
        call prdec99
        mov  si, m_unrec
        call prstr
        call pr_lastid
        mov  si, m_addman3
        call prstr
        int  20h
.norc:
        mov  si, m_socket
        call prstr
        mov  al, [sock]
        call prdec99
        mov  si, m_nocards
        call prstr
        int  20h
.scan:
        mov  byte [any_chip], 0
        mov  byte [sock], 0
.sc1:
        mov  al, [sock]
        call pc_select
        call pc_present
        jc   .sc2
        mov  byte [any_chip], 1
        call pc_probe
        jnc  pc_found
.sc2:
        inc  byte [sock]
        cmp  byte [sock], 7
        jbe  .sc1
        cmp  byte [any_chip], 0
        jne  .nomatch
        mov  si, m_nopcic
        jmp  errout
.nomatch:
        cmp  word [manfid], 0
        je   .noknown
        mov  si, m_nomatch
        call prstr
        call pr_lastid
        mov  si, m_addman2
        call prstr
        int  20h
.noknown:
        mov  si, m_noknown2
        call prstr
        int  20h

; ---------- card accepted: attr window still mapped ----------------------
pc_found:
        ; drop MPU on cards that can't use it (no MIDI jack, or the port
        ; aliases); recompute win1 without the MPU port
        test byte [k_flags], F_MPU
        jnz  .mok
        cmp  byte [en_mpu], 0
        je   .mok
        mov  byte [en_mpu], 0
        mov  byte [r_nompu], 1
        mov  byte [p_have1], 0
        cmp  byte [en_fm], 0
        je   .mok
        mov  ax, [o_fm]
        mov  [p_w1s], ax
        inc  ax
        mov  [p_w1e], ax
        mov  byte [p_have1], 1
.mok:
        ; drop /JOY on cards whose glue can't decode 201h (the IBM combo:
        ; 201h lands on its FM DATA register).  Un-stretch win0.
        test byte [k_flags], F_JOY
        jnz  .jok
        cmp  byte [en_joy], 0
        je   .jok
        mov  byte [en_joy], 0
        mov  ax, [o_sb]
        mov  [p_w0s], ax
        mov  si, m_nojoy
        call prstr
.jok:
        ; ---- COR via the attribute window pc_probe left mapped.  Base
        ;      from the card's CISTPL_CONFIG for a recognized card; for a
        ;      forced/unreadable CIS use the 400h proven across the family.
        mov  bx, 0400h
        mov  al, [o_cfg]
        cmp  byte [matched], 0
        je   .cw
        mov  bx, [cfgbase]
        mov  al, [k_cor]
.cw:
        cmp  bx, 3FFEh
        jbe  .cw2
        mov  si, m_badcis
        jmp  errout
.cw2:
        mov  [rep_cor], al
        mov  cx, [o_wseg]
        mov  es, cx
        mov  [es:bx], al              ; plain index: no level bit on the PCIC

        ; ---- I/O windows -------------------------------------------------
        mov  al, 08h
        mov  ah, [p_w0s]
        call pc_wr
        mov  al, 09h
        mov  ah, [p_w0s+1]
        call pc_wr
        mov  al, 0Ah
        mov  ah, [p_w0e]
        call pc_wr
        mov  al, 0Bh
        mov  ah, [p_w0e+1]
        call pc_wr
        cmp  byte [p_have1], 0
        je   .now1
        mov  al, 0Ch
        mov  ah, [p_w1s]
        call pc_wr
        mov  al, 0Dh
        mov  ah, [p_w1s+1]
        call pc_wr
        mov  al, 0Eh
        mov  ah, [p_w1e]
        call pc_wr
        mov  al, 0Fh
        mov  ah, [p_w1e+1]
        call pc_wr
.now1:
        mov  al, 07h                  ; 8-bit windows
        xor  ah, ah
        call pc_wr
        mov  ah, [o_irq]              ; I/O-card mode + IRQ steer
        and  ah, 0Fh
        or   ah, 70h
        mov  al, 03h
        call pc_wr
        mov  ah, 40h                  ; enable I/O win0 (+win1); mem win off
        cmp  byte [p_have1], 0
        je   .en
        or   ah, 80h
.en:
        mov  al, 06h
        call pc_wr

        ; ---- chip bring-up ----------------------------------------------
        xor  al, al
        cmp  byte [en_fm], 0
        je   .b1
        or   al, M_FM
.b1:
        cmp  byte [en_mpu], 0
        je   .b2
        or   al, M_MPU
.b2:
        cmp  byte [en_joy], 0
        je   .b3
        or   al, M_JOY
.b3:
        mov  [mapflags], al
        mov  al, [o_irq]
        call essirq_calc
        call chip_init
        jnc  .chipok
        jmp  e_nodsp
.chipok:
        ; ---- window list for the summary ---------------------------------
        mov  byte [wcount], 1
        mov  byte [wnum], 0
        mov  ax, [p_w0s]
        mov  [wbase], ax
        mov  cx, [p_w0e]
        sub  cx, ax
        inc  cx
        mov  [wsize], cx
        cmp  byte [p_have1], 0
        je   .rep
        mov  byte [wcount], 2
        mov  byte [wnum+1], 1
        mov  ax, [p_w1s]
        mov  [wbase+2], ax
        mov  cx, [p_w1e]
        sub  cx, ax
        inc  cx
        mov  [wsize+2], cx
.rep:
        mov  al, [sock]
        mov  [rep_sock], al
        mov  al, [o_irq]
        mov  [rep_irq], al
        call report
        int  20h

pc_nochip:
        mov  si, m_nochip1
        call prstr
        mov  al, [sock]
        call prdec99
        mov  si, m_nochip2
        call prstr
        mov  ax, [pc_idx]
        call prhex3
        mov  al, ')'
        call prchar
        call crlf
        int  20h

; ---- PCIC register access ------------------------------------------------
pc_select:                            ; AL = socket 0..7
        push ax
        push bx
        mov  bl, al
        xor  bh, bh
        and  bl, 0FEh                 ; chip base = 3E0h + (s & ~1)
        add  bx, PCIC_BASE
        mov  [pc_idx], bx
        mov  byte [pc_off], 0         ; bank B of a chip sits at +40h
        test al, 1
        jz   .r
        mov  byte [pc_off], 40h
.r:
        pop  bx
        pop  ax
        ret

pc_rd:                                ; AL = reg -> AL = value
        push dx
        add  al, [pc_off]
        mov  dx, [pc_idx]
        out  dx, al
        inc  dx
        in   al, dx
        pop  dx
        ret

pc_wr:                                ; AL = reg, AH = value
        push ax
        push dx
        add  al, [pc_off]
        mov  dx, [pc_idx]
        out  dx, al
        inc  dx
        mov  al, ah
        out  dx, al
        pop  dx
        pop  ax
        ret

pc_present:                           ; CF clear = 82365-class ID answers
        push ax
        mov  al, 0                    ; identification/revision register
        call pc_rd
        and  al, 0C0h
        cmp  al, 80h
        je   .yes
        pop  ax
        stc
        ret
.yes:
        pop  ax
        clc
        ret

pc_ms:                                ; AX = ~milliseconds of port-80h reads
        push ax
        push bx
        push cx
        mov  bx, ax                   ; BX counts: the inner reads eat AL
.m:
        mov  cx, 1000
.l:
        in   al, 80h
        loop .l
        dec  bx
        jnz  .m
        pop  cx
        pop  bx
        pop  ax
        ret

; ---- pc_probe: power socket [sock] (already selected), map its attribute
;      window at [o_wseg], read the CIS, identify.  CF=0: ours (left
;      powered + mapped).  CF=1: put back the way we found it - a card
;      ALREADY running there is restored exactly, not powered off. --------
pc_probe:
        call pc_present
        jnc  .cd
        jmp  .nope
.cd:
        mov  al, 01h                  ; both card-detect bits?
        call pc_rd
        and  al, 0Ch
        cmp  al, 0Ch
        je   .have
        jmp  .nope
.have:
        mov  al, 01h
        call pc_rd
        and  al, 40h                  ; power already up = a running card
        mov  [p_wason], al
        mov  al, 03h                  ; save the regs we borrow
        call pc_rd
        mov  [p_s03], al
        mov  al, 06h
        call pc_rd
        mov  [p_s06], al
        mov  al, 10h
        call pc_rd
        mov  [p_s10], al
        mov  al, 11h
        call pc_rd
        mov  [p_s11], al
        mov  al, 12h
        call pc_rd
        mov  [p_s12], al
        mov  al, 13h
        call pc_rd
        mov  [p_s13], al
        mov  al, 14h
        call pc_rd
        mov  [p_s14], al
        mov  al, 15h
        call pc_rd
        mov  [p_s15], al
        cmp  byte [p_wason], 0
        jne  .waspow
        mov  al, 02h                  ; power up
        mov  ah, 95h
        call pc_wr
        ; Poll power-good rather than a fixed wait: the 82365SL asserts it
        ; near instantly, but CardBus-era bridges (ThinkPad 235) ramp Vcc
        ; through a soft power switch and can take a few hundred ms.
        mov  bx, 50
.pw:
        mov  ax, 10
        call pc_ms
        mov  al, 01h
        call pc_rd
        test al, 40h
        jnz  .pgood
        dec  bx
        jnz  .pw
        mov  al, 02h                  ; power never came good
        xor  ah, ah
        call pc_wr
        jmp  .nope
.pgood:
        mov  ax, 100                  ; card settle after power-good
        call pc_ms
.waspow:
        mov  al, 03h                  ; reset off, memory mode
        mov  ah, 40h
        call pc_wr
        mov  ax, 100
        call pc_ms
        ; ---- memory window 0 -> [o_wseg], REG active ---------------------
        mov  ax, [o_wseg]
        mov  cl, 8
        shr  ax, cl                   ; start page (A19..A12)
        mov  [pw_pg], ax
        mov  al, 10h
        mov  ah, [pw_pg]
        call pc_wr
        mov  al, 11h
        mov  ah, [pw_pg+1]
        and  ah, 3Fh
        call pc_wr
        mov  ax, [pw_pg]
        add  ax, 3                    ; 16 KB window
        mov  [pw_pg2], ax
        mov  al, 12h
        mov  ah, [pw_pg2]
        call pc_wr
        mov  al, 13h
        mov  ah, [pw_pg2+1]
        and  ah, 3Fh
        call pc_wr
        mov  ax, [pw_pg]
        neg  ax                       ; offset = (0 - start) & 3FFF, REG bit
        and  ax, 3FFFh
        or   ax, 4000h
        mov  [pw_pg2], ax
        mov  al, 14h
        mov  ah, [pw_pg2]
        call pc_wr
        mov  al, 15h
        mov  ah, [pw_pg2+1]
        call pc_wr
        mov  al, 06h
        call pc_rd
        or   al, 01h                  ; enable mem win0 (keep others)
        mov  ah, al
        mov  al, 06h
        call pc_wr
        mov  ax, 20
        call pc_ms
        call cis_even
        call cis_parse                ; CF ignored: cfgbase stays 400h
        call identify
        jnc  .ours
        mov  byte [sawunk], 1
        cmp  byte [o_force], 0
        je   .undo
        call force_ident              ; /FORCE (validated: only with /S)
        jmp  .ours
.undo:
        cmp  byte [p_wason], 0
        je   .pdown
        mov  al, 10h                  ; already-running card: restore exactly
        mov  ah, [p_s10]
        call pc_wr
        mov  al, 11h
        mov  ah, [p_s11]
        call pc_wr
        mov  al, 12h
        mov  ah, [p_s12]
        call pc_wr
        mov  al, 13h
        mov  ah, [p_s13]
        call pc_wr
        mov  al, 14h
        mov  ah, [p_s14]
        call pc_wr
        mov  al, 15h
        mov  ah, [p_s15]
        call pc_wr
        mov  al, 06h
        mov  ah, [p_s06]
        call pc_wr
        mov  al, 03h
        mov  ah, [p_s03]
        call pc_wr
        jmp  .nope
.pdown:
        mov  al, 06h                  ; we powered it just to peek
        xor  ah, ah
        call pc_wr
        mov  al, 03h
        xor  ah, ah
        call pc_wr
        mov  al, 02h
        xor  ah, ah
        call pc_wr
.nope:
        stc
        ret
.ours:
        clc
        ret

; ---- pc_findfree: pick a probe segment no other card has an enabled
;      memory window over (prefers [o_wseg], then the candidate list) -----
pc_findfree:
        mov  ax, [o_wseg]
        mov  [mw_seg], ax
        call mw_overlap
        jc   .hunt
        ret
.hunt:
        mov  si, mw_cands
.c:
        lodsw
        or   ax, ax
        jz   .none
        mov  [mw_seg], ax
        push si
        call mw_overlap
        pop  si
        jnc  .found
        jmp  .c
.found:
        mov  si, m_wbusy1
        call prstr
        mov  ax, [o_wseg]
        call prhex4
        mov  si, m_wbusy2
        call prstr
        mov  ax, [mw_seg]
        call prhex4
        mov  al, '.'
        call prchar
        call crlf
        mov  ax, [mw_seg]
        mov  [o_wseg], ax
.none:
        ret

mw_cands: dw 0D000h, 0CC00h, 0D400h, 0D800h, 0DC00h
          dw 0E000h, 0E400h, 0E800h, 0C800h, 0

; ---- mw_overlap: does [mw_seg]..+16KB overlap an ENABLED memory window on
;      any present socket?  Read-only, so it disturbs nothing.  Memory
;      windows 0..4 = bits 0..4 of the Window-Enable reg (06h); each
;      window's start/stop host page lives in regs 10h+w*8 .. +3.
;      CF set = overlap. -------------------------------------------------
mw_overlap:
        push ax
        push cx
        mov  ax, [mw_seg]
        mov  cl, 8
        shr  ax, cl
        mov  [mw_cs], ax
        add  ax, 3
        mov  [mw_ce], ax
        mov  byte [mw_sk], 0
.sock:
        mov  al, [mw_sk]
        call pc_select
        call pc_present
        jc   .next                    ; unimplemented bank floats 0FFh
        mov  al, 06h
        call pc_rd
        mov  [mw_en], al
        mov  byte [mw_w], 0
.win:
        mov  cl, [mw_w]
        mov  al, 1
        shl  al, cl
        test [mw_en], al
        jz   .nw                      ; window w not enabled
        mov  al, [mw_w]               ; reg base = 10h + w*8
        mov  cl, 3
        shl  al, cl
        add  al, 10h
        mov  [mw_rb], al
        mov  al, [mw_rb]              ; ws = ((rd(b+1)&0F)<<8) | rd(b)
        inc  al
        call pc_rd
        and  al, 0Fh
        mov  [mw_ws+1], al
        mov  al, [mw_rb]
        call pc_rd
        mov  [mw_ws], al
        mov  al, [mw_rb]              ; we = ((rd(b+3)&0F)<<8) | rd(b+2)
        add  al, 3
        call pc_rd
        and  al, 0Fh
        mov  [mw_we+1], al
        mov  al, [mw_rb]
        add  al, 2
        call pc_rd
        mov  [mw_we], al
        mov  ax, [mw_cs]              ; overlap iff cs <= we && ws <= ce
        cmp  ax, [mw_we]
        ja   .nw
        mov  ax, [mw_ws]
        cmp  ax, [mw_ce]
        ja   .nw
        pop  cx                       ; ranges overlap
        pop  ax
        stc
        ret
.nw:
        inc  byte [mw_w]
        cmp  byte [mw_w], 5
        jb   .win
.next:
        inc  byte [mw_sk]
        cmp  byte [mw_sk], 8
        jb   .sock
        pop  cx
        pop  ax
        clc
        ret

;==========================================================================
;  SHARED CIS PLUMBING  (transient: PCIC + OB probe paths)
;==========================================================================
; cis_even: copy CISLEN even host bytes from [o_wseg]:0 into cisbuf.
; (Attribute memory only implements even card addresses; the odd host
;  bytes float.)
cis_even:
        push ax
        push cx
        push si
        push di
        push ds
        push es
        push cs
        pop  es
        mov  di, cisbuf
        mov  cx, CISLEN
        mov  ax, [o_wseg]
        mov  ds, ax
        xor  si, si
        cld
.c:
        lodsb
        stosb
        inc  si
        loop .c
        pop  es
        pop  ds
        pop  di
        pop  si
        pop  cx
        pop  ax
        ret

; cis_parse: walk the dense CIS in cisbuf.  Fills [manfid], [cfgbase]
; (default 400h), versbuf/[verslen].  CF set = no CISTPL_CONFIG found.
cis_parse:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        xor  bx, bx
        mov  byte [gotcfg], 0
        mov  word [verslen], 0
        mov  word [manfid], 0
        mov  word [manfid+2], 0
        mov  word [cfgbase], 0400h
        mov  byte [matched], 0
.loop:
        mov  al, [cisbuf+bx]
        cmp  al, 0FFh
        je   .end
        or   al, al
        jnz  .real
        inc  bx                       ; null tuple
        jmp  .chk
.real:
        mov  ah, [cisbuf+bx+1]        ; link
        cmp  ah, 0FFh
        je   .end
        cmp  al, 15h                  ; CISTPL_VERS_1
        jne  .n15
        call .vers
.n15:
        cmp  al, 20h                  ; CISTPL_MANFID
        jne  .n20
        mov  dl, [cisbuf+bx+2]
        mov  dh, [cisbuf+bx+3]
        mov  [manfid], dx
        mov  dl, [cisbuf+bx+4]
        mov  dh, [cisbuf+bx+5]
        mov  [manfid+2], dx
.n20:
        cmp  al, 1Ah                  ; CISTPL_CONFIG
        jne  .n1a
        push ax
        mov  al, [cisbuf+bx+2]        ; TPCC_SZ: bits1:0 = RADR size - 1
        and  al, 03h
        mov  dl, [cisbuf+bx+4]        ; RADR low
        xor  dh, dh
        or   al, al
        jz   .rd1
        mov  dh, [cisbuf+bx+5]        ; RADR high
.rd1:
        mov  [cfgbase], dx
        mov  byte [gotcfg], 1
        pop  ax
.n1a:
        xor  dx, dx
        mov  dl, ah
        add  bx, dx
        add  bx, 2
.chk:
        cmp  bx, CISLEN-2
        jb   .loop
.end:
        cmp  byte [gotcfg], 0
        je   .bad
        pop  di
        pop  si
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        clc
        ret
.bad:
        pop  di
        pop  si
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        stc
        ret
; local: copy the VERS_1 strings (skip major/minor) into versbuf
.vers:
        push ax
        push cx
        push si
        push di
        mov  cl, ah                   ; body length
        xor  ch, ch
        cmp  cx, 2
        jbe  .vdone
        sub  cx, 2
        cmp  cx, VBMAX
        jbe  .vlen
        mov  cx, VBMAX
.vlen:
        mov  [verslen], cx
        lea  si, [cisbuf+bx+4]        ; body+2 = first string
        mov  di, versbuf
        push es
        push cs
        pop  es
        cld
        rep  movsb
        pop  es
.vdone:
        pop  di
        pop  si
        pop  cx
        pop  ax
        ret

; pr_vers: print the captured VERS_1 strings, space-separated (max 4)
pr_vers:
        push ax
        push bx
        push cx
        mov  bx, 0
        mov  cx, 4
        cmp  word [verslen], 0
        jne  .l
        mov  si, m_novers
        call prstr
        jmp  .done
.l:
        cmp  bx, [verslen]
        jae  .done
        mov  al, [versbuf+bx]
        inc  bx
        cmp  al, 0FFh
        je   .done
        or   al, al
        jnz  .ch
        mov  al, ' '
        call prchar
        loop .l
        jmp  .done
.ch:
        call prchar
        jmp  .l
.done:
        pop  cx
        pop  bx
        pop  ax
        ret

;==========================================================================
;  SHARED SUMMARY REPORT  (ES1688GO output design)
;==========================================================================
report:
; line 1: <name>[ (FORCED)]: socket n[ (auto)]  DSP vM.mm
        mov  si, [k_name]
        call prstr
        cmp  byte [matched], 0
        jne  .n1
        mov  si, m_forcedtag
        call prstr
.n1:
        mov  si, m_sock1
        call prstr
        mov  al, [rep_sock]
        call prdec99
        cmp  byte [o_sock], 0FFh
        jne  .n2
        mov  si, m_auto
        call prstr
.n2:
        mov  si, m_dspv
        call prstr
        mov  al, [r_vmaj]
        add  al, '0'
        call prchar
        mov  al, '.'
        call prchar
        mov  al, [r_vmin]
        call prdec2
        call crlf
; line 2: "   CIS: <vers>  (MANFID xxxx/xxxx)"
        mov  si, m_cis
        call prstr
        call pr_vers
        mov  si, m_manf1
        call prstr
        mov  ax, [manfid]
        call prhex4
        mov  al, '/'
        call prchar
        mov  ax, [manfid+2]
        call prhex4
        mov  al, ')'
        call prchar
        call crlf
; line 3: "   COR @ xxxh index xx"
        mov  si, m_corat
        call prstr
        mov  ax, [cfgbase]
        call prhexadr
        mov  si, m_index
        call prstr
        mov  al, [rep_cor]
        call prhex2
        call crlf
; line 4: "   SB 220  FM 388[(?)]  MPU 330[(?)]  JOY 201  IRQ n"
        mov  si, m_sb
        call prstr
        mov  ax, [o_sb]
        call prhex3
        test byte [mapflags], M_FM
        jz   .f4
        mov  si, m_fm
        call prstr
        mov  ax, [o_fm]
        call prhex3
        cmp  byte [r_fmok], 0
        jne  .f4
        mov  si, m_query
        call prstr
.f4:
        test byte [mapflags], M_MPU
        jz   .m4
        mov  si, m_mpu
        call prstr
        mov  ax, [o_mpu]
        call prhex3
        cmp  byte [r_mpuok], 0
        jne  .m4
        mov  si, m_query
        call prstr
.m4:
        test byte [mapflags], M_JOY
        jz   .j4
        mov  si, m_joy
        call prstr
.j4:
        cmp  byte [rep_irq], 0FFh
        je   .i4
        mov  si, m_irq
        call prstr
        mov  al, [rep_irq]
        call prdec99
.i4:
        call crlf
; line 5: "   I/O windows: win4 220-22F, win5 388-38B, ..."
        cmp  byte [wcount], 0
        je   .w5done
        mov  si, m_wins
        call prstr
        xor  bx, bx
.w5:
        cmp  bl, [wcount]
        jae  .w5nl
        or   bx, bx
        jz   .w5f
        mov  si, m_comma
        call prstr
.w5f:
        mov  si, m_win
        call prstr
        mov  al, [wnum+bx]
        add  al, '0'
        call prchar
        mov  al, ' '
        call prchar
        push bx
        shl  bx, 1
        mov  ax, [wbase+bx]
        push ax
        call prhex3
        mov  al, '-'
        call prchar
        pop  ax
        add  ax, [wsize+bx]
        dec  ax
        call prhex3
        pop  bx
        inc  bx
        jmp  .w5
.w5nl:
        call crlf
.w5done:
; optional: "   amp-enable: GPO 227h <- nn[ (override)]"
        cmp  byte [o_gpoov], 0
        jne  .g6
        cmp  byte [k_gpo], 0FFh
        je   .g6done
.g6:
        mov  si, m_amp
        call prstr
        mov  ax, [o_sb]
        add  ax, 7
        call prhex3
        mov  si, m_arrow
        call prstr
        mov  al, [o_gpoval]
        cmp  byte [o_gpoov], 0
        jne  .gv
        mov  al, [k_gpo]
.gv:
        call prhex2
        cmp  byte [o_gpoov], 0
        je   .g6nl
        mov  si, m_ovr
        call prstr
.g6nl:
        call crlf
.g6done:
; optional: "   TEST: OPL tone playing on SB-base FM"
        cmp  byte [o_tone], 0
        je   .t6
        mov  si, m_test
        call prstr
.t6:
; optional MPU notes
        test byte [mapflags], M_MPU
        jz   .q7
        cmp  byte [r_mpuok], 0
        jne  .q7
        mov  si, m_mpunote
        call prstr
.q7:
        cmp  byte [r_nompu], 0
        je   .q8
        mov  si, m_nompu
        call prstr
.q8:
        ret

; ---- shared fatal: card configured but no DSP handshake -----------------
e_nodsp:
        mov  si, m_nodsp
        call prstr
        mov  ax, [o_sb]
        call prhex3
        call crlf
        int  20h

;==========================================================================
;  COMMAND LINE
;  ES1688GO-tolerant: '/X', '/Xtail', value after ':' or '='; unknown
;  switches reported and ignored.
;==========================================================================
parse_args:
.loop:
        lodsb
        cmp  al, 0Dh
        je   .done
        cmp  al, '/'
        je   .sw
        cmp  al, '-'
        je   .sw
        jmp  .loop
.done:
        ret
.sw:
        lodsb
        and  al, 0DFh
        cmp  al, 'P'
        je   .p
        cmp  al, 'C'
        je   .c
        cmp  al, 'O'
        je   .o
        cmp  al, 'S'
        je   .s
        cmp  al, 'F'
        je   .f
        cmp  al, 'M'
        je   .m
        cmp  al, 'N'
        je   .n
        cmp  al, 'J'
        je   .j
        cmp  al, 'I'
        je   .i
        cmp  al, 'W'
        je   .w
        cmp  al, 'G'
        je   .g
        cmp  al, 'T'
        je   .t
        jmp  .unknown
.p:                                   ; /PCIC or /P (pulse IREQ)
        mov  al, [si]
        and  al, 0DFh
        cmp  al, 'C'
        je   .pcic
        call swtail
        mov  byte [o_pulse], 1
        jmp  .loop
.pcic:
        call swtail
        mov  byte [o_mode], MODE_PCIC
        jmp  .loop
.c:                                   ; /CS or /C=hex
        mov  al, [si]
        and  al, 0DFh
        cmp  al, 'S'
        je   .cs
        call eat_eq
        call hexnum
        test dx, dx
        jz   .loop
        and  dl, 3Fh
        mov  [o_cfg], dl
        jmp  .loop
.cs:
        call swtail
        mov  byte [o_mode], MODE_CS
        jmp  .loop
.o:                                   ; /OB or /OFF
        mov  al, [si]
        and  al, 0DFh
        cmp  al, 'B'
        je   .ob
        cmp  al, 'F'
        je   .off
        jmp  .unknown
.ob:
        call swtail
        mov  byte [o_mode], MODE_OB
        jmp  .loop
.off:
        call swtail
        mov  byte [o_off], 1
        jmp  .loop
.s:                                   ; /SB=hex or /S=dec
        mov  al, [si]
        and  al, 0DFh
        cmp  al, 'B'
        je   .sb
        call eat_eq
        mov  al, [si]
        cmp  al, '0'
        jb   .loop
        cmp  al, '9'
        ja   .loop
        call decnum
        cmp  dx, 7
        ja   .loop
        mov  [o_sock], dl
        jmp  .loop
.sb:
        call eat_eq
        call hexnum
        test dx, dx
        jz   .loop
        mov  [o_sb], dx
        jmp  .loop
.f:                                   ; /FM[=hex] or /F[ORCE]
        mov  al, [si]
        and  al, 0DFh
        cmp  al, 'M'
        je   .fm
        call swtail
        mov  byte [o_force], 1
        jmp  .loop
.fm:
        mov  byte [o_fmon], 1
        call eat_eq
        call hexnum
        test dx, dx
        jz   .loop
        mov  [o_fm], dx
        jmp  .loop
.m:                                   ; /MPU[=hex]
        mov  byte [o_mpuon], 1
        call eat_eq
        call hexnum
        test dx, dx
        jz   .loop
        mov  [o_mpu], dx
        jmp  .loop
.n:                                   ; /NOFM or /NOMPU
        lodsb
        and  al, 0DFh
        cmp  al, 'O'
        jne  .unk2
        lodsb
        and  al, 0DFh
        cmp  al, 'F'
        je   .nofm
        cmp  al, 'M'
        je   .nompu
        jmp  .unk2
.nofm:
        call swtail
        mov  byte [o_nofm], 1
        jmp  .loop
.nompu:
        call swtail
        mov  byte [o_nompu], 1
        jmp  .loop
.j:                                   ; /JOY
        call swtail
        mov  byte [o_joyon], 1
        jmp  .loop
.i:                                   ; /I=dec
        call eat_eq
        mov  al, [si]
        cmp  al, '0'
        jb   .loop
        cmp  al, '9'
        ja   .loop
        call decnum
        cmp  dx, 15
        ja   .loop
        mov  al, dl
        mov  [o_irq], al
        jmp  .loop
.w:                                   ; /W=hex
        call eat_eq
        call hexnum
        test dx, dx
        jz   .loop
        mov  [o_wseg], dx
        mov  byte [o_wgiven], 1
        jmp  .loop
.g:                                   ; /G[PO]=hex (00 is a valid value)
        call eat_eq
        mov  al, [si]
        call ishex
        jc   .loop
        call hexnum
        mov  [o_gpoval], dl
        mov  byte [o_gpoov], 1
        jmp  .loop
.t:                                   ; /T[ONE]
        call swtail
        mov  byte [o_tone], 1
        jmp  .loop
.unk2:
        dec  si
.unknown:
        dec  si
        push si
        mov  si, m_ignsw
        call prstr
        pop  si
.uecho:
        lodsb                         ; echo the offending token
        cmp  al, 0Dh
        je   .uend
        cmp  al, ' '
        je   .unl
        call prchar
        jmp  .uecho
.unl:
        call crlf
        jmp  .loop
.uend:
        call crlf
        dec  si
        jmp  .loop

swtail:                               ; skip switch tail up to space/'/'/CR
        lodsb
        cmp  al, 0Dh
        je   .stop
        cmp  al, ' '
        je   .stop
        cmp  al, '/'
        je   .stop
        jmp  swtail
.stop:
        dec  si
        ret

eat_eq:                               ; skip rest of switch name + '='/':'
.e1:
        lodsb
        cmp  al, '='
        je   .r
        cmp  al, ':'
        je   .r
        and  al, 0DFh                 ; letters (e.g. the PU of /MPU): go on
        cmp  al, 'A'
        jb   .back
        cmp  al, 'Z'
        jbe  .e1
.back:
        dec  si
.r:
        ret

ishex:                                ; AL a hex digit?  CF clear = yes
        cmp  al, '0'
        jb   .no
        cmp  al, '9'
        jbe  .yes
        and  al, 0DFh
        cmp  al, 'A'
        jb   .no
        cmp  al, 'F'
        ja   .no
.yes:
        clc
        ret
.no:
        stc
        ret

decnum:                               ; parse decimal at DS:SI -> DX
        xor  dx, dx
.d1:
        lodsb
        cmp  al, '0'
        jb   .done
        cmp  al, '9'
        ja   .done
        sub  al, '0'
        xor  ah, ah
        push ax
        mov  ax, dx
        mov  dx, 10
        mul  dx                       ; AX = old total * 10 (DX clobbered)
        mov  dx, ax
        pop  ax
        add  dx, ax
        jmp  .d1
.done:
        dec  si
        ret

hexnum:                               ; parse hex at DS:SI -> DX (0 if none)
        xor  dx, dx
.h1:
        lodsb
        and  al, 0DFh                 ; upper-case (digits unharmed for cmp)
        cmp  al, 10h                  ; '0' & DF = 10h.. '9' & DF = 19h
        jb   .done
        cmp  al, 19h
        jbe  .dig
        cmp  al, 'A'
        jb   .done
        cmp  al, 'F'
        ja   .done
        sub  al, 'A' - 10
        jmp  .acc
.dig:
        sub  al, 10h
.acc:
        push cx
        mov  cl, 4
        shl  dx, cl
        pop  cx
        xor  ah, ah
        add  dx, ax
        jmp  .h1
.done:
        dec  si
        ret

;==========================================================================
;  SMALL HELPERS
;==========================================================================
ticks:                                ; wait CX BIOS ticks (~55 ms each)
        push ax
        push es
.t:
        mov  ax, 40h
        mov  es, ax
        mov  ax, [es:6Ch]
.same:
        cmp  ax, [es:6Ch]
        je   .same
        loop .t
        pop  es
        pop  ax
        ret

prhexadr:                             ; AX as 3 digits if <1000h else 4, +'h'
        cmp  ax, 0FFFh
        ja   .four
        call prhex3
        jmp  .h
.four:
        call prhex4
.h:
        mov  al, 'h'
        call prchar
        ret
prhex3:
        push ax
        mov  al, ah
        and  al, 0Fh
        call prnyb
        pop  ax
        push ax
        call prhex2
        pop  ax
        ret
prhex4:
        push ax
        mov  al, ah
        call prhex2
        pop  ax
prhex2:
        push ax
        push cx
        mov  cl, 4
        shr  al, cl
        call prnyb
        pop  cx
        pop  ax
        push ax
        call prnyb
        pop  ax
        ret
prnyb:
        push ax
        and  al, 0Fh
        add  al, '0'
        cmp  al, '9'
        jbe  .p
        add  al, 7
.p:
        call prchar
        pop  ax
        ret
prdec99:                              ; AL 0-99 decimal, no leading zero
        push ax
        aam                           ; AH = tens, AL = ones
        cmp  ah, 0
        je   .ones
        push ax
        mov  al, ah
        add  al, '0'
        call prchar
        pop  ax
.ones:
        add  al, '0'
        call prchar
        pop  ax
        ret
prdec2:                               ; AL 0-99, always two digits
        push ax
        push dx
        xor  ah, ah
        mov  dl, 10
        div  dl                       ; AL = tens, AH = ones
        push ax
        add  al, '0'
        call prchar
        pop  ax
        mov  al, ah
        add  al, '0'
        call prchar
        pop  dx
        pop  ax
        ret
prchar:
        push ax
        push dx
        mov  dl, al
        mov  ah, 2
        int  21h
        pop  dx
        pop  ax
        ret
prstr:                                ; ASCIIZ at SI
        push ax
.l:
        lodsb
        or   al, al
        jz   .r
        call prchar
        jmp  .l
.r:
        pop  ax
        ret
crlf:
        push si
        mov  si, m_crlf
        call prstr
        pop  si
        ret

errout:                               ; SI = message; print + exit
        call prstr
        int  20h

;==========================================================================
;  MESSAGES
;==========================================================================
m_banner:  db 'ES1688GO 1.2 - unified ES1688 PC Card enabler (PCIC/CS/OB)',13,10,0
m_hostcs:  db 'Host: PCMCIA Card Services',13,10,0
m_hostob:  db 'Host: Socket Services (OmniBook)',13,10,0
m_hostpc:  db 'Host: 82365-class PCIC (direct)',13,10,0
m_nomode:  db 'No supported PCMCIA host found (no Card Services, no Socket'
           db ' Services,',13,10,'no 82365 PCIC at 3E0h). Force a mode with'
           db ' /PCIC, /CS or /OB.',13,10,0
m_badmpu:  db 'Bad /MPU: must be 300/310/320/330.',13,10,0
m_badirq:  db 'Bad /I: IRQ must be 0..15.',13,10,0
m_fneeds:  db '/FORCE needs /S=n : name the socket to configure without'
           db ' the CIS check.',13,10,0
m_ignsw:   db 'Ignoring unknown switch: ',0
m_crlf:    db 13,10,0
m_novers:  db 'unreadable',0
; ---- summary block ----
m_forcedtag: db ' (FORCED)',0
m_sock1:   db ': socket ',0
m_auto:    db ' (auto)',0
m_dspv:    db '  DSP v',0
m_cis:     db '   CIS: ',0
m_manf1:   db '  (MANFID ',0
m_manf2:   db 'MANFID ',0
m_corat:   db '   COR @ ',0
m_index:   db ' index ',0
m_sb:      db '   SB ',0
m_fm:      db '  FM ',0
m_mpu:     db '  MPU ',0
m_joy:     db '  JOY 201',0
m_irq:     db '  IRQ ',0
m_query:   db '(?)',0
m_wins:    db '   I/O windows: ',0
m_win:     db 'win',0
m_comma:   db ', ',0
m_amp:     db '   amp-enable: GPO ',0
m_arrow:   db 'h <- ',0
m_ovr:     db ' (override)',0
m_test:    db '   TEST: OPL tone playing on SB-base FM',13,10,0
m_mpunote: db '   (MPU not confirmed - needs IRQ 5/7/9/10 and a 3x0 port)',13,10,0
m_nompu:   db '   Note: this card has no usable MPU-401 - MPU dropped.',13,10,0
m_nodsp:   db 'Card configured but SB DSP not answering at ',0
; ---- socket verdicts (PCIC + OB) ----
m_socket:  db 'Socket ',0
m_nocards: db ': no card present/ready.',13,10,0
m_indrive: db ': in use by the system (drive window) - refused.',13,10,0
m_unrec:   db ': unrecognized card - ',0
m_addman:  db '  Use /F, or add it to the manifest.',13,10,0
m_addman2: db '  Use /F /S=n, or add it to the manifest.',13,10,0
m_addman3: db '  Use /FORCE, or add it to the manifest.',13,10,0
m_noknown: db 'No known card in any socket. Use /F /S=n for an unreadable'
           db ' CIS.',13,10,0
m_noknown2: db 'No known card in any socket. Use /FORCE /S=n for an'
           db ' unreadable CIS.',13,10,0
m_nomatch: db 'No known card matched (last seen ',0
m_badcis:  db 'CIS invalid / config register base out of range',13,10,0
; ---- OB mode ----
m_noss:    db 'No PCMCIA Socket Services (INT 1A) on this machine.',13,10,0
m_sserr:   db 'Socket Services error AH=',0
m_corbad:  db 'COR readback mismatch: ',0
m_obbadsock: db 'Bad /S: OB sockets are 1..4.',13,10,0
m_obnooff: db '/OFF is not supported in OB mode.',13,10,0
m_note:    db 'Note: ',0
m_conflict: db ' - port range in use by another card',13,10,0
m_outwin:  db ' - out of I/O windows',13,10,0
m_sbfail:  db 'SB block unavailable',0
s_fm:      db 'FM skipped',0
s_mpu:     db 'MPU skipped',0
s_joy:     db 'JOY 201 skipped',0
; ---- PCIC mode ----
m_nopcic:  db 'No 82365-class PCIC found (scanned 3E0/3E2/3E4/3E6).',13,10,0
m_nochip1: db 'No PCIC controller for socket ',0
m_nochip2: db ' (port ',0
m_pcbadsock: db 'Bad /S: PCIC sockets are 0..7.',13,10,0
m_badsb:   db 'Bad /SB: base must be 200h..3D0h.',13,10,0
m_badfm:   db 'Bad /FM: port must be 200h..3DEh.',13,10,0
m_wclash:  db 'I/O window runs into the PCIC/COM1 area - adjust ports.',13,10,0
m_wovl:    db 'I/O windows overlap - adjust ports.',13,10,0
m_wbusy1:  db 'Probe window ',0
m_wbusy2:  db ' in use by another card; using ',0
m_nojoy:   db 'Note: no gameport at 201 on this card - JOY off (see'
           db ' CD20XGO).',13,10,0
m_offdone: db ' powered off.',13,10,0
; ---- CS mode ----
m_nocs:    db 'No PCMCIA Card Services (INT 1Ah AH=AFh not answered).',13,10
           db 'Load the CS stack (e.g. SystemSoft SS + CS.EXE) first.',13,10,0
m_cs:      db 'Card Services found, sockets: ',0
m_regfail: db 'RegisterClient failed, status ',0
m_reg:     db 'Registration complete event: ',0
m_regyes:  db 'yes',13,10,0
m_regno:   db 'NO (continuing anyway)',13,10,0
m_probe:   db 'Probing socket ',0
m_s_tup:   db '  no card / CIS unreadable, status ',0
m_s_wrong: db '  not a supported ES1688 card: MANFID ',0
m_s_io:    db '  RequestIO refused, status ',0
m_s_cfg:   db '  RequestConfiguration refused, status ',0
m_nocard:  db 'Card not enabled.',13,10,0
m_resident: db 'Staying resident - insert the card and it will be'
           db ' configured.',13,10,0
m_via:     db 'Reconfigured via the resident copy:',13,10,0
m_offok:   db 'Released - the resident copy is dormant (run again to'
           db ' re-enable).',13,10,0
m_vermsg:  db 'A different ES1688GO/CARDGO/CS1688GO version is resident -'
           db ' reboot to replace it.',13,10,0
m_offnone: db 'Nothing resident to switch off.',13,10,0
m_csnojoy: db 'Note: /JOY is not possible through Card Services (two I/O'
           db ' ranges only) - ignored.',13,10,0
m_csnoforce: db 'Note: /FORCE is not supported in CS mode - ignored.',13,10,0

;==========================================================================
;  TRANSIENT DATA
;==========================================================================
o_mode:    db 0                       ; 0 = auto-detect
o_fmon:    db 0                       ; /FM named
o_mpuon:   db 0                       ; /MPU named
o_joyon:   db 0                       ; /JOY named
o_nofm:    db 0
o_nompu:   db 0
o_wseg:    dw 0D000h                  ; attr probe window segment
o_wgiven:  db 0
sock:      db 0                       ; current socket (OB/PCIC)
sawunk:    db 0
failwhy:   db 0
gotcfg:    db 0
rep_sock:  db 0                       ; summary inputs
rep_irq:   db 0FFh
rep_cor:   db 0
corval:    db 0
any_chip:  db 0
wcount:    db 0                       ; mapped-window list for the summary
wnum:      db 0,0,0,0
wbase:     dw 0,0,0,0
wsize:     dw 0,0,0,0
; OB scratch
cw_i:      db 0
aw_i:      db 0
aw_base:   dw 0
aw_size:   dw 0
qstat:     db 0,0,0,0
qbase:     dw 0,0,0,0
qsize:     dw 0,0,0,0
gw_n:      db 0
w0_bl:     db 0
w0_cx:     dw 0
w0_dx:     dw 0
w0_si:     dw 0
w0_di:     dw 0
; PCIC scratch
pc_idx:    dw PCIC_BASE
pc_off:    db 0
p_w0s:     dw 0
p_w0e:     dw 0
p_w1s:     dw 0
p_w1e:     dw 0
p_have1:   db 0
p_wason:   db 0
p_s03:     db 0
p_s06:     db 0
p_s10:     db 0
p_s11:     db 0
p_s12:     db 0
p_s13:     db 0
p_s14:     db 0
p_s15:     db 0
pw_pg:     dw 0
pw_pg2:    dw 0
mw_seg:    dw 0
mw_cs:     dw 0
mw_ce:     dw 0
mw_sk:     db 0
mw_en:     db 0
mw_w:      db 0
mw_rb:     db 0
mw_ws:     dw 0
mw_we:     dw 0
; CS transient scratch
ibuf:      times 50h db 0
qcopy:     times 16 db 0
res_seg:   dw 0
res_off:   dw 0
fptr:      dd 0
hndoff:    db 0
res_badver: db 0
cisbuf:                               ; CISLEN dense CIS bytes (trailing BSS)
