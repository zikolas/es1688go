; SSCALL 1.0 -- raw INT 1A (PCMCIA Socket Services) probe call
; OB1688GO clean-room project (formerly ES425GO). Host interface per RBIL INT 1A AH=80h..90h
; (see doc/SS-SPEC-NOTES.md). No vendor code consulted.
;
; usage: SSCALL ax bx cx dx si di     (hex, up to 4 digits, missing args = 0)
; prints: CF, AX BX CX DX SI DI DS after the call, then 32 bytes read from
; DS:SI and DS:DI (for Inquire* calls returning characteristic tables).

        cpu  8086
        org  100h

start:  mov  si,0081h           ; PSP command tail
        mov  di,inregs
        mov  cx,6
.arg:   call parsehex
        jc   .go
        mov  [di],ax
        add  di,2
        loop .arg
.go:
        mov  ax,[inregs+0]
        mov  bx,[inregs+2]
        mov  cx,[inregs+4]
        mov  dx,[inregs+6]
        mov  si,[inregs+8]
        mov  di,[inregs+10]
        int  1ah
        pushf
        mov  [cs:r_ax],ax
        mov  [cs:r_bx],bx
        mov  [cs:r_cx],cx
        mov  [cs:r_dx],dx
        mov  [cs:r_si],si
        mov  [cs:r_di],di
        mov  [cs:r_ds],ds
        pop  ax
        mov  [cs:r_fl],ax
        push cs
        pop  ds

        mov  si,s_cf
        call prstr
        mov  ax,[r_fl]
        and  al,1
        call prnyb
        mov  si,s_ax
        call prstr
        mov  ax,[r_ax]
        call prhex4
        mov  si,s_bx
        call prstr
        mov  ax,[r_bx]
        call prhex4
        mov  si,s_cx
        call prstr
        mov  ax,[r_cx]
        call prhex4
        mov  si,s_dx
        call prstr
        mov  ax,[r_dx]
        call prhex4
        mov  si,s_si
        call prstr
        mov  ax,[r_si]
        call prhex4
        mov  si,s_di
        call prstr
        mov  ax,[r_di]
        call prhex4
        mov  si,s_ds
        call prstr
        mov  ax,[r_ds]
        call prhex4
        call crlf

        mov  si,t_si
        call prstr
        mov  si,[r_si]
        mov  ds,[cs:r_ds]
        call dump32
        push cs
        pop  ds
        call crlf

        mov  si,t_di
        call prstr
        mov  si,[r_di]
        mov  ds,[cs:r_ds]
        call dump32
        push cs
        pop  ds
        call crlf
        int  20h

; ---- parse one hex arg from DS:SI; AX=value CF=0, or CF=1 at end of tail
parsehex:
        xor  bx,bx
.skip:  lodsb
        cmp  al,0dh
        je   .none
        cmp  al,' '
        je   .skip
        cmp  al,9
        je   .skip
.dig:   call hexval
        jc   .done
        shl  bx,1
        shl  bx,1
        shl  bx,1
        shl  bx,1
        or   bl,al
        lodsb
        cmp  al,0dh
        je   .term
        jmp  .dig
.term:  dec  si
.done:  mov  ax,bx
        clc
        ret
.none:  dec  si
        stc
        ret

hexval: cmp  al,'0'
        jb   .no
        cmp  al,'9'
        jbe  .num
        and  al,0dfh
        cmp  al,'A'
        jb   .no
        cmp  al,'F'
        ja   .no
        sub  al,'A'-10
        clc
        ret
.num:   sub  al,'0'
        clc
        ret
.no:    stc
        ret

; ---- output helpers (AH=02h char writes; registers preserved where noted)
prhex4: push ax
        mov  al,ah
        call prhex2
        pop  ax
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
        push dx
        and  al,0fh
        add  al,'0'
        cmp  al,'9'
        jbe  .p
        add  al,7
.p:     mov  dl,al
        mov  ah,2
        int  21h
        pop  dx
        pop  ax
        ret

prstr:  lodsb
        or   al,al
        jz   .r
        push si
        mov  dl,al
        mov  ah,2
        int  21h
        pop  si
        jmp  prstr
.r:     ret

crlf:   push dx
        mov  dl,13
        mov  ah,2
        int  21h
        mov  dl,10
        mov  ah,2
        int  21h
        pop  dx
        ret

; dump 32 bytes from DS:SI as hex
dump32: mov  cx,32
.l:     lodsb
        call prhex2
        push ax
        push dx
        mov  dl,' '
        mov  ah,2
        int  21h
        pop  dx
        pop  ax
        loop .l
        ret

s_cf:   db 'CF=',0
s_ax:   db ' AX=',0
s_bx:   db ' BX=',0
s_cx:   db ' CX=',0
s_dx:   db ' DX=',0
s_si:   db ' SI=',0
s_di:   db ' DI=',0
s_ds:   db ' DS=',0
t_si:   db 'SI> ',0
t_di:   db 'DI> ',0

inregs: dw 0,0,0,0,0,0
r_ax:   dw 0
r_bx:   dw 0
r_cx:   dw 0
r_dx:   dw 0
r_si:   dw 0
r_di:   dw 0
r_ds:   dw 0
r_fl:   dw 0
