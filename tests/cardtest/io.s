;
; io.s -- card register access for cardtest.c
;
; Every card access is one absolute LDA or STA. The NMOS 6502 does a dummy
; read of the target before an indexed store (STA abs,X / STA (zp),Y), and a
; dummy read of a VDP data port or W5100 data register advances its address,
; so the C code never touches card registers through a pointer.
;
        .export _io_rd, _io_wr, _delay_ms
        .import popax

        .code

; unsigned char __fastcall__ io_rd (unsigned addr);
_io_rd: sta     rd+1
        stx     rd+2
rd:     lda     $FFFF
        ldx     #0
        rts

; void __fastcall__ io_wr (unsigned addr, unsigned char value);
_io_wr: pha
        jsr     popax
        sta     wr+1
        stx     wr+2
        pla
wr:     sta     $FFFF
        rts

; void __fastcall__ delay_ms (unsigned ms);  about 1 ms per count at 1.02 MHz
_delay_ms:
        sta     cnt
        stx     cnt+1
outer:  lda     cnt
        ora     cnt+1
        beq     done
        ldy     #198
inner:  dey                     ; 5 cycles a turn
        bne     inner
        lda     cnt
        bne     :+
        dec     cnt+1
:       dec     cnt
        jmp     outer
done:   rts

        .bss
cnt:    .res    2
