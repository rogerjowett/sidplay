; SID Player v1.1, by Simon Owen
;
; WWW: http://simonowen.com/sam/sidplay/
;
; Emulates a 6510 CPU to play most C64 SID tunes in real time.
; Requires Quazar SID interface board (see www.quazar.clara.net)
;
; Load PSID file at &10000 and call &d000 to play
; POKE &d002,tune-number (default=0, for SID default)
; POKE &d003,key-mask (binary: 0,0,Esc,Right,Left,Down,Up,Space)
; DPOKE &d004,pre-buffer-frames (default=25, for 0.5 seconds)
;
; Features:
;   - Full 6510 emulation in Z80
;   - PAL (50Hz), NTSC (60Hz) and 100Hz playback speeds
;   - Support PSID files up to 64K
;   - Both polled and timer-driven players
;
; RSID files and sound samples are not supported.

base:          equ  &d000           ; Player based at 53248

buffer_blocks: equ  25              ; number of frames to pre-buffer
buffer_low:    equ  10              ; low limit before screen disable

status:        equ  249             ; Status port for active interrupts (input)
line:          equ  249             ; Line interrupt (output)
lmpr:          equ  250             ; Low Memory Page Register
hmpr:          equ  251             ; High Memory Page Register
midi:          equ  253             ; MIDI port
border:        equ  254             ; Bits 5 and 3-0 hold border colour (output)
keyboard:      equ  254             ; Main keyboard matrix (input)
rom0_off:      equ  %00100000       ; LMPR bit to disable ROM0

low_page:      equ  3               ; LMPR during emulation
high_page:     equ  5               ; HMPR during emulation
buffer_page:   equ  7               ; base page for SID buffering

ret_ok:        equ  0               ; no error (space to exit)
ret_space:     equ  ret_ok          ; space
ret_up:        equ  1               ; cursor up
ret_down:      equ  2               ; cursor down
ret_left:      equ  3               ; cursor left
ret_right:     equ  4               ; cursor right
ret_esc:       equ  5               ; esc
ret_badfile:   equ  6               ; missing or invalid file
ret_rsid:      equ  7               ; RSID files unsupported
ret_timer:     equ  8               ; unsupported timer frequency
ret_brk:       equ  9               ; BRK unsupported

m6502_nmi:     equ  &fffa           ; nmi vector address
m6502_reset:   equ  &fffc           ; reset vector address
m6502_int:     equ  &fffe           ; int vector address (also for BRK)

c64_irq_vec:   equ  &0314           ; C64 IRQ vector
c64_irq_cont:  equ  &ea31           ; C64 ROM IRQ chaining
c64_cia_timer: equ  &dc04           ; C64 CIA#1 timer

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

               org  base
               dump $
               autoexec             ; set the code file as auto-executing

               jr   start

song:          defb 0               ; 0=default song from SID header
key_mask:      defb %00000000       ; exit keys to ignore
pre_buffer:    defw buffer_blocks   ; pre-buffer 1 second

start:         di

               ld   (old_stack+1),sp
               ld   sp,new_stack

               ld   a,low_page+rom0_off
               out  (lmpr),a        ; page in tune

               ld   hl,0            ; SID file header
               ld   a,(hl)
               cp   "R"             ; RSID signature?
               ld   c,ret_rsid
               jp   z,exit_player
               cp   "P"             ; new PSID signature?
               jr   nz,old_file

               ld   de,sid_header
               ld   bc,22
               ldir                 ; copy header to master copy
old_file:      ex   af,af'          ; save Z flag for new file

               ld   ix,sid_header
               ld   a,(ix)
               cp   "P"
               ld   c,ret_badfile
               jp   nz,exit_player

               ld   a,high_page+rom0_off
               out  (lmpr),a

               ld   hl,&d000
               ld   de,&d000-&8000
               ld   bc,&1000
               ldir                 ; copy player

               ld   a,low_page+rom0_off
               out  (lmpr),a        ; page tune back in
               ld   a,high_page
               out  (hmpr),a        ; activate player copy

               ld   h,(ix+10)       ; init address
               ld   l,(ix+11)
               ld   (init_addr),hl
               ld   h,(ix+12)       ; play address
               ld   l,(ix+13)
               ld   (play_addr),hl

               ld   h,(ix+6)        ; data offset (big-endian)
               ld   l,(ix+7)
               ld   d,(ix+8)        ; load address (or zero)
               ld   e,(ix+9)

               ld   a,d
               or   e
               jr   nz,got_load     ; jump if address valid
               ld   e,(hl)          ; take address from start of data
               inc  l               ; (already little endian)
               ld   d,(hl)
               inc  l
got_load:

               ex   af,af'
               jr   nz,no_reloc

; At this point we have:  HL=sid_data DE=load_addr

               ld   b,h
               ld   c,l
               ld   hl,&ffff
               and  a
               sbc  hl,de
               add  hl,bc
               ld   de,&ffff
               ld   bc,&2000
               lddr                 ; relocate e000-ffff
               ld   bc,-&1000
               add  hl,bc
               ex   de,hl
               add  hl,bc
               ex   de,hl
               ld   bc,&d000
               lddr                 ; relocate 0000-cfff
no_reloc:
               ld   h,0
               ld   l,h
clear_zp:      ld   (hl),h
               inc  l
               jr   nz,clear_zp

               ld   b,(ix+15)       ; songs available
               ld   c,(ix+17)       ; default start song
               ld   a,(song)        ; user requested song
               and  a               ; zero?
               jr   z,use_default   ; use default if so
               inc  b               ; max+1
               cp   b               ; song in range?
               jr   c,got_song      ; use if it is
use_default:   ld   a,c
got_song:      ld   (play_song),a   ; save song to play

               ld   hl,sid_header+21  ; end of speed bit array
speed_lp:      ld   c,1             ; start with bit 0
speed_lp2:     dec  a
               jr   z,got_speed
               rl   c               ; shift up bit to check
               jr   nc,speed_lp2
               dec  hl
               jr   speed_lp
got_speed:     ld   a,(hl)
               and  c
               ld   (ntsc_tune),a

               call play_tune
               ld   c,a
               exx

               di
               im   1
               call sid_reset

               exx
exit_player:   ld   b,0

               ld   a,31
               out  (lmpr),a
               ld   a,1
               out  (hmpr),a
               xor  a
               out  (border),a
old_stack:     ld   sp,0
               ei
               ret

sid_header:    defs 22              ; copy of start of SID header

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

; Tune player

play_tune:     ld   hl,0
               ld   (blocks),hl     ; no buffered blocks
               ld   (head),hl       ; head/tail at buffer start
               ld   (tail),hl
               ld   (c64_cia_timer),hl  ; no timer frequency
               ld   (c64_irq_vec),hl    ; no irq handler for timer

               call reorder_decode  ; optimise decode table

               ld   a,(play_song)   ; song to play
               dec  a               ; player expects A=song-1
               ld   hl,(init_addr)  ; tune init function
               call execute         ; initialise player
               and  a
               ret  nz              ; return any error

               call sid_reset       ; reset the SID
               call record_block    ; record initial SID state

               ld   hl,(play_addr)  ; tune player poll address
               ld   a,h
               or   l
               jr   nz,buffer_loop  ; non-zero means we have one

               ld   hl,(c64_irq_vec); use custom handler
               ld   a,&40           ; rti 6502 opcode
               ld   (c64_irq_cont),a ; no ROM IRQ continuation
               ld   (play_addr),hl  ; store play address

buffer_loop:   ld   hl,(blocks)     ; current block count
               ld   de,(pre_buffer) ; blocks to pre-buffer
               and  a
               sbc  hl,de
               jr   nc,buffer_done

               xor  a
               ld   hl,(play_addr)  ; poll or interrupt addr
               call execute
               and  a
               ret  nz              ; return any errors

               call record_block    ; record the state
               jr   buffer_loop     ; loop buffering more

buffer_done:   call set_speed       ; set player speed
               call enable_player   ; enable interrupt-driven player

sleep_loop:    halt                 ; wait for a block to play

play_loop:     ld   a,(key_mask)    ; keys to ignore
               ld   b,a

               ld   a,&f7
               in   a,(status)      ; read extended keys
               or   b
               and  %00100000       ; check Esc
               ld   a,ret_esc
               ret  z               ; exit if pressed

               ld   a,&7f           ; bottom row
               in   a,(keyboard)    ; read keyboard
               or   b
               rra                  ; check Space
               ld   a,ret_space
               ret  nc              ; exit if space pressed

               ld   a,&ff           ; cursor keys + cntrl
               in   a,(keyboard)
               or   b               ; mask keys to ignore
               rra                  ; key bit 0 (cntrl)
               rra                  ; key bit 1 (up)
               ld   c,a
               ld   a,ret_up
               ret  nc              ; return if pressed
               inc  a
               rr   c               ; key bit 2 (down)
               ret  nc              ; return if pressed
               inc  a
               rr   c               ; key bit 3 (left)
               ret  nc              ; return if pressed
               inc  a
               rr   c               ; key bit 3 (right)
               ret  nc              ; return if pressed

               ld   a,&f7
               in   a,(keyboard)
               rra
               ld   c,a
               call nc,set_100hz
               bit  3,c
               call z,set_50hz
               ld   a,&ef
               in   a,(keyboard)
               bit  4,a
               call z,set_60hz

               ld   hl,(blocks)     ; check buffered blocks
               ld   de,32768/32-1   ; maximum we can buffer
               and  a
               sbc  hl,de
               jr   nc,sleep_loop   ; jump back to wait if full

               xor  a
               ld   hl,(play_addr)
               call execute         ; execute 1 frame
               and  a               ; execution error?
               ret  nz              ; return if so

               call record_block    ; record the new SID state
               jp   play_loop       ; generate more data

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

; Interrupt handling

gap1:          equ  &d200-$         ; error if previous code is
               defs gap1            ; too big for available gap!

im2_table:     defs 257             ; 256 overlapped WORDs

im2_handler:   push af
               in   a,(status)      ; read status to check interrupts
               rra
               jr   nc,line_int
               bit  3,a
               jr   z,midi_int
               bit  2,a
               jr   nz,int_exit

frame_int:     ld   a,(line_num)
               and  a               ; zero?
               jr   z,int_hit       ; frame int only for 50Hz
               cp   step5_60Hz      ; 2nd step in border for 60Hz
               jr   z,midi_start
line_start:    cp   0               ; (self-modified value)
               jr   z,line_set
line_end:      cp   0               ; (self-modified value)
               jr   nz,int_exit     ; skip frame interrupt
               ld   a,(line_start+1); first step
               jr   line_set        ; loop interrupt sequence

line_int:      ld   a,(line_num)
line_step1:    sub  0               ; (self-modified value)
line_set:      out  (line),a
               ld   (line_num),a

int_hit:       in   a,(lmpr)
               push af
               ld   a,buffer_page+rom0_off
               out  (lmpr),a
               push bc
               push de
               push hl
               call play_block
               pop  hl
               pop  de
               pop  bc
               pop  af
               out  (lmpr),a
int_exit:      pop  af
               ei
               reti

midi_start:
line_step2:    sub  0               ; adjust line for next step
               ld   (line_num),a
               ld   a,10
               jr   midi_next       ; assumes NZ from sub above
midi_int:      ld   a,0
               dec  a
midi_next:     ld   (midi_int+1),a
               jr   z,int_hit
               out  (midi),a
               jr   int_exit

line_num:      defb 0


gap2:          equ  &d400-$         ; error if previous code is
               defs gap2            ; too big for available gap!

; C64 SID register go here, followed by a second set recording changes
sid_regs:      defs 32
sid_changes:   defs 32
prev_regs:     defs 32
last_regs:     defs 32              ; last values written to SID

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

; 6510 emulation

execute:       ex   de,hl           ; PC stays in DE throughout
               ld   b,a             ; set A from Z80 accumulator
               xor  a
               ld   iy,0            ; X=0 and Y=0
               exx
               ld   hl,&01ff        ; 6502 stack pointer in HL'
               ld   d,%00000100     ; interrupts disabled
               ld   b,a             ; clear V
               ld   c,a             ; clear C
               exx
               ld   c,a             ; set Z
               ex   af,af'          ; clear N

read_write_loop:
write_loop:    ld   a,h
               cp   &d4             ; SID based at &d400
               jr   z,sid_write
zwrite_loop:
zread_write_loop:
zread_loop:
read_loop:
main_loop:     ld   a,(de)          ; fetch opcode
               inc  de              ; PC=PC+1
               ld   l,a
               ld   h,decode_table/256
               ld   a,(hl)          ; handler low
               inc  h
               ld   h,(hl)          ; handler high
               ld   l,a
               jp   (hl)            ; execute!

sid_write:     ld   a,(hl)
               set  6,l
               xor  (hl)
               jr   z,main_loop
               res  6,l
               set  5,l
               or   (hl)
               ld   (hl),a
               res  5,l
               ld   a,(hl)
               set  6,l
               ld   (hl),a
               jp   main_loop


; 6502 addressing modes, shared by logical and arithmetic
; instructions, but inlined into the load and store.

a_indirect_x:  ld   a,(de)          ; indirect pre-indexed with X
               inc  de
               add  a,iyh           ; add X (may wrap in zero page)
               ld   l,a
               ld   h,0
               ld   a,(hl)
               inc  hl
               ld   h,(hl)
               ld   l,a
               jp   (ix)

a_zero_page:   ld   a,(de)          ; zero-page
               inc  de
               ld   l,a
               ld   h,0
               jp   (ix)

a_absolute:    ex   de,hl           ; absolute (2-bytes)
               ld   e,(hl)
               inc  hl
               ld   d,(hl)
               inc  hl
               ex   de,hl
               jp   (ix)

a_indirect_y:  ld   a,(de)          ; indirect post-indexed with Y
               inc  de
               ld   l,a
               ld   h,0
               ld   a,iyl           ; Y
               add  a,(hl)
               inc  l               ; (may wrap in zero page)
               ld   h,(hl)
               ld   l,a
               ld   a,0
               adc  a,h
               ld   h,a
               jp   (ix)

a_zero_page_x: ld   a,(de)          ; zero-page indexed with X
               inc  de
               add  a,iyh           ; add X (may wrap in zero page)
               ld   l,a
               ld   h,0
               jp   (ix)

a_zero_page_y: ld   a,(de)          ; zero-page indexed with Y
               inc  de
               add  a,iyl           ; add Y (may wrap in zero page)
               ld   l,a
               ld   h,0
               jp   (ix)

a_absolute_y:  ex   de,hl           ; absolute indexed with Y
               ld   a,iyl           ; Y
               add  a,(hl)
               ld   e,a
               inc  hl
               ld   a,0
               adc  a,(hl)
               ld   d,a
               inc  hl
               ex   de,hl
               jp   (ix)

a_absolute_x:  ex   de,hl           ; absolute indexed with X
               ld   a,iyh           ; X
               add  a,(hl)
               ld   e,a
               inc  hl
               ld   a,0
               adc  a,(hl)
               ld   d,a
               inc  hl
               ex   de,hl
               jp   (ix)


; Instruction implementations

i_nop:         equ  main_loop
i_undoc_1:     equ  main_loop
i_undoc_3:     inc  de              ; 3-byte NOP
i_undoc_2:     inc  de              ; 2-byte NOP
               jp   main_loop

i_clc:         exx                  ; clear carry
               ld   c,0
               exx
               jp   main_loop
i_sec:         exx                  ; set carry
               ld   c,1
               exx
               jp   main_loop
i_cli:         exx                  ; clear interrupt disable
               res  2,d
               exx
               jp   main_loop
i_sei:         exx                  ; set interrupt disable
               set  2,d
               exx
               jp   main_loop
i_clv:         exx                  ; clear overflow
               ld   b,0
               exx
               jp   main_loop
i_cld:         exx                  ; clear decimal mode
               res  3,d
               exx
               xor  a               ; NOP
               ld   (adc_daa),a     ; use binary mode for adc
               ld   (sbc_daa),a     ; use binary mode for sbc
               jp   main_loop
i_sed:         exx
               set  3,d
               exx
               ld   a,&27           ; DAA
               ld   (adc_daa),a     ; use decimal mode for adc
               ld   (sbc_daa),a     ; use decimal mode for sbc
               jp   main_loop

i_bpl:         ld   a,(de)
               inc  de
               ex   af,af'
               ld   l,a             ; copy N
               ex   af,af'
               bit  7,l             ; test N
               jr   z,i_branch      ; branch if plus
               jp   main_loop
i_bmi:         ld   a,(de)
               inc  de
               ex   af,af'
               ld   l,a             ; copy N
               ex   af,af'
               bit  7,l             ; test N
               jr   nz,i_branch     ; branch if minus
               jp   main_loop
i_bvc:         ld   a,(de)          ; V in bit 6
               inc  de              ; V set if non-zero
               exx
               bit  6,b
               exx
               jr   z,i_branch      ; branch if V clear
               jp   main_loop
i_bvs:         ld   a,(de)          ; V in bit 6
               inc  de
               exx
               bit  6,b
               exx
               jr   nz,i_branch     ; branch if V set
               jp   main_loop
i_bcc:         ld   a,(de)          ; C in bit 1
               inc  de
               exx
               bit  0,c
               exx
               jr   z,i_branch      ; branch if C clear
               jp   main_loop
i_bcs:         ld   a,(de)
               inc  de
               exx
               bit  0,c
               exx
               jr   nz,i_branch     ; branch if C set
               jp   main_loop
i_beq:         ld   a,(de)
               inc  de
               inc  c
               dec  c               ; zero?
               jr   z,i_branch      ; branch if zero
               jp   main_loop
i_bne:         ld   a,(de)
               inc  de
               inc  c
               dec  c               ; zero?
               jp   z,main_loop     ; no branch if not zero
i_branch:      ld   l,a             ; offset low
               rla                  ; set carry with sign
               sbc  a,a             ; form high byte for offset
               ld   h,a
               add  hl,de           ; PC=PC+e
               ex   de,hl
               jp   main_loop

i_jmp_a:       ex   de,hl           ; JMP nn
               ld   e,(hl)
               inc  hl
               ld   d,(hl)
               inc  hl
               jp   main_loop

i_jmp_i:       ex   de,hl           ; JMP (nn)
               ld   e,(hl)
               inc  hl
               ld   d,(hl)
               inc  hl
               ex   de,hl
               ld   e,(hl)
               inc  l               ; 6502 bug wraps within page, *OR*
;              inc  hl              ; 65C02 spans pages correctly
               ld   d,(hl)
               jp   main_loop

i_jsr:         ex   de,hl           ; JSR nn
               ld   e,(hl)          ; subroutine low
               inc  hl              ; only 1 inc - we push ret-1
               ld   d,(hl)          ; subroutine high
               ld   a,h             ; PCh
               exx
               ld   (hl),a          ; push ret-1 high byte
               dec  l               ; S--
               exx
               ld   a,l             ; PCl
               exx
               ld   (hl),a          ; push ret-1 low byte
               dec  l               ; S--
               exx
               jp   main_loop

i_brk:         ld   a,ret_brk
               ret
               inc  de              ; return to BRK+2
               ld   a,d
               exx
               ld   (hl),a          ; push return MSB
               dec  l               ; S--
               exx
               ld   a,e
               exx
               ld   (hl),a          ; push return LSB
               dec  l               ; S--
               ld   a,d
               or   %00010000       ; set B flag (temp)
               ld   (hl),a          ; push flags with B set
               dec  l               ; S--
               set  2,d             ; set I flag
               exx
               ld   de,(m6502_int)  ; fetch interrupt handler
               jp   main_loop

i_rts:         exx                  ; RTS
               inc  l               ; S++
               ld   a,ret_ok
               ret  z               ; finish if stack empty
               ld   a,(hl)          ; PC LSB
               exx
               ld   e,a
               exx
               inc  l               ; S++
               ld   a,(hl)          ; PC MSB
               exx
               ld   d,a
               inc  de              ; PC++ (strange but true)
               jp   main_loop

i_rti:         exx                  ; RTI
               inc  l               ; S++
               ld   a,ret_ok
               ret  z               ; finish if stack empty
               ld   a,(hl)          ; pop P
               or   %00110000       ; set T and B flags
               call split_p_exx     ; split P into status+flags (already exx)
               exx
               inc  l               ; S++
               ld   a,(hl)          ; pop return LSB
               exx
               ld   e,a
               exx
               inc  l               ; S++
               ld   a,(hl)          ; pop return MSB
               exx
               ld   d,a
               jp   main_loop

i_php:         call make_p          ; make P from status+flags
               or   %00010000       ; B always pushed as 1
               exx
               ld   (hl),a
               dec  l               ; S--
               exx
               jp   main_loop
i_plp:         exx                  ; PLP
               inc  l               ; S++
               ld   a,(hl)          ; P
               or   %00110000       ; set T and B flags
               exx
               call split_p         ; split P into status+flags
               jp   main_loop
i_pha:         ld   a,b             ; PHA
               exx
               ld   (hl),a
               dec  l               ; S--
               exx
               jp   main_loop
i_pla:         exx                  ; PLA
               inc  l               ; S++
               ld   a,(hl)
               exx
               ld   b,a             ; set A
               ld   c,b             ; set Z
               ex   af,af'          ; set N
               jp   main_loop

i_dex:         dec  iyh             ; X--
               ld   a,iyh           ; X
               ld   c,a             ; set Z
               ex   af,af'          ; set N
               jp   main_loop
i_dey:         dec  iyl             ; Y--
               ld   a,iyl           ; Y
               ld   c,a             ; set Z
               ex   af,af'          ; set N
               jp   main_loop
i_inx:         inc  iyh             ; X++
               ld   a,iyh           ; X
               ld   c,a             ; set Z
               ex   af,af'          ; set N
               jp   main_loop
i_iny:         inc  iyl             ; Y++
               ld   a,iyl           ; Y
               ld   c,a             ; set Z
               ex   af,af'          ; set N
               jp   main_loop

i_txa:         ld   a,iyh           ; X
               ld   b,a             ; A=X
               ld   c,b             ; set Z
               ex   af,af'          ; set N
               jp   main_loop
i_tya:         ld   a,iyl           ; Y
               ld   b,a             ; A=Y
               ld   c,b             ; set Z
               ex   af,af'          ; set N
               jp   main_loop
i_tax:         ld   iyh,b           ; X=A
               ld   c,b             ; set Z
               ld   a,b
               ex   af,af'          ; set N
               jp   main_loop
i_tay:         ld   iyl,b           ; Y=A
               ld   c,b             ; set Z
               ld   a,b
               ex   af,af'          ; set N
               jp   main_loop
i_txs:         ld   a,iyh           ; X
               exx
               ld   l,a             ; set S (no flags set)
               exx
               jp   main_loop
i_tsx:         exx                  ; TSX
               ld   a,l             ; fetch S
               exx
               ld   iyh,a           ; X=S
               ld   c,a             ; set Z
               ex   af,af'          ; set N
               jp   main_loop


; For speed, LDA/LDX/LDY instructions have addressing inlined

i_lda_ix:      ld   a,(de)          ; LDA ($nn,X)
               inc  de
               add  a,iyh           ; add X (may wrap in zero page)
               ld   l,a
               ld   h,0
               ld   a,(hl)
               inc  hl
               ld   h,(hl)
               ld   l,a
               ld   b,(hl)          ; set A
               ld   c,b             ; set Z
               ld   a,b
               ex   af,af'          ; set N
               jp   zread_loop
i_lda_z:       ld   a,(de)          ; LDA $nn
               inc  de
               ld   l,a
               ld   h,0
               ld   b,(hl)          ; set A
               ld   c,b             ; set Z
               ld   a,b
               ex   af,af'          ; set N
               jp   zread_loop
i_lda_a:       ex   de,hl           ; LDA $nnnn
               ld   e,(hl)
               inc  hl
               ld   d,(hl)
               inc  hl
               ex   de,hl
               ld   b,(hl)          ; set A
               ld   c,b             ; set Z
               ld   a,b
               ex   af,af'          ; set N
               jp   read_loop
i_lda_iy:      ld   a,(de)          ; LDA ($nn),Y
               inc  de
               ld   l,a
               ld   h,0
               ld   a,iyl           ; Y
               add  a,(hl)
               inc  l               ; (may wrap in zero page)
               ld   h,(hl)
               ld   l,a
               ld   a,0
               adc  a,h
               ld   h,a
               ld   b,(hl)          ; set A
               ld   c,b             ; set Z
               ld   a,b
               ex   af,af'          ; set N
               jp   read_loop
i_lda_zx:      ld   a,(de)          ; LDA $nn,X
               inc  de
               add  a,iyh           ; add X (may wrap in zero page)
               ld   l,a
               ld   h,0
               ld   b,(hl)          ; set A
               ld   c,b             ; set Z
               ld   a,b
               ex   af,af'          ; set N
               jp   zread_loop
i_lda_ay:      ex   de,hl           ; LDA $nnnn,Y
               ld   a,iyl           ; Y
               add  a,(hl)
               ld   e,a
               inc  hl
               ld   a,0
               adc  a,(hl)
               ld   d,a
               inc  hl
               ex   de,hl
               ld   b,(hl)          ; set A
               ld   c,b             ; set Z
               ld   a,b
               ex   af,af'          ; set N
               jp   read_loop
i_lda_ax:      ex   de,hl           ; LDA $nnnn,X
               ld   a,iyh           ; X
               add  a,(hl)
               ld   e,a
               inc  hl
               ld   a,0
               adc  a,(hl)
               ld   d,a
               inc  hl
               ex   de,hl
               ld   b,(hl)          ; set A
               ld   c,b             ; set Z
               ld   a,b
               ex   af,af'          ; set N
               jp   read_loop
i_lda_i:       ld   a,(de)          ; LDA #$nn
               inc  de
               ld   b,a             ; set A
               ld   c,b             ; set Z
               ex   af,af'          ; set N
               jp   main_loop

i_ldx_z:       ld   a,(de)          ; LDX $nn
               inc  de
               ld   l,a
               ld   h,0
               ld   a,(hl)
               ld   iyh,a           ; set X
               ld   c,a             ; set Z
               ex   af,af'          ; set N
               jp   zread_loop
i_ldx_a:       ex   de,hl           ; LDX $nnnn
               ld   e,(hl)
               inc  hl
               ld   d,(hl)
               inc  hl
               ex   de,hl
               ld   a,(hl)
               ld   iyh,a           ; set X
               ld   c,a             ; set Z
               ex   af,af'          ; set N
               jp   read_loop
i_ldx_zy:      ld   a,(de)          ; LDX $nn,Y
               inc  de
               add  a,iyl           ; add Y (may wrap in zero page)
               ld   l,a
               ld   h,0
               ld   a,(hl)
               ld   iyh,a           ; set X
               ld   c,a             ; set Z
               ex   af,af'          ; set N
               jp   zread_loop
i_ldx_ay:      ex   de,hl           ; LDX $nnnn,Y
               ld   a,iyl           ; Y
               add  a,(hl)
               ld   e,a
               inc  hl
               ld   a,0
               adc  a,(hl)
               ld   d,a
               inc  hl
               ex   de,hl
               ld   a,(hl)
               ld   iyh,a           ; set X
               ld   c,a             ; set Z
               ex   af,af'          ; set N
               jp   read_loop
i_ldx_i:       ld   a,(de)          ; LDX #$nn
               inc  de
               ld   iyh,a           ; set X
               ld   c,a             ; set Z
               ex   af,af'          ; set N
               jp   main_loop

i_ldy_z:       ld   a,(de)          ; LDY $nn
               inc  de
               ld   l,a
               ld   h,0
               ld   a,(hl)
               ld   iyl,a           ; set Y
               ld   c,a             ; set Z
               ex   af,af'          ; set N
               jp   zread_loop
i_ldy_a:       ex   de,hl           ; LDY $nnnn
               ld   e,(hl)
               inc  hl
               ld   d,(hl)
               inc  hl
               ex   de,hl
               ld   a,(hl)
               ld   iyl,a           ; set Y
               ld   c,a             ; set Z
               ex   af,af'          ; set N
               jp   read_loop
i_ldy_zx:      ld   a,(de)          ; LDY $nn,X
               inc  de
               add  a,iyh           ; add X (may wrap in zero page)
               ld   l,a
               ld   h,0
               ld   a,(hl)
               ld   iyl,a           ; set Y
               ld   c,a             ; set Z
               ex   af,af'          ; set N
               jp   zread_loop
i_ldy_ax:      ex   de,hl           ; LDY $nnnn,X
               ld   a,iyh           ; X
               add  a,(hl)
               ld   e,a
               inc  hl
               ld   a,0
               adc  a,(hl)
               ld   d,a
               inc  hl
               ex   de,hl
               ld   a,(hl)
               ld   iyl,a           ; set Y
               ld   c,a             ; set Z
               ex   af,af'          ; set N
               jp   read_loop
i_ldy_i:       ld   a,(de)          ; LDY #$nn
               inc  de
               ld   iyl,a           ; set Y
               ld   c,a             ; set Z
               ex   af,af'          ; set N
               jp   main_loop


; For speed, STA/STX/STY instructions have addressing inlined

i_sta_ix:      ld   a,(de)          ; STA ($xx,X)
               inc  de
               add  a,iyh           ; add X (may wrap in zero page)
               ld   l,a
               ld   h,0
               ld   a,(hl)
               inc  hl
               ld   h,(hl)
               ld   l,a
               ld   (hl),b
               jp   zwrite_loop
i_sta_z:       ld   a,(de)          ; STA $nn
               inc  de
               ld   l,a
               ld   h,0
               ld   (hl),b
               jp   zwrite_loop
i_sta_iy:      ld   a,(de)
               inc  de
               ld   l,a
               ld   h,0
               ld   a,iyl           ; Y
               add  a,(hl)
               inc  l
               ld   h,(hl)
               ld   l,a
               ld   a,0
               adc  a,h
               ld   h,a
               ld   (hl),b
               jp   write_loop
i_sta_zx:      ld   a,(de)
               inc  de
               add  a,iyh           ; add X (may wrap in zero page)
               ld   l,a
               ld   h,0
               ld   (hl),b
               jp   zwrite_loop
i_sta_ay:      ex   de,hl
               ld   a,iyl           ; Y
               add  a,(hl)
               ld   e,a
               inc  hl
               ld   a,0
               adc  a,(hl)
               ld   d,a
               inc  hl
               ex   de,hl
               ld   (hl),b
               jp   write_loop

i_sta_ax:      ex   de,hl
               ld   a,iyh           ; X
               add  a,(hl)
               ld   e,a
               inc  hl
               ld   a,0
               adc  a,(hl)
               ld   d,a
               inc  hl
               ex   de,hl
               ld   (hl),b
               jp   write_loop
i_sta_a:       ex   de,hl
               ld   e,(hl)
               inc  hl
               ld   d,(hl)
               inc  hl
               ex   de,hl
               ld   (hl),b
               jp   write_loop

i_stx_z:       ld   a,(de)
               inc  de
               ld   l,a
               ld   h,0
               ld   a,iyh           ; X
               ld   (hl),a
               jp   zwrite_loop
i_stx_zy:      ld   a,(de)
               inc  de
               add  a,iyl           ; add Y (may wrap in zero page)
               ld   l,a
               ld   h,0
               ld   a,iyh           ; X
               ld   (hl),a
               jp   zwrite_loop
i_stx_a:       ex   de,hl
               ld   e,(hl)
               inc  hl
               ld   d,(hl)
               inc  hl
               ex   de,hl
               ld   a,iyh           ; X
               ld   (hl),a
               jp   write_loop

i_sty_z:       ld   a,(de)
               inc  de
               ld   l,a
               ld   h,0
               ld   a,iyl           ; Y
               ld   (hl),a
               jp   zwrite_loop
i_sty_zx:      ld   a,(de)
               inc  de
               add  a,iyh           ; add X (may wrap in zero page)
               ld   l,a
               ld   h,0
               ld   a,iyl           ; Y
               ld   (hl),a
               jp   zwrite_loop
i_sty_a:       ex   de,hl
               ld   e,(hl)
               inc  hl
               ld   d,(hl)
               inc  hl
               ex   de,hl
               ld   a,iyl           ; Y
               ld   (hl),a
               jp   write_loop

i_stz_zx:      ld   a,(de)
               inc  de
               add  a,iyh           ; add X (may wrap in zero page)
               ld   l,a
               ld   h,0
               ld   (hl),h
               jp   zwrite_loop
i_stz_ax:      ex   de,hl
               ld   a,iyh           ; X
               add  a,(hl)
               ld   e,a
               inc  hl
               ld   a,0
               adc  a,(hl)
               ld   d,a
               inc  hl
               ex   de,hl
               ld   (hl),0
               jp   write_loop
i_stz_a:       ex   de,hl
               ld   e,(hl)
               inc  hl
               ld   d,(hl)
               inc  hl
               ex   de,hl
               ld   (hl),0
               jp   write_loop

i_adc_ix:      ld   ix,i_adc
               jp   a_indirect_x
i_adc_z:       ld   ix,i_adc
               jp   a_zero_page
i_adc_a:       ld   ix,i_adc
               jp   a_absolute
i_adc_zx:      ld   ix,i_adc
               jp   a_zero_page_x
i_adc_ay:      ld   ix,i_adc
               jp   a_absolute_y
i_adc_ax:      ld   ix,i_adc
               jp   a_absolute_x
i_adc_iy:      ld   ix,i_adc
               jp   a_indirect_y
i_adc_i:       ld   h,d
               ld   l,e
               inc  de
i_adc:         exx
               ld   a,c             ; C
               exx
               rra                  ; set up carry
               ld   a,b             ; A
               adc  a,(hl)          ; A+M+C
adc_daa:       nop
               ld   b,a             ; set A
;              jp   set_nvzc
               ; fall through to set_nvzc...

set_nvzc:      ld   c,a             ; set Z
               rla                  ; C in bit 0, no effect on V
               exx
               ld   c,a             ; set C
               jp   pe,set_v
               ld   b,%00000000     ; V clear
               exx
               ld   a,c
               ex   af,af'          ; set N
               jp   read_loop
set_v:         ld   b,%01000000     ; V set
               exx
               ld   a,c
               ex   af,af'          ; set N
               jp   read_loop

i_sbc_ix:      ld   ix,i_sbc
               jp   a_indirect_x
i_sbc_z:       ld   ix,i_sbc
               jp   a_zero_page
i_sbc_a:       ld   ix,i_sbc
               jp   a_absolute
i_sbc_zx:      ld   ix,i_sbc
               jp   a_zero_page_x
i_sbc_ay:      ld   ix,i_sbc
               jp   a_absolute_y
i_sbc_ax:      ld   ix,i_sbc
               jp   a_absolute_x
i_sbc_iy:      ld   ix,i_sbc
               jp   a_indirect_y
i_sbc_i:       ld   h,d
               ld   l,e
               inc  de
i_sbc:         exx
               ld   a,c             ; C
               exx
               rra                  ; set up carry
               ld   a,b             ; A
               ccf                  ; uses inverted carry
               sbc  a,(hl)          ; A-M-(1-C)
sbc_daa:       nop
               ccf                  ; no carry for overflow
               ld   b,a             ; set A
               jp   set_nvzc

i_and_ix:      ld   ix,i_and
               jp   a_indirect_x
i_and_z:       ld   ix,i_and
               jp   a_zero_page
i_and_a:       ld   ix,i_and
               jp   a_absolute
i_and_zx:      ld   ix,i_and
               jp   a_zero_page_x
i_and_ay:      ld   ix,i_and
               jp   a_absolute_y
i_and_ax:      ld   ix,i_and
               jp   a_absolute_x
i_and_iy:      ld   ix,i_and
               jp   a_indirect_y
i_and_i:       ld   h,d
               ld   l,e
               inc  de
i_and:         ld   a,b             ; A
               and  (hl)            ; A&x
               ld   b,a             ; set A
               ld   c,b             ; set Z
               ex   af,af'          ; set N
               jp   read_loop

i_eor_ix:      ld   ix,i_eor
               jp   a_indirect_x
i_eor_z:       ld   ix,i_eor
               jp   a_zero_page
i_eor_a:       ld   ix,i_eor
               jp   a_absolute
i_eor_zx:      ld   ix,i_eor
               jp   a_zero_page_x
i_eor_ay:      ld   ix,i_eor
               jp   a_absolute_y
i_eor_ax:      ld   ix,i_eor
               jp   a_absolute_x
i_eor_iy:      ld   ix,i_eor
               jp   a_indirect_y
i_eor_i:       ld   h,d
               ld   l,e
               inc  de
i_eor:         ld   a,b             ; A
               xor  (hl)            ; A^x
               ld   b,a             ; set A
               ld   c,b             ; set Z
               ex   af,af'          ; set N
               jp   read_loop

i_ora_ix:      ld   ix,i_ora
               jp   a_indirect_x
i_ora_z:       ld   ix,i_ora
               jp   a_zero_page
i_ora_a:       ld   ix,i_ora
               jp   a_absolute
i_ora_zx:      ld   ix,i_ora
               jp   a_zero_page_x
i_ora_ay:      ld   ix,i_ora
               jp   a_absolute_y
i_ora_ax:      ld   ix,i_ora
               jp   a_absolute_x
i_ora_iy:      ld   ix,i_ora
               jp   a_indirect_y
i_ora_i:       ld   h,d
               ld   l,e
               inc  de
i_ora:         ld   a,b             ; A
               or   (hl)            ; A|x
               ld   b,a             ; set A
               ld   c,b             ; set Z
               ex   af,af'          ; set N
               jp   read_loop

i_cmp_ix:      ld   ix,i_cmp
               jp   a_indirect_x
i_cmp_z:       ld   ix,i_cmp
               jp   a_zero_page
i_cmp_a:       ld   ix,i_cmp
               jp   a_absolute
i_cmp_zx:      ld   ix,i_cmp
               jp   a_zero_page_x
i_cmp_ay:      ld   ix,i_cmp
               jp   a_absolute_y
i_cmp_ax:      ld   ix,i_cmp
               jp   a_absolute_x
