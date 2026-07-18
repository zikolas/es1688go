; CISDUMP 1.0 -- power a PCMCIA socket, reset, wait for READY, map an
; attribute-memory window and archive the CIS. OB1688GO clean-room project (formerly ES425GO).
; All Socket Services usage per doc/SS-SPEC-NOTES.md (RBIL INT 1A AH=80h..90h).
;
; usage: CISDUMP n [aa]
;   n  = socket number 1..4
;   aa = optional window-attribute byte for SetWindow DH (hex, default 07
;        = memory-mapped + attribute + enabled; try 0F to add 16-bit path)
;
; Refuses sockets mapped by an enabled common-memory window (OS drive
; mapping -- socket 4 on this machine; see doc/RECON-425.md). Card-status
; RDY/WP bits float high on unpowered sockets here and mean nothing.
; Sequence: SetSocket(Vcc idx 1 = 5V, Vpp 11h, memory IF) -> ~220ms ->
; ResetCard -> poll READY (max ~2.2s) -> SetWindow 0 @ D0000 16KB ->
; copy 512 raw bytes -> write CISn.BIN -> print first 64 CIS (even) bytes ->
; restore window 0 as found. Socket is left powered for follow-on probing.

        cpu  8086
        org  100h

start:  mov  si,0081h
        call skipsp
        cmp  al,0dh
        je   usage
        sub  al,'0'
        cmp  al,1
        jb   usage
        cmp  al,4
        ja   usage
        mov  [sock],al
        add  [fname+3],al       ; CIS0 -> CISn
        call skipsp
        cmp  al,0dh
        je   .noattr
        call hexbyte            ; AL = first hex digit already loaded
        mov  [wattr],al
.noattr:

; --- Socket Services present?
        mov  ax,8000h
        call ss_call
        jc   err_ss
        cmp  cx,5353h
        jne  err_nosss

; --- card status
        call getstat
        mov  si,m_stat
        call prstr
        call prhex2
        call crlf
        test al,80h
        jz   err_nocard
        call chk_drivewin
        jc   err_sys

; --- save window 0 state
        mov  ax,8800h
        xor  bx,bx
        call ss_call
        jc   err_ss
        mov  [w0_bl],bl
        mov  [w0_cx],cx
        mov  [w0_dx],dx
        mov  [w0_si],si
        mov  [w0_di],di

; --- power up: SetSocket mask C0, Vcc idx1 (5V), Vpp 11h, memory IF
        mov  ax,8E00h
        mov  bh,0C0h
        mov  bl,[sock]
        mov  cx,0111h
        xor  dx,dx
        mov  si,0001h
        xor  di,di
        call ss_call
        jc   err_ss
        mov  si,m_pwr
        call prstr

        mov  cx,4               ; ~220 ms Vcc settle
        call ticks

; --- reset, then poll for READY
        mov  ax,9000h
        mov  bl,[sock]
        xor  bh,bh
        call ss_call
        jc   err_ss

        mov  bp,40              ; ~2.2 s max
.rdy:   mov  cx,1
        call ticks
        call getstat
        test al,40h
        jnz  .isrdy
        dec  bp
        jnz  .rdy
        jmp  err_nordy
.isrdy: mov  si,m_rdy
        call prstr
        call prhex2
        call crlf

; --- map window 0: target socket, attribute mem, D0000, 16KB, 300ns
        mov  ax,8900h
        xor  bh,bh
        mov  bl,[sock]
        mov  cx,0004h
        mov  dh,[wattr]
        mov  dl,20h
        mov  si,00D0h
        xor  di,di
        call ss_call
        jc   err_ss
        mov  si,m_win
        call prstr

; --- copy 512 raw bytes from D000:0
        push ds
        push cs
        pop  es
        mov  ax,0D000h
        mov  ds,ax
        xor  si,si
        mov  di,buf
        mov  cx,512
        cld
        rep  movsb
        pop  ds

; --- write CISn.BIN
        mov  ah,3Ch
        xor  cx,cx
        mov  dx,fname
        int  21h
        jc   err_file
        mov  bx,ax
        mov  ah,40h
        mov  cx,512
        mov  dx,buf
        int  21h
        mov  ah,3Eh
        int  21h
        mov  si,m_file
        call prstr

; --- print first 64 even (CIS) bytes
        xor  bx,bx
.pr:    mov  al,[buf+bx]
        call prhex2
        mov  al,' '
        call prchar
        add  bx,2
        test bl,15
        jnz  .nonl
        call crlf
.nonl:  cmp  bx,128
        jb   .pr

; --- restore window 0 (set bit0: memory window; readback bit0 unreliable)
        mov  ax,8900h
        xor  bh,bh
        mov  bl,[w0_bl]
        mov  cx,[w0_cx]
        mov  dx,[w0_dx]
        or   dh,01h
        mov  si,[w0_si]
        mov  di,[w0_di]
        call ss_call
        mov  si,m_done
        call prstr
        int  20h

