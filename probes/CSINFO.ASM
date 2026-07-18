;==========================================================================
;  CSINFO.COM - probe PCMCIA Card Services via the INT 1Ah DOS binding.
;
;  Calls GetCardServicesInfo (AH=AFh, AL=0Bh) and prints the returned
;  signature, socket count, revision, CS level and vendor string.
;  Read-only: registers nothing, configures nothing.
;
;  Binding (SystemSoft CardSoft technical guide, appendix B/D):
;    AH=AFh AL=function DX=handle DI:SI=Pointer CX=ArgLength ES:BX=ArgPointer
;    ret: CF=error, AX=status
;
;  Build (host):  nasm -f bin CSINFO.ASM -o CSINFO.COM
;==========================================================================
        cpu 8086
        org 100h

BUFLEN  equ 50h

start:
        mov  word [ibuf], BUFLEN      ; InfoLen in = buffer length
        mov  ax, cs
        mov  es, ax
        mov  bx, ibuf                 ; ES:BX = ArgPointer
        mov  cx, BUFLEN               ; ArgLength
        xor  dx, dx                   ; no handle
        xor  si, si                   ; no Pointer
        xor  di, di
        mov  ax, 0AF0Bh               ; GetCardServicesInfo
        int  1Ah
        jnc  .ok
        mov  dx, m_err
        call prstr
        call prax                     ; status code
        mov  dx, m_crlf
        call prstr
        mov  ax, 4C01h
        int  21h
.ok:
        ; signature: accept "CS" or "SC" byte order
        cmp  word [ibuf+2], 5343h     ; 'C','S' in memory
        je   .sigok
        cmp  word [ibuf+2], 4353h     ; 'S','C'
        je   .sigok
        mov  dx, m_nosig
        call prstr
        mov  ax, [ibuf+2]
        call prax
        mov  dx, m_crlf
        call prstr
        mov  ax, 4C02h
        int  21h
.sigok:
        mov  dx, m_sig
        call prstr
        mov  ax, [ibuf+4]             ; number of sockets
        call prax
        mov  dx, m_rev
        call prstr
        mov  ax, [ibuf+6]             ; revision (BCD)
        call prax
        mov  dx, m_lvl
        call prstr
        mov  ax, [ibuf+8]             ; CS level (BCD)
        call prax
        mov  dx, m_ven
        call prstr
        ; vendor string: offset word at +0Ah, length word at +0Ch
        mov  si, [ibuf+0Ah]
        add  si, ibuf
        mov  cx, [ibuf+0Ch]
        cmp  cx, 40h
        jbe  .vl
        mov  cx, 40h
.vl:
        jcxz .vdone
.vch:
        lodsb
        test al, al
        jz   .vdone
        mov  dl, al
        mov  ah, 2
        int  21h
        loop .vch
.vdone:
        mov  dx, m_crlf
        call prstr
        mov  ax, 4C00h
        int  21h

; ---- print AX as 4 hex digits -------------------------------------------
prax:
        push cx
        push dx
        mov  cx, 4
.dig:
        rol  ax, 1
        rol  ax, 1
        rol  ax, 1
        rol  ax, 1
        push ax
        and  al, 0Fh
        add  al, '0'
        cmp  al, '9'
        jbe  .out
        add  al, 7
.out:
        mov  dl, al
        mov  ah, 2
        int  21h
        pop  ax
        loop .dig
        pop  dx
        pop  cx
        ret

prstr:
        mov  ah, 9
        int  21h
        ret

m_err:   db 'Card Services call failed, status $'
m_nosig: db 'No CS signature (got $'
m_sig:   db 'Card Services OK.  Sockets: $'
m_rev:   db '  Revision: $'
m_lvl:   db '  CS level: $'
m_ven:   db 0Dh,0Ah,'Vendor: $'
m_crlf:  db 0Dh,0Ah,'$'

ibuf:    times BUFLEN db 0