i_cmp_iy:      ld   ix,i_cmp
               jp   a_indirect_y
i_cmp_i:       ld   h,d
               ld   l,e
               inc  de
i_cmp:         ld   a,b             ; A
               sub  (hl)            ; A-x (result discarded)
               ccf
               exx
               rl   c               ; retrieve carry
               exx
               ld   c,a             ; set Z
               ex   af,af'          ; set N
               jp   read_loop

i_cpx_z:       ld   ix,i_cpx
               jp   a_zero_page
i_cpx_a:       ld   ix,i_cpx
               jp   a_absolute
i_cpx_i:       ld   h,d
               ld   l,e
               inc  de
i_cpx:         ld   a,iyh           ; X
               sub  (hl)            ; X-x (result discarded)
               ccf
               exx
               rl   c               ; retrieve carry
               exx
               ld   c,a             ; set Z
               ex   af,af'          ; set N
               jp   read_loop

i_cpy_z:       ld   ix,i_cpy
               jp   a_zero_page
i_cpy_a:       ld   ix,i_cpy
               jp   a_absolute
i_cpy_i:       ld   h,d
               ld   l,e
               inc  de
i_cpy:         ld   a,iyl           ; Y
               sub  (hl)            ; Y-x (result discarded)
               ccf
               exx
               rl   c               ; retrieve carry
               exx
               ld   c,a             ; set Z
               ex   af,af'          ; set N
               jp   read_loop


i_dec_z:       ld   ix,i_dec_zp
               jp   a_zero_page
i_dec_zx:      ld   ix,i_dec_zp
               jp   a_zero_page_x
i_dec_a:       ld   ix,i_dec
               jp   a_absolute
i_dec_ax:      ld   ix,i_dec
               jp   a_absolute_x
i_dec:         dec  (hl)            ; mem--
               ld   c,(hl)          ; set Z
               ld   a,c
               ex   af,af'          ; set N
               jp   read_write_loop
i_dec_zp:      dec  (hl)            ; zero-page--
               ld   c,(hl)          ; set Z
               ld   a,c
               ex   af,af'          ; set N
               jp   zread_write_loop

i_inc_z:       ld   ix,i_inc_zp
               jp   a_zero_page
i_inc_zx:      ld   ix,i_inc_zp
               jp   a_zero_page_x
i_inc_a:       ld   ix,i_inc
               jp   a_absolute
i_inc_ax:      ld   ix,i_inc
               jp   a_absolute_x
i_inc:         inc  (hl)            ; mem++
               ld   c,(hl)          ; set Z
               ld   a,c
               ex   af,af'          ; set N
               jp   read_write_loop
i_inc_zp:      inc  (hl)            ; zero-page++
               ld   c,(hl)          ; set Z
               ld   a,c
               ex   af,af'          ; set N
               jp   zread_write_loop

i_asl_z:       ld   ix,i_asl
               jp   a_zero_page
i_asl_zx:      ld   ix,i_asl
               jp   a_zero_page_x
i_asl_a:       ld   ix,i_asl
               jp   a_absolute
i_asl_ax:      ld   ix,i_asl
               jp   a_absolute_x
i_asl_acc:     sla  b               ; A << 1
               exx
               rl   c               ; retrieve carry
               exx
               ld   c,b             ; set Z
               ld   a,b
               ex   af,af'          ; set N
               jp   main_loop
i_asl:         ld   a,(hl)          ; x
               add  a,a             ; x << 1
               ld   (hl),a          ; set memory
               exx
               rl   c               ; retrieve carry
               exx
               ld   c,a             ; set Z
               ex   af,af'          ; set N
               jp   write_loop

i_lsr_z:       ld   ix,i_lsr
               jp   a_zero_page
i_lsr_zx:      ld   ix,i_lsr
               jp   a_zero_page_x
i_lsr_a:       ld   ix,i_lsr
               jp   a_absolute
i_lsr_ax:      ld   ix,i_lsr
               jp   a_absolute_x
i_lsr_acc:     srl  b               ; A >> 1
               exx
               rl   c               ; retrieve carry
               exx
               ld   c,b             ; set Z
               ld   a,b
               ex   af,af'          ; set N
               jp   main_loop
i_lsr:         ld   a,(hl)          ; x
               srl  a               ; x >> 1
               ld   (hl),a          ; set memory
               exx
               rl   c               ; retrieve carry
               exx
               ld   c,a             ; set Z
               ex   af,af'          ; set N
               jp   write_loop

i_rol_z:       ld   ix,i_rol
               jp   a_zero_page
i_rol_zx:      ld   ix,i_rol
               jp   a_zero_page_x
i_rol_a:       ld   ix,i_rol
               jp   a_absolute
i_rol_ax:      ld   ix,i_rol
               jp   a_absolute_x
i_rol_acc:     ld   a,b
               exx
               rr   c               ; set up carry
               rla                  ; A << 1
               rl   c               ; retrieve carry
               exx
               ld   b,a             ; set A
               ld   c,b             ; set Z
               ex   af,af'          ; set N
               jp   main_loop
i_rol:         ld   a,(hl)          ; x
               exx
               rr   c               ; set up carry
               rla                  ; x << 1
               rl   c               ; retrieve carry
               exx
               ld   (hl),a          ; set memory
               ld   c,a             ; set Z
               ex   af,af'          ; set N
               jp   write_loop

i_ror_z:       ld   ix,i_ror
               jp   a_zero_page
i_ror_zx:      ld   ix,i_ror
               jp   a_zero_page_x
i_ror_a:       ld   ix,i_ror
               jp   a_absolute
i_ror_ax:      ld   ix,i_ror
               jp   a_absolute_x
i_ror_acc:     ld   a,b
               exx
               rr   c               ; set up carry
               rra                  ; A >> 1
               rl   c               ; retrieve carry
               exx
               ld   b,a             ; set A
               ld   c,b             ; set Z
               ex   af,af'          ; set N
               jp   main_loop
i_ror:         ld   a,(hl)          ; x
               exx
               rr   c               ; set up carry
               rra                  ; x >> 1
               rl   c               ; retrieve carry
               exx
               ld   (hl),a          ; set memory
               ld   c,a             ; set Z
               ex   af,af'          ; set N
               jp   write_loop


i_bit_z:       ld   ix,i_bit
               jp   a_zero_page
i_bit_zx:      ld   ix,i_bit
               jp   a_zero_page_x
i_bit_a:       ld   ix,i_bit
               jp   a_absolute
i_bit_ax:      ld   ix,i_bit
               jp   a_absolute_x
i_bit_i:       ld   h,d             ; BIT #$nn
               ld   l,e
               inc  de
i_bit:         ld   c,(hl)          ; x
               ld   a,c
               ex   af,af'          ; set N
               ld   a,c
               and  %01000000       ; V flag set from bit 6
               exx
               ld   b,a             ; set V
               exx
               ld   a,b             ; A
               and  c               ; perform BIT test
               ld   c,a             ; set Z
               jp   read_loop

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

make_p:        ex   af,af'
               and  %10000000       ; keep N
               ld   l,a             ; N
               ex   af,af'
               ld   a,c             ; Z
               sub  1               ; set carry if zero
               rla
               rla
               and  %00000010       ; keep 6510 Z bit
               or   l               ; N+Z
               exx
               or   b               ; N+V+Z
               ld   e,a
               ld   a,c
               and  %00000001       ; keep C
               or   e               ; N+V+Z+C
               exx
               ret

split_p:       exx
split_p_exx:   ld   e,a             ; save P
               and  %00111100       ; keep CPU bits
               ld   d,a             ; set status
               ld   a,e
               ex   af,af'          ; set N
               ld   a,e
               and  %01000000       ; keep V
               ld   b,a             ; set V
               ld   a,e
               and  %00000001       ; keep C
               ld   c,a             ; set C
               ld   a,e
               cpl
               and  %00000010       ; Z=0 NZ=2
               exx
               ld   c,a             ; set NZ
               ret