; ---------------- helpers ----------------
; refuse the target socket if an enabled COMMON-memory window (1-3) maps it:
; that is the probed signature of an OS drive mapping on this machine
; (doc/RECON-425.md). Attribute-mode window 0 is a probe window, not a drive.
chk_drivewin:
        mov  byte [gw_n],1
.w:     mov  ax,8800h
        mov  bh,[gw_n]
        call ss_call
        jc   .next
        cmp  bl,[sock]
        jne  .next
        test dh,04h             ; enabled?
        jz   .next
        test dh,02h             ; attribute mode -> not a drive map
        jnz  .next
        stc
        ret
.next:  inc  byte [gw_n]
        cmp  byte [gw_n],3
        jbe  .w
        clc
        ret
gw_n:   db 0

ss_call:                        ; INT 1A preserving DS/ES/BP
        push ds
        push es
        push bp
        int  1ah
        pop  bp
        pop  es
        pop  ds
        ret

getstat:                        ; card status socket [sock] -> AL
        mov  ax,8F00h
        xor  bh,bh
        mov  bl,[sock]
        call ss_call
        jc   err_ss
        mov  al,dl
        ret

ticks:                          ; wait CX BIOS ticks (~55ms each)
.t:     push cx
        push es
        mov  ax,40h
        mov  es,ax
        mov  ax,[es:6Ch]
.same:  cmp  ax,[es:6Ch]
        je   .same
        pop  es
        pop  cx
        loop .t
        ret

skipsp: lodsb                   ; skip blanks; AL=first non-blank (may be 0Dh)
        cmp  al,' '
        je   skipsp
        cmp  al,9
        je   skipsp
        ret

hexbyte:                        ; AL=first hex char, DS:SI more -> AL=byte
        call nyb
        mov  ah,al
        lodsb
        call nyb
        jc   .one
        push cx
        mov  cl,4
        shl  ah,cl
        pop  cx
        or   al,ah
        ret
.one:   mov  al,ah
        ret
nyb:    cmp  al,'0'
        jb   .no
        cmp  al,'9'
        jbe  .n
        and  al,0DFh
        cmp  al,'A'
        jb   .no
        cmp  al,'F'
        ja   .no
        sub  al,'A'-10
        clc
        ret
.n:     sub  al,'0'
        clc
        ret
.no:    stc
        ret

prhex2: push ax
        push cx
        mov  cl,4
        shr  al,cl
        call prnyb
        pop  cx
        pop  ax
        push ax
        call prnyb
        pop  ax
        ret
prnyb:  push ax
        and  al,0Fh
        add  al,'0'
        cmp  al,'9'
        jbe  .p
        add  al,7
.p:     call prchar
        pop  ax
        ret
prchar: push ax
        push dx
        mov  dl,al
        mov  ah,2
        int  21h
        pop  dx
        pop  ax
        ret
prstr:  push ax
.l:     lodsb
        or   al,al
        jz   .r
        call prchar
        jmp  .l
.r:     pop  ax
        ret
crlf:   push si
        mov  si,m_crlf
        call prstr
        pop  si
        ret

usage:  mov  si,m_use
        call prstr
        int  20h
err_nosss:
        mov  si,m_noss
        call prstr
        int  20h
err_nocard:
        mov  si,m_nocd
        call prstr
        int  20h
err_sys:
        mov  si,m_sys
        call prstr
        int  20h
err_nordy:
        mov  si,m_nrdy
        call prstr
        call prhex2
        call crlf
        int  20h
err_ss: pushf
        mov  al,ah
        mov  si,m_sserr
        call prstr
        call prhex2
        call crlf
        popf
        int  20h
err_file:
        mov  si,m_ferr
        call prstr
        int  20h

m_use:  db 'usage: CISDUMP socket(1-4) [attrhex]',13,10,0
m_noss: db 'no Socket Services',13,10,0
m_nocd: db 'no card in socket',13,10,0
m_sys:  db 'refusing socket with active drive window',13,10,0
m_nrdy: db 'card never came READY, status=',0
m_sserr:db 'SS error AH=',0
m_ferr: db 'file write failed',13,10,0
m_stat: db 'status=',0
m_pwr:  db 'power on (5V), settling',13,10,0
m_rdy:  db 'READY, status=',0
m_win:  db 'window 0 -> attr mem @ D0000',13,10,0
m_file: db 'wrote 512 bytes',13,10,0
m_done: db 13,10,'window 0 restored, socket left powered',13,10,0
m_crlf: db 13,10,0

sock:   db 3
wattr:  db 07h
w0_bl:  db 0
w0_cx:  dw 0
w0_dx:  dw 0
w0_si:  dw 0
w0_di:  dw 0
fname:  db 'CIS0.BIN',0
buf:
