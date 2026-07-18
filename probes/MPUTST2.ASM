; MPUTST2 -- settle-time lab for the ES1688 MPU after a mixer-40h routing
; change (reproduces CARDGO's failing transition 03h -> DAh with no Card
; Services involvement).  First calibrates how many IN AL,80h reads fit in
; one BIOS tick (55 ms) so poll counts convert to real time.  Then: ext
; mode, 40h <- 03h (the plain-FM config = MPU routed away), ~1 s settle,
; 40h <- DAh (MPU to 330h, IRQ 7), and:
;   (default)  ONE FFh immediately, then poll DSR up to 8x65536 reads;
;              print the data byte + outer:inner poll position.
;              -> measures pure ACK latency; "no data" = command swallowed.
;   /S         spam: FFh every 25000 status polls, up to 40 sends; print
;              byte + send# when data appears.
;              -> do re-sends prevent (reset) or achieve the ACK?
;   /D         wait ~500 ms after the flip, then ONE FFh, short poll.
;              -> does silence-then-send win?
; CARDGO clean-room project, (C) 2026 zikolas, MIT.
        cpu  8086
        org  100h

SB      equ  220h
MPU     equ  330h

start:
        mov  si, 81h                  ; /S or /D
.p:     lodsb
        cmp  al, 0Dh
        je   .pd
        cmp  al, '/'
        jne  .p
        lodsb
        and  al, 0DFh
        cmp  al, 'S'
        jne  .p2
        mov  byte [mode], 1
        jmp  .p
.p2:    cmp  al, 'D'
        jne  .p
        mov  byte [mode], 2
        jmp  .p
.pd:
        ; ---- calibrate: IN AL,80h reads per BIOS tick --------------------
        call tickedge
        xor  dx, dx
.cal:   in   al, 80h
        inc  dx
        mov  ax, [es:6Ch]
        cmp  ax, [tick0]
        je   .cal
        mov  si, m_cal
        call pr
        mov  ax, dx
        call phex4
        call crlf

        ; ---- drain any stale MPU data ------------------------------------
        mov  cx, 8
.dr:    mov  dx, MPU+1
        in   al, dx
        test al, 80h
        jnz  .drok
        mov  dx, MPU
        in   al, dx
        loop .dr
.drok:
        ; ---- ext mode; routing away (03h); 1 s; routing to 330 (DAh) -----
        mov  al, 0C6h
        call dspcmd
        mov  al, 40h
        mov  ah, 03h
        call mixw
        mov  cx, 18
        call ticks
        mov  al, 40h
        mov  ah, 0DAh
        call mixw

        cmp  byte [mode], 1
        je   spamrun
        cmp  byte [mode], 2
        je   delayrun

        ; ---- single-shot: one FFh now, poll up to 8x65536 ----------------
        mov  dx, MPU+1
        mov  al, 0FFh
        out  dx, al
        xor  bx, bx                   ; outer
.o:     xor  bp, bp                   ; inner
.i:     in   al, dx
        test al, 80h
        jz   gotdata
        inc  bp
        jnz  .i
        inc  bx
        cmp  bx, 8
        jb   .o
        mov  si, m_none
        call pr
        int  20h

delayrun:
        mov  cx, 9                    ; ~500 ms of silence
        call ticks
        mov  dx, MPU+1
        mov  al, 0FFh
        out  dx, al
        xor  bx, bx
        xor  bp, bp
.dp:    in   al, dx
        test al, 80h
        jz   gotdata
        inc  bp
        jnz  .dp
        mov  si, m_none
        call pr
        int  20h

gotdata:
        mov  dx, MPU
        in   al, dx
        push ax
        mov  si, m_got
        call pr
        pop  ax
        call phex2
        mov  si, m_at
        call pr
        mov  ax, bx
        call phex4
        mov  al, ':'
        call pch
        mov  ax, bp
        call phex4
        call crlf
        int  20h

spamrun:
        xor  bx, bx                   ; send counter
.s:     mov  dx, MPU+1
        mov  al, 0FFh
        out  dx, al
        mov  bp, 25000
.sp:    in   al, dx
        test al, 80h
        jz   .sdata
        dec  bp
        jnz  .sp
        inc  bx
        cmp  bx, 40
        jb   .s
        mov  si, m_none
        call pr
        int  20h
.sdata:
        mov  dx, MPU
        in   al, dx
        push ax
        mov  si, m_got
        call pr
        pop  ax
        call phex2
        mov  si, m_snd
        call pr
        mov  ax, bx
        call phex4
        call crlf
        int  20h

; ---- helpers -------------------------------------------------------------
tickedge:                             ; wait for a tick edge; ES=40h
        push ax
        mov  ax, 40h
        mov  es, ax
        mov  ax, [es:6Ch]
.w:     cmp  ax, [es:6Ch]
        je   .w
        mov  ax, [es:6Ch]
        mov  [tick0], ax
        pop  ax
        ret

ticks:                                ; wait CX BIOS ticks
        push ax
        push es
.t:     mov  ax, 40h
        mov  es, ax
        mov  ax, [es:6Ch]
.same:  cmp  ax, [es:6Ch]
        je   .same
        loop .t
        pop  es
        pop  ax
        ret

dspcmd:                               ; AL -> DSP write port
        push ax
        push cx
        push dx
        mov  ah, al
        mov  dx, SB+0Ch
        mov  cx, 10000
.w:     in   al, dx
        test al, 80h
        jz   .go
        loop .w
.go:    mov  al, ah
        out  dx, al
        pop  dx
        pop  cx
        pop  ax
        ret

mixw:                                 ; index AL, value AH
        push dx
        mov  dx, SB+4
        out  dx, al
        call iod
        inc  dx
        mov  al, ah
        out  dx, al
        call iod
        pop  dx
        ret

iod:    push ax
        push cx
        mov  cx, 16
.l:     in   al, 80h
        loop .l
        pop  cx
        pop  ax
        ret

pr:     push ax
.l:     lodsb
        or   al, al
        jz   .r
        call pch
        jmp  .l
.r:     pop  ax
        ret
pch:    push ax
        push dx
        mov  dl, al
        mov  ah, 2
        int  21h
        pop  dx
        pop  ax
        ret
phex4:  push ax
        mov  al, ah
        call phex2
        pop  ax
phex2:  push ax
        push cx
        mov  cl, 4
        shr  al, cl
        call pnyb
        pop  cx
        pop  ax
        push ax
        call pnyb
        pop  ax
        ret
pnyb:   push ax
        and  al, 0Fh
        add  al, '0'
        cmp  al, '9'
        jbe  .p
        add  al, 7
.p:     call pch
        pop  ax
        ret
crlf:   push si
        mov  si, m_crlf
        call pr
        pop  si
        ret

mode:   db 0
tick0:  dw 0
m_cal:  db 'reads/tick = ',0
m_got:  db 'D=',0
m_at:   db ' at outer:inner ',0
m_snd:  db ' at send# ',0
m_none: db 'no data',13,10,0
m_crlf: db 13,10,0