gap3:          equ  &dc00-$        ; error if previous code is
               defs gap3           ; too big for available gap!

               defs 16             ; CIA #1 (keyboard, joystick, mouse, tape, IRQ)


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

; SID interface functions

sid_reset:     ld   hl,last_regs
               ld   bc,&00d4       ; SID base port is &D4
               ld   d,b            ; write 0 to all registers
               ld   a,25           ; 25 registers to write
reset_loop:    out  (c),d          ; write to register
               ld   (hl),d         ; remember new value
               inc  hl
               set  7,b
               out  (c),d          ; effectively strobe write
               res  7,b
               inc  b
               cp   b
               jr   nz,reset_loop  ; loop until all reset

               xor  a
               ld   (last_regs+&04),a   ; control for voice 1
               ld   (last_regs+&0b),a   ; control for voice 2
               ld   (last_regs+&12),a   ; control for voice 3
               ret

sid_update:    ex   de,hl          ; switch new values to DE
               ld   c,&d4          ; SID interface base port

               ld   hl,25          ; control 1 changes offset
               add  hl,de
               ld   a,(hl)         ; fetch changes
               and  a
               jr   z,control2     ; skip if nothing changed
               ld   (hl),0         ; reset changes for next time
               ld   hl,&04         ; new register 4 offset
               ld   b,l            ; SID register 4
               add  hl,de
               xor  (hl)           ; toggle changed bits
               out  (c),a          ; write intermediate value
               ld   (last_regs+&04),a ; update last reg value
               set  7,b
               out  (c),a          ; strobe

control2:      ld   hl,26          ; control 2 changes offset
               add  hl,de
               ld   a,(hl)
               and  a
               jr   z,control3     ; skip if no changes
               ld   (hl),0
               ld   hl,&0b
               ld   b,l            ; SID register 11
               add  hl,de
               xor  (hl)
               out  (c),a
               ld   (last_regs+&0b),a
               set  7,b
               out  (c),a

control3:      ld   hl,27          ; control 3 changes offset
               add  hl,de
               ld   a,(hl)
               and  a
               jr   z,control_done ; skip if no changes
               ld   (hl),0
               ld   hl,&12
               ld   b,l            ;  SID register 18
               add  hl,de
               xor  (hl)
               out  (c),a
               ld   (last_regs+&12),a
               set  7,b
               out  (c),a

control_done:  ld   hl,last_regs   ; previous register values
               ld   b,0            ; start with register 0
out_loop:      ld   a,(de)         ; new register value
               cp   (hl)           ; compare with previous value
               jr   z,sid_skip     ; skip if no change
               out  (c),a          ; write value
               ld   (hl),a         ; store new value
               set  7,b
               out  (c),a          ; effectively strobe write
               res  7,b
sid_skip:      inc  hl
               inc  de
               inc  b              ; next register
               ld   a,b
               cp   25             ; 25 registers to write
               jr   nz,out_loop    ; loop until all updated
               ld   hl,7
               add  hl,de          ; make up to a block of 32
               ret


start_50Hz:    equ  0
step_50Hz:     equ  0
end_50Hz:      equ  0

start_60Hz:    equ  191             ; start on line 191
step_60Hz:     equ  312/6           ; step back 52 lines
step5_60Hz:    equ  start_60Hz-(4*step_60Hz) ; in top border
end_60Hz:      equ  start_60Hz-(5*step_60Hz) ; frame int finish

start_100Hz:   equ  88
step_100Hz:    equ  0
end_100Hz:     equ  start_100Hz

; Set playback speed, using timer first then ntsc flag
set_speed:     ld   hl,(c64_cia_timer) ; C64 CIA#1 timer frequency
               ld   a,h
               or   l
               jr   nz,use_timer    ; use if non-zero
               ld   a,(ntsc_tune)   ; SID header said NTSC tune?
               and  a
               jr   nz,set_60hz     ; use 60Hz for NTSC

set_50hz:      ld   h,start_50Hz
;              ld   l,end_50Hz
;              ld   a,step_50Hz
set_exit:      ld   (line_step1+1),a
               ld   (line_step2+1),a
               ld   a,h
               ld   (line_start+1),a
               ld   (line_num),a
               ld   a,l
               ld   (line_end+1),a
               ld   a,&ff
               out  (line),a        ; disable line interrupts
               ret
set_60hz:      ld   h,start_60Hz
               ld   l,end_60Hz
               ld   a,step_60hz
               jr   set_exit
set_100hz:     ld   h,start_100Hz
               ld   l,end_100Hz
               ld   a,step_100Hz
               jr   set_exit

; 985248.4Hz / HL = playback frequency in Hz
use_timer:     ld   a,h
               cp   &22             ; 110Hz (PAL)
               jr   c,bad_timer     ; reject >100Hz
               cp   &2b             ; 90Hz
               jr   c,set_100Hz     ; use 100Hz for 90-110Hz
               cp   &3b             ; 65Hz
               jr   c,bad_timer     ; reject 65<freq<90hz
               cp   &45             ; 55Hz
               jr   c,set_60Hz      ; use 60Hz for 55-65Hz
               cp   &56             ; 45Hz
               jr   c,set_50Hz      ; use 50Hz for 45-55Hz
                                    ; reject <45Hz
bad_timer:     pop  hl              ; junk return address
               ld   a,ret_timer     ; unsupported frequency
               ret

gap4:          equ  &dd00-$         ; error if previous code is
               defs gap4            ; too big for available gap!
               defs 16              ; CIA #2 (serial, NMI)

               defs 32              ; small private stack
new_stack:     equ  $

blocks:        defw 0               ; buffered block count
head:          defw 0               ; head for recorded data
tail:          defw 0               ; tail for playing data

init_addr:     defw 0
play_addr:     defw 0
play_song:     defb 0
ntsc_tune:     defb 0               ; non-zero for 60Hz tunes

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

; Buffer management

record_block:  ld   de,(head)
               ld   hl,sid_regs     ; record from live SID values
               ld   bc,25           ; 25 registers to copy

               ld   a,buffer_page+rom0_off
               out  (lmpr),a
               ldir
               xor  a
               ld   l,&24           ; changes for control 1
               ldi
               ld   l,&2b           ; changes for control 2
               ldi
               ld   l,&32           ; changes for control 3
               ldi
               ld   l,&24
               ld   (hl),a          ; clear control changes 1
               ld   l,&2b
               ld   (hl),a          ; clear control changes 2
               ld   l,&32
               ld   (hl),a          ; clear control changes 3
               inc  e
               inc  e
               inc  e
               inc  de              ; top up to 32 byte block
               res  7,d             ; wrap in 32K block
               ld   (head),de
               ld   a,low_page+rom0_off
               out  (lmpr),a

               ld   hl,sid_regs
               ld   de,prev_regs
               ld   bc,25
               ldir

               ld   hl,(blocks)
               inc  hl
               ld   (blocks),hl
               ret

play_block:    ld   hl,(blocks)
               ld   a,h
               or   l
               ret  z
               dec  hl              ; 1 less block available
               ld   (blocks),hl
               ld   de,buffer_low
               sbc  hl,de
               jr   nc,buffer_ok    ; jump if we're not low
               ld   a,128           ; screen off for speed boost
               out  (border),a

buffer_ok:     ld   a,buffer_page+rom0_off
               out  (lmpr),a
               ld   hl,(tail)
               call sid_update
               res  7,h             ; wrap in 32K block
               ld   (tail),hl

               ld   a,&ff
               in   a,(keyboard)
               rra
               ret  c               ; return if Cntrl not pressed

               ld   hl,(blocks)
               add  hl,hl
               ld   a,&3f
               sub  h
               and  %00000111
               out  (border),a
               ret

