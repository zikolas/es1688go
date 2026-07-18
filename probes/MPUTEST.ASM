; MPUTEST -- why does the in-program MPU probe fail where a slow manual
; poke sees the FEh ACK?  Replicates CARDGO's exact chip-init tail at CPU
; speed (DSP C6h ext mode, mixer 40h rewrite with the routing value read
; off the live 530: DAh = IRQ7 + port 330 + OPL), then:
;   attempt 1: immediate 1.1-style probe (DRR wait w/ fallthrough, FFh,
;              DSR poll, read)          -> "swallowed first command"?
;   attempt 2: second FFh immediately   -> classic MPU-401 double-reset?
;   attempt 3: ~60 ms delay, then FFh   -> engine settle time?
; Prints the data byte + poll count (of 8000h) per attempt, or T=status
; on timeout.  CARDGO clean-room project, (C) 2026 zikolas, MIT.
        cpu  8086
        org  100h

SB      equ  220h
MPU     equ  330h

start:
        mov  si, m_hello
        call pr
        mov  dx, MPU+1                ; status before anything
        in   al, dx
        call phex2
        call crlf

        ; ---- full CARDGO chip-init preamble: DSP reset + E1 + unmute ----
        mov  dx, SB+6
        mov  al, 1
        out  dx, al
        mov  cx, 200
.rst:   loop .rst
        xor  al, al
        out  dx, al
        mov  bp, 4000
.rp:    mov  dx, SB+0Eh
        in   al, dx
        test al, 80h
        jnz  .ra
        dec  bp
        jnz  .rp
.ra:    mov  dx, SB+0Ah
        in   al, dx                   ; expect AA (not checked, printed)
        mov  si, m_rst
        call pr
        call phex2
        call crlf
        mov  al, 0E1h                 ; DSP version (read + discard 2 bytes)
        call dspcmd
        call dspget
        call dspget
        mov  al, 22h                  ; unmute master/FM/voice
        mov  ah, 0DDh
        call mixw
        mov  al, 26h
        mov  ah, 0DDh
        call mixw
        mov  al, 04h
        mov  ah, 0DDh
        call mixw

        mov  al, 0C6h                 ; ext mode
        call dspcmd
        mov  dx, SB+4                 ; mixer 40h <- DAh (as CARDGO wrote)
        mov  al, 40h
        out  dx, al
        call iod
        inc  dx
        mov  al, 0DAh
        out  dx, al
        call iod

        mov  si, m_a1
        call pr
        call probe1
        jnc  ok
        mov  si, m_a2
        call pr
        call probe1
        jnc  ok
        mov  cx, 60000                ; ~60 ms breather
        call iodn
        mov  si, m_a3
        call pr
        call probe1
        jnc  ok
        mov  si, m_fail
        call pr
        int  20h
ok:
        mov  si, m_ok
        call pr
        int  20h

; ---- one probe attempt, verbose.  CF clear = FEh seen. ------------------
probe1:
        mov  dx, MPU+1
        mov  bp, 2000h
.dw:    in   al, dx                   ; DRR wait (falls through on timeout)
        test al, 40h
        jz   .cmd
        dec  bp
        jnz  .dw
.cmd:   mov  al, 0FFh                 ; UART reset
        out  dx, al
        mov  bp, 8000h
.dr:    in   al, dx                   ; DSR poll
        test al, 80h
        jz   .rd
        dec  bp
        jnz  .dr
        mov  si, m_to                 ; timeout: T=last status
        call pr
        in   al, dx
        call phex2
        call crlf
        stc
        ret
.rd:    mov  dx, MPU
        in   al, dx
        push ax
        mov  si, m_d                  ; D=data byte
        call pr
        pop  ax
        push ax
        call phex2
        mov  si, m_p                  ; P=polls used
        call pr
        mov  ax, 8000h
        sub  ax, bp
        call phex4
        call crlf
        pop  ax
        mov  dx, MPU+1
        cmp  al, 0FEh
        jne  .dr2
        clc
        ret
.dr2:   dec  bp                      ; junk byte: keep draining
        jz   .bad
        jmp  .dr
.bad:   stc
        ret

; ---- helpers -------------------------------------------------------------
dspcmd:                               ; AL -> DSP write port (22Ch)
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

dspget:                               ; -> AL (FFh on timeout)
        push cx
        push dx
        mov  cx, 10000
.w:     mov  dx, SB+0Eh
        in   al, dx
        test al, 80h
        jnz  .rd
        loop .w
        mov  al, 0FFh
        jmp  .r
.rd:    mov  dx, SB+0Ah
        in   al, dx
.r:     pop  dx
        pop  cx
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

iodn:   push ax
.l:     in   al, 80h
        loop .l
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

m_hello: db 'MPUTEST: status before = ',0
m_rst:   db 'DSP reset -> ',0
m_a1:    db 'A1 immediate: ',0
m_a2:    db 'A2 second FF: ',0
m_a3:    db 'A3 after 60ms: ',0
m_to:    db 'T=',0
m_d:     db 'D=',0
m_p:     db ' P=',0
m_ok:    db 'ACK CONFIRMED',13,10,0
m_fail:  db 'NO ACK on any attempt',13,10,0
m_crlf:  db 13,10,0
