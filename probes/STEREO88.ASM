; ---------------------------------------------------------------------------
; STEREO88.COM -- bare-metal ES1688 8-bit STEREO probe (NASM -f bin, 8086)
;
; Purpose: found + validated the full ES1688 extended-mode PIO STEREO recipe
; (2026-07-29, REX-5571 on the TP235, two clean confirmed runs of v1.7):
;   1. B7 second write encodes channels: 8-bit stereo 98h (mono D0h),
;      16-bit stereo BCh (mono F4h) -- VSBPCM always wrote the mono values,
;      which is why the whole ES1688 fleet played mono (the DAC believes B7
;      over A8). Per ES1868 datasheet Table 11 + ALSA es1688_lib.c.
;   2. A1/A2 from the FRAME rate always (chip doubles byte consumption in
;      stereo itself; VSBPCM's byte-rate hack was compensating for mono-mode
;      and must be reverted with this fix or stereo runs 2x fast).
;   3. B9 = 01h for stereo (2-byte demand: FIFO unload becomes PAIR-ATOMIC =
;      deterministic first-byte-LEFT channel phase; without it the L/R
;      assignment is a per-stream coin flip). B9 = 00h for mono.
;      Bisected: v1.4 B9=1 deterministic+noisy, v1.5 B9=2 garbage,
;      v1.6 B9=0 clean+random, v1.7 B9=1+paced = CORRECT + CLEAN.
;   4. Stereo fills need ~1us settle after each L+R pair (two INs of port
;      80h) -- demand-2 consumes fills as request-shaped 2-byte groups and
;      hashes the second byte (right channel) when the next pair tailgates.
;   5. Also adopted: ESS reset 3h (bit1 = FIFO clear), B6 80h/00h per
;      unsigned/signed (Table 11), B2 = 10h (PIO: bits 7:5 low; the old
;      'B1/B2 must be 50h' lore is refuted for B2 -- bit4 is what matters),
;      prime 256 silence AFTER B8 run (B8 bit0 gates system->FIFO).
;
; Requires: card enabled at 220h first (ES1688GO). Run BARE -- no VSBPCM
; resident (the resident's pump owns the chip). Any key aborts.
; Register recipe mirrors sc_es1688.c es_pt_reconfig (field-proven mono
; bring-up) with only A8/B7 swapped per phase and B6=80h per ALSA.
; ---------------------------------------------------------------------------

        cpu 8086
        org 100h

BASE    equ 0220h
PRESET  equ BASE+06h            ; DSP reset
PRDATA  equ BASE+0Ah            ; DSP read data
PWSTAT  equ BASE+0Ch            ; DSP write-status/cmd; bit7 busy, bit3 FIFO-HE
PRSTAT  equ BASE+0Eh            ; DSP read-status; bit7 data ready
PFIFO   equ BASE+0Fh            ; extended-mode FIFO data port

A1_11K  equ 0B8h                ; 256 - round(795444/11025)  (high clock)
A2_11K  equ 0ECh                ; 256 - round(218293/11025)  (filter)
FIFO_HE equ 08h
TONE_HI equ 0B0h                ; ~501 Hz square: 11 frames high, 11 low
TONE_LO equ 050h
SILENCE equ 080h                ; unsigned silence (B7 bit5=0 in all configs)
HALF_P  equ 11                  ; half-period in frames
TIMEOUT equ 40                  ; BIOS ticks (~2.2s) with FIFO never half-empty

start:
        mov     dx, m_banner
        call    puts
        call    dsp_reset
        jnc     .dsp_ok
        mov     dx, m_nodsp
        call    puts
        int     20h
.dsp_ok:
        mov     si, phases
.phase: lodsw                   ; name ptr, 0 = table end
        or      ax, ax
        jz      .alldone
        mov     dx, ax
        call    puts
        lodsw                   ; AL = A8 value, AH = B7 second byte
        mov     [cur_a8], al
        mov     [cur_b7], ah
        lodsw                   ; AL = mode (0 mono, bit0 L on, bit1 R on)
        mov     [cur_mode], al  ; (AH spare)
        lodsw                   ; total bytes this phase
        mov     [remain], ax
        mov     byte [frame], 0
        mov     byte [parity], 0
        call    configure
        call    play
        pushf
        call    stop_chip
        popf
        jc      .aborted        ; key pressed or FIFO dead
        call    gap             ; ~0.4s of silence between phases
        jmp     .phase
.alldone:
        mov     dx, m_pass
        call    puts
        int     20h
.aborted:
        mov     dx, m_abort
        call    puts
        int     20h

; --- play: feed [remain] bytes of the phase pattern; CY set on abort -------
play:
.wait:  call    kbhit
        jc      .fail
        mov     dx, PWSTAT
        in      al, dx
        test    al, FIFO_HE
        jnz     .feed
        call    ticks
        cmp     ax, [t0]
        je      .wait           ; same tick, keep spinning
        mov     bx, ax
        sub     bx, [t0]
        cmp     bx, TIMEOUT
        jb      .wait
        mov     dx, m_dead      ; FIFO never went half-empty: DAC not draining
        call    puts
        stc
        ret
.feed:  call    ticks
        mov     [t0], ax        ; FIFO alive: reset the watchdog
        mov     cx, 128         ; burst <= half the 256-byte FIFO
        cmp     cx, [remain]
        jbe     .go
        mov     cx, [remain]
.go:    sub     [remain], cx
.gen:   mov     al, [cur_mode]
        or      al, al
        jz      .mono
        mov     ah, [parity]    ; stereo: even byte = LEFT, odd = RIGHT
        or      ah, ah
        jnz     .right
        test    byte [cur_mode], 1
        jmp     short .pick
.right: test    byte [cur_mode], 2
.pick:  jz      .mute
        call    tonebyte
        jmp     short .emit
.mute:  mov     al, SILENCE
.emit:  mov     dx, PFIFO
        out     dx, al
        mov     al, [parity]
        xor     al, 1
        mov     [parity], al
        or      al, al          ; parity wrapped to 0 = frame complete
        jnz     .next
        call    stepframe
        push    dx              ; ~1us settle after each L+R pair: demand-2
        mov     dx, 80h         ; consumes fills as 2-byte requests and hashes
        in      al, dx          ; the 2nd byte when the next pair tailgates
        in      al, dx
        pop     dx
        jmp     short .next
.mono:  call    tonebyte
        mov     dx, PFIFO
        out     dx, al
        call    stepframe
.next:  loop    .gen
        cmp     word [remain], 0
        jnz     .wait
        clc
        ret
.fail:  stc
        ret

tonebyte:                       ; AL = square sample for current frame
        mov     al, [frame]
        cmp     al, HALF_P
        mov     al, TONE_HI
        jb      .t
        mov     al, TONE_LO
.t:     ret

stepframe:
        push    ax
        mov     al, [frame]
        inc     al
        cmp     al, 2*HALF_P
        jb      .s
        xor     al, al
.s:     mov     [frame], al
        pop     ax
        ret

; --- configure: full bring-up for the current phase ------------------------
; mirrors es_pt_reconfig: reset, C6, B8=04, A8, A1, A2, A4/A5, B6, B7 pair,
; B1/B2=50h, prime 256 x silence, D1, B8=05.
configure:
        call    dsp_reset
        mov     al, 0C6h        ; extended mode
        call    dsp_cmd
        mov     ax, 04B8h       ; B8 <- 04  (auto-init)
        call    ewr
        mov     ah, [cur_a8]    ; A8 <- 12h mono / 11h stereo
        mov     al, 0A8h
        call    ewr
        ; B9: the bisected truth (v1.4/1.5/1.6) -- 01h (2-byte demand) makes the
        ; FIFO unload PAIR-ATOMIC = deterministic L/R, but needs paced fills
        ; (see play); 00h is clean but channel phase goes random; 02h = garbage.
        mov     ax, 00B9h       ; mono: single transfer (clean, no pairing needed)
        cmp     byte [cur_mode], 0
        je      .b9
        mov     ax, 01B9h       ; stereo: 2-byte demand = the channel aligner
.b9:    call    ewr
        mov     ax, A1_11K*256+0A1h
        call    ewr
        mov     ax, A2_11K*256+0A2h
        call    ewr
        mov     ax, 000A4h      ; A4 <- 00
        call    ewr
        mov     ax, 0FEA5h      ; A5 <- FEh (count reload -512)
        call    ewr
        mov     ax, 80B6h       ; B6 <- 80h (ALSA 8-bit value)
        call    ewr
        mov     ax, 51B7h       ; B7 first write
        call    ewr
        mov     ah, [cur_b7]    ; B7 second write: D0h mono / 98h stereo
        mov     al, 0B7h
        call    ewr
        mov     ax, 50B1h       ; IRQ+FIFO run enable (field-proven value)
        call    ewr
        mov     ax, 10B2h       ; B2: bit4 high ONLY -- datasheet PIO recipe
        call    ewr             ; wants bits 7:5 LOW (no DRQ/DACK cycles)
        mov     al, 0D1h        ; speaker on
        call    dsp_cmd
        mov     ax, 05B8h       ; run FIRST: B8 bit0 gates system->FIFO
        call    ewr
        mov     cx, 256         ; ...THEN prime (documented order)
        mov     dx, PFIFO
        mov     al, SILENCE
.pr:    out     dx, al
        loop    .pr
        call    ticks
        mov     [t0], ax
        ret

stop_chip:
        mov     ax, 00B8h       ; clear run bit
        call    ewr
        call    dsp_reset
        mov     al, 0D3h        ; speaker off
        call    dsp_cmd
        ret

; --- chip helpers -----------------------------------------------------------
ewr:                            ; AL = extended reg, AH = value
        push    ax
        call    dsp_cmd
        pop     ax
        mov     al, ah
        ; fall through
dsp_cmd:                        ; AL = byte for the DSP write port
        mov     ah, al
        mov     dx, PWSTAT
        mov     cx, 4000
.w:     in      al, dx
        test    al, 80h
        jz      .go
        loop    .w
        ret                     ; busy-timeout: swallow (matches driver)
.go:    mov     al, ah
        out     dx, al
        ret

dsp_reset:                      ; CY set if no 0AAh ack
        mov     dx, PRESET
        mov     al, 3           ; ESS reset: bit1 EXPLICITLY CLEARS THE FIFO
        out     dx, al          ; (datasheet + ALSA; plain SB writes 1 and the
                                ;  FIFO channel pointer inherits random residue)
        mov     cx, 120
        call    iodly
        mov     dx, PRESET
        xor     al, al
        out     dx, al
        mov     cx, 360
        call    iodly
        mov     dx, PRSTAT
        mov     cx, 4000
.w:     in      al, dx
        test    al, 80h
        jnz     .rd
        loop    .w
        stc
        ret
.rd:    mov     dx, PRDATA
        in      al, dx
        cmp     al, 0AAh
        jne     .bad
        clc
        ret
.bad:   stc
        ret

iodly:                          ; CX dummy reads of port 80h
        push    ax
        push    dx
        mov     dx, 80h
.d:     in      al, dx
        loop    .d
        pop     dx
        pop     ax
        ret

; --- host helpers -----------------------------------------------------------
puts:   push    ax
        mov     ah, 9
        int     21h
        pop     ax
        ret

kbhit:                          ; CY set (and key consumed) if a key waits
        mov     ah, 1
        int     16h
        jz      .no
        mov     ah, 0
        int     16h
        stc
        ret
.no:    clc
        ret

ticks:                          ; AX = BIOS tick counter low word
        push    es
        mov     ax, 0040h
        mov     es, ax
        mov     ax, [es:006Ch]
        pop     es
        ret

gap:                            ; ~0.4s silent pause between phases
        call    ticks
        mov     bx, ax
.g:     call    ticks
        sub     ax, bx
        cmp     ax, 8
        jb      .g
        ret

; --- data -------------------------------------------------------------------
; phase records: name ptr, (B7<<8)|A8, mode, total bytes; 0 terminates
; six alternating L/R phases, each a FULL fresh reconfig: one run shows
; whether the mixer-toggle makes channel phase deterministic across streams
phases:
        dw      m_p1, 0D012h, 0, 11025      ; mono ref: 1s
        dw      m_pL, 09811h, 1, 22050      ; stereo LEFT  1s
        dw      m_pR, 09811h, 2, 22050      ; stereo RIGHT 1s
        dw      m_pL, 09811h, 1, 22050
        dw      m_pR, 09811h, 2, 22050
        dw      m_pL, 09811h, 1, 22050
        dw      m_pR, 09811h, 2, 22050
        dw      m_p4, 09811h, 3, 22050      ; stereo BOTH  1s
        dw      0

cur_a8   db 0
cur_b7   db 0
cur_mode db 0
frame    db 0
parity   db 0
remain   dw 0
t0       dw 0

m_banner db 'STEREO88 1.8 - bare ES1688 8-bit stereo probe (base 220h, 11025 Hz)',13,10
         db 'Run AFTER ES1688GO, WITHOUT VSBPCM resident. Any key aborts.',13,10,'$'
m_nodsp  db 'No DSP ack (AAh) at 220h - is the card enabled? (run ES1688GO)',13,10,'$'
m_p1     db 13,10,'MONO reference (centre)',13,10,'$'
m_pL     db 'LEFT',13,10,'$'
m_pR     db 'RIGHT',13,10,'$'
m_p4     db 'BOTH (centre)',13,10,'$'
m_dead   db 'FIFO never went half-empty - DAC not draining (config rejected?)',13,10,'$'
m_abort  db 13,10,'Aborted.',13,10,'$'
m_pass   db 13,10,'Done. Validated recipe: B7=98h + FRAME-rate A1/A2 + B9=01h',13,10
         db '(pair demand) + paced pair fills + prime-after-run.',13,10
         db 'First FIFO byte = LEFT. See header for the full story.',13,10,'$'