enable_player: ld   hl,im2_table
               ld   c,im2_vector/256
im2_lp:        ld   (hl),c
               inc  l
               jr   nz,im2_lp       ; loop for first 256 entries
               ld   a,h
               inc  h
               ld   (hl),c          ; 257th entry
               ld   i,a
               im   2               ; set interrupt mode 2
               ei                   ; enable player
               ret

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

gap5:          equ  &dddd-$         ; error if previous code is
               defs gap5            ; too big for available gap!

im2_vector:    jp   im2_handler     ; interrupt mode 2 handler

; Reordering the decode table to group low and high bytes avoids
; 16-bit arithmetic for the decode stage, saving 12T

reorder_256:   equ  im2_table       ; use IM2 table as working space

reorder_decode:ld   hl,decode_table
               ld   d,h
               ld   e,l
               ld   bc,reorder_256  ; 256-byte temporary store
reorder_lp:    ld   a,(hl)          ; low byte
               ld   (de),a
               inc  l
               inc  e
               ld   a,(hl)          ; high byte
               ld   (bc),a
               inc  hl
               inc  c
               jr   nz,reorder_lp
               dec  h               ; back to 2nd half (high bytes)
reorder_lp2:   ld   a,(bc)
               ld   (hl),a
               inc  c
               inc  l
               jr   nz,reorder_lp2
               ret

gap6:          equ  &de00-$        ; error if previous code is
               defs gap6           ; too big for available gap!

decode_table:  defw i_brk,i_ora_ix,i_undoc_1,i_undoc_2     ; 00
               defw i_undoc_1,i_ora_z,i_asl_z,i_undoc_2    ; 04
               defw i_php,i_ora_i,i_asl_acc,i_undoc_2      ; 08
               defw i_undoc_3,i_ora_a,i_asl_a,i_undoc_2    ; 0C

               defw i_bpl,i_ora_iy,i_undoc_2,i_undoc_2     ; 10
               defw i_undoc_1,i_ora_zx,i_asl_zx,i_undoc_2  ; 14
               defw i_clc,i_ora_ay,i_undoc_1,i_undoc_3     ; 18
               defw i_undoc_3,i_ora_ax,i_asl_ax,i_undoc_2  ; 1C

               defw i_jsr,i_and_ix,i_undoc_1,i_undoc_2     ; 20
               defw i_bit_z,i_and_z,i_rol_z,i_undoc_2      ; 24
               defw i_plp,i_and_i,i_rol_acc,i_undoc_2      ; 28
               defw i_bit_a,i_and_a,i_rol_a,i_undoc_2      ; 2C

               defw i_bmi,i_and_iy,i_undoc_2,i_undoc_2     ; 30
               defw i_bit_zx,i_and_zx,i_rol_zx,i_undoc_2   ; 34
               defw i_sec,i_and_ay,i_undoc_1,i_undoc_3     ; 38
               defw i_bit_ax,i_and_ax,i_rol_ax,i_undoc_2   ; 3C

               defw i_rti,i_eor_ix,i_undoc_1,i_undoc_2     ; 40
               defw i_undoc_2,i_eor_z,i_lsr_z,i_undoc_2    ; 44
               defw i_pha,i_eor_i,i_lsr_acc,i_undoc_2      ; 48
               defw i_jmp_a,i_eor_a,i_lsr_a,i_undoc_2      ; 4C

               defw i_bvc,i_eor_iy,i_undoc_2,i_undoc_2     ; 50
               defw i_undoc_2,i_eor_zx,i_lsr_zx,i_undoc_2  ; 54
               defw i_cli,i_eor_ay,i_undoc_1,i_undoc_3     ; 58
               defw i_undoc_3,i_eor_ax,i_lsr_ax,i_undoc_2  ; 5C

               defw i_rts,i_adc_ix,i_undoc_1,i_undoc_2     ; 60
               defw i_undoc_2,i_adc_z,i_ror_z,i_undoc_2    ; 64
               defw i_pla,i_adc_i,i_ror_acc,i_undoc_2      ; 68
               defw i_jmp_i,i_adc_a,i_ror_a,i_undoc_2      ; 6C

               defw i_bvs,i_adc_iy,i_undoc_2,i_undoc_2     ; 70
               defw i_stz_zx,i_adc_zx,i_ror_zx,i_undoc_2   ; 74
               defw i_sei,i_adc_ay,i_undoc_1,i_undoc_3     ; 78
               defw i_undoc_3,i_adc_ax,i_ror_ax,i_undoc_2  ; 7C

               defw i_undoc_2,i_sta_ix,i_undoc_2,i_undoc_2 ; 80
               defw i_sty_z,i_sta_z,i_stx_z,i_undoc_2      ; 84
               defw i_dey,i_bit_i,i_txa,i_undoc_2          ; 88
               defw i_sty_a,i_sta_a,i_stx_a,i_undoc_2      ; 8C

               defw i_bcc,i_sta_iy,i_undoc_2,i_undoc_2     ; 90
               defw i_sty_zx,i_sta_zx,i_stx_zy,i_undoc_2   ; 94
               defw i_tya,i_sta_ay,i_txs,i_undoc_2         ; 98
               defw i_stz_a,i_sta_ax,i_stz_ax,i_undoc_2    ; 9C

               defw i_ldy_i,i_lda_ix,i_ldx_i,i_undoc_2     ; A0
               defw i_ldy_z,i_lda_z,i_ldx_z,i_undoc_2      ; A4
               defw i_tay,i_lda_i,i_tax,i_undoc_2          ; A8
               defw i_ldy_a,i_lda_a,i_ldx_a,i_undoc_2      ; AC

               defw i_bcs,i_lda_iy,i_undoc_2,i_undoc_2     ; B0
               defw i_ldy_zx,i_lda_zx,i_ldx_zy,i_undoc_2   ; B4
               defw i_clv,i_lda_ay,i_tsx,i_undoc_3         ; B8
               defw i_ldy_ax,i_lda_ax,i_ldx_ay,i_undoc_2   ; BC

               defw i_cpy_i,i_cmp_ix,i_undoc_2,i_undoc_2   ; C0
               defw i_cpy_z,i_cmp_z,i_dec_z,i_undoc_2      ; C4
               defw i_iny,i_cmp_i,i_dex,i_undoc_1          ; C8
               defw i_cpy_a,i_cmp_a,i_dec_a,i_undoc_2      ; CC

               defw i_bne,i_cmp_iy,i_undoc_2,i_undoc_2     ; D0
               defw i_undoc_2,i_cmp_zx,i_dec_zx,i_undoc_2  ; D4
               defw i_cld,i_cmp_ay,i_undoc_1,i_undoc_1     ; D8
               defw i_undoc_3,i_cmp_ax,i_dec_ax,i_undoc_2  ; DC

               defw i_cpx_i,i_sbc_ix,i_undoc_2,i_undoc_2   ; E0
               defw i_cpx_z,i_sbc_z,i_inc_z,i_undoc_2      ; E4
               defw i_inx,i_sbc_i,i_nop,i_undoc_2          ; E8
               defw i_cpx_a,i_sbc_a,i_inc_a,i_undoc_2      ; EC

               defw i_beq,i_sbc_iy,i_undoc_2,i_undoc_2     ; F0
               defw i_undoc_2,i_sbc_zx,i_inc_zx,i_undoc_2  ; F4
               defw i_sed,i_sbc_ay,i_undoc_1,i_undoc_3     ; F8
               defw i_undoc_3,i_sbc_ax,i_inc_ax,i_undoc_2  ; FC

end:           equ  $
size:          equ  end-base

; For testing we include a sample tune (not supplied)
;INCLUDE "tune.asm"