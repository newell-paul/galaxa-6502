; ======================================================================================
; Galaxa - BBC Micro Model B fixed shooter skeleton (MODE 2, 6502, BeebAsm)
; Original design: three alien types in a swaying formation, one looping dive pattern.
;
; Controls: Z = left, X = right, RETURN = fire
;
; Engine summary
;   - MODE 2: 160x256, 16 colours, 4 bits per pixel, 2 pixels per byte, screen &3000-&7FFF
;   - Positions are in pixels. Every sprite (up to ALIEN_W pixels wide) is stored pre-shifted
;     twice (one copy per pixel offset inside a byte), so it is up to SPR_BYTES bytes wide
;     on screen and can sit at any x, not just every 2nd pixel.
;   - Sprites are drawn with EOR (XOR). Drawing the same image twice erases it.
;   - A sprite that slides one pixel sideways is moved with a single "delta" image
;     (old image EOR new image, also up to SPR_BYTES bytes wide). Each screen byte changes once, straight
;     from the old picture to the new one, so the sprite never vanishes mid-frame.
;   - Beam chasing: User VIA timer 2 restarts at vsync, so the code knows which scan
;     line the CRT is drawing. Objects are redrawn top to bottom, each one just after
;     the beam has passed it, so nothing is ever half old, half new on screen, and
;     every object appears exactly one frame after it is drawn. The ship is the
;     exception: it sits at the bottom, so it is drawn straight after vsync, well
;     before the beam gets there.
;   - The formation ripples: one row moves per frame, so each row steps 1 pixel every
;     4 frames and a frame never redraws more than 6 aliens.
;   - Aliens flap between two frames. A step that also flaps uses a "cross" delta (old
;     frame at the old x EOR new frame at the new x), so flapping costs no extra plots.
;   - The flagships' yellow is its own logical colour (2), pulsed by ULA palette
;     writes during vblank: no plots.
;   - Starfield: sprites use colour bits 0-2 only, stars bit 3 only. Colour 8 is white
;     and colours 9-15 repeat 1-7, so a sprite always shows over a star and neither
;     ever changes the other's pixels. Stars move straight after vsync, ahead of the beam.
;   - Divers peel off in a half loop, then swoop at the player with sideways momentum.
;   - The ship fires one shot at a time. Shooting BONUS_KILLS swooping aliens drops a
;     capsule; catching it gives two shots at a time until the ship is lost.
;   - Memory: the file loads at &1900 and copies itself down to &0E00 (the disc
;     system's workspace, unused once loaded). Run-time state lives at &0400-&07FF, with
;     the bonus capsule's code after it.
;   - One frame = wait for vsync (OSBYTE 19), then update everything once (50Hz).
;   - Fully deterministic: no random numbers, same inputs = same game.
; ======================================================================================

OSRDCH = &FFE0
OSWRCH = &FFEE
OSWORD = &FFF1
OSBYTE = &FFF4
KEYV   = &0228

SCREEN       = &3000
MODE7_SCREEN = &7C00

; User VIA timer 2, used as a raster clock (1MHz, one tick per microsecond)
USR_T2L      = &FE68
USR_T2H      = &FE69
USR_ACR      = &FE6B
USR_IER      = &FE6E

; Raster position is measured in 256us units (4 scan lines). Pixel row y is scanned
; at unit BEAM_TOP + y DIV 4 after the timer restarts.
BEAM_TOP     = 7              ; measured in jsbeeb: 6-8 (the timer starts after OSBYTE 19 returns)

SYS_IER      = &FE4E          ; System VIA interrupt enable

KEY_LEFT     = 1              ; keys bits, read at the start of each frame
KEY_RIGHT    = 2
KEY_FIRE     = 4

; Keyboard matrix codes, read straight from the System VIA (INKEY -n is code n - 1)
KEY_Z        = &61
KEY_X        = &42
KEY_RETURN   = &49

SYS_ORB      = &FE40          ; System VIA: addressable latch (bit 3 = keyboard auto-scan)
SYS_DDRA     = &FE43
SYS_ORA_NH   = &FE4F          ; port A without handshake: keyboard column / row select

ULA_PALETTE  = &FE21

SPR_PLAYER   = 0              ; sprite ids, index spr_h / img_* / dlt_*
SPR_BULLET   = 1
SPR_FLAGSHIP = 2              ; aliens come in pairs: id EOR 1 is the other flap frame
SPR_ESCORT   = 4
SPR_DRONE    = 6
SPR_BULLET_STEP = 8           ; old and new bullet together: one plot moves it
SPR_ABULLET  = 9              ; the aliens' bullets
SPR_ABULLET_STEP = 10
CROSS_OFS    = 9              ; delta id of "frame id at x -> other frame at x + 1"
VERT_OFS     = 15             ; delta id of "frame id at y -> same frame at y + 1"
DOWN_OFS     = 21             ; delta id of "frame id at (x, y) -> same at (x + 1, y + 1)"
UP_OFS       = 27             ; delta id of "frame id at (x, y + 1) -> same at (x + 1, y)"
ALIEN_W      = 10             ; every alien image is this many pixels wide and high
ALIEN_H      = 8
ALIEN_MID    = ALIEN_W DIV 2 - 1    ; an alien's middle column: it fires from here
SPR_BYTES    = (ALIEN_W + 1) DIV 2 + 1  ; the widest image or delta (an alien delta), in byte columns

PULSE_COLOUR = 2              ; logical colour of the flagships' yellow
STAR_COLOUR  = 8              ; the star bit: added to a sprite colour, it changes nothing

NUM_STARS    = 30             ; a third each move 2px a frame, 1px a frame, 1px every 2nd frame
STAR_TOP     = 16             ; stars stay below the HUD, where the beam is after they move
STAR_X_STEP  = 67             ; a star leaving the bottom comes back this far to the right
TWINKLE_RATE = 4              ; frames between twinkles: two stars blink out at a time
TWINKLE_STEP = 7
STAR_BAND    = 48             ; stars above this row (or about to wrap to the top) move first

FLAP_MASK    = 4              ; a row sways on steps where frame AND FLAP_MASK = 0
FLAP_SKIP    = 8              ; and flaps on those where frame AND FLAP_SKIP = 0 too

SFX_FIRE     = 1              ; sfx bits, in sfx_data order
SFX_DIVE     = 2
SFX_DIE      = 4
SFX_RUMBLE   = 8
SFX_HIT      = 16             ; an alien shot: the wave tune at double speed (play_tune)
SFX_POWER    = 32             ; the capsule caught: a jingle (play_tune), the last bit

MACRO SFX bit
    LDA #bit : ORA sfx : STA sfx
ENDMACRO

PLAYER_Y     = 232            ; top row of the player's ship
PLAYER_MAX_X = 148            ; the right limit for the ship and the aliens
PLAYER_START = 72             ; where each ship comes into play
SPARE_Y      = 256 - 8        ; spare ships wait in the bottom left corner, 10 pixels apart
DIE_TIME     = 144            ; frames a hit ship blinks before it goes
FLASH_TIME   = 8              ; the first frames of that, the background flashes
DIE_BLINK    = 8              ; it toggles every this many frames (a power of 2)
ASSERT (DIE_TIME DIV DIE_BLINK) MOD 2 = 0       ; an odd number of toggles: it ends hidden
ASSERT PLAYER_START MOD 2 = 0

PS_PLAY      = 0              ; player_state values
PS_DYING     = 1              ; hit: blinking out
PS_SLIDE     = 2              ; the next ship sliding in from the spares: no hits, no control
PS_OVER      = 3              ; the last ship has gone
GAME_OVER_TIME = 100           ; frames GAME OVER shows before the title

HS_ENTRIES   = 5
HS_NAME      = 3              ; title.asm high score row: name, then score digits
HS_DIGITS    = 16
PROMPT_LEN   = 13
PROMPT_ANY   = PROMPT_LEN - 1     ; last character of each prompt in txt_prompts
PROMPT_INITIALS = 2 * PROMPT_LEN - 1
TT_WHITE     = 135            ; teletext: white text
TT_FLASH     = 136            ; teletext: flash
ASSERT PLAYER_MAX_X + ALIEN_W <= 160    ; an alien there still fits on screen

FORM_COLS    = 6
FORM_ROWS    = 4
FORM_COUNT   = FORM_COLS * FORM_ROWS
FORM_INSET   = "2100"         ; empty columns at each end of each row: 2, 4, 6, 6 aliens
WAVE_COUNT   = FORM_COUNT - 2 * (VAL(MID$(FORM_INSET, 1, 1)) + VAL(MID$(FORM_INSET, 2, 1)) + VAL(MID$(FORM_INSET, 3, 1)) + VAL(MID$(FORM_INSET, 4, 1)))
FORM_Y       = 32             ; top pixel row of the formation
COL_STEP     = ALIEN_W + 4    ; pixels between formation columns
ROW_STEP     = ALIEN_H + 4    ; pixel rows between formation rows
BREATH_MAX   = 8              ; the outer columns move out this far as the formation breathes
VBREATH_MAX  = 3              ; and the top and bottom rows this far
FX_START     = 40
FX_MIN       = 4 + BREATH_MAX
FX_MAX       = PLAYER_MAX_X - (FORM_COLS - 1) * COL_STEP - BREATH_MAX
ASSERT FX_MIN < FX_START AND FX_START < FX_MAX    ; or the sway never turns

LEVELS       = 6              ; waves 1 to 5, then 6 on: see the level tables
RUSH_COUNT   = 6              ; this few aliens left: they dive almost non-stop
RUSH_DELAY   = 8
DIVE_STRIDE  = 7              ; next diver = (last + 7) MOD 24; coprime with 24, visits every slot
DIVER_SPEED  = 3              ; pixels per frame, down
DIVER_BOTTOM = 240            ; wrap to the top once a diver passes this row
DIVER_TOP    = 8              ; re-entry row, just under the HUD
LOOP_LEN     = 32             ; frames in the peel-off half loop
LOOP_R       = 14             ; its radius in pixels
DIVE_VMAX    = 24             ; swoop speed limit sideways, in 1/16 pixels per frame

BULLETS      = 2              ; the second only with the double shot
BULLET_SPEED = 4              ; = bullet height: old and new positions just touch
FIRE_DELAY   = 16             ; frames between shots
BULLET_TOP   = 8              ; bullets vanish when they reach the HUD

BONUS_KILLS  = 6              ; swooping aliens shot, with a single shot, for a capsule to drop
BONUS_W      = 7
BONUS_BOTTOM = 256 - ALIEN_H  ; gone once its top row passes this
SPR_BONUS    = 11             ; an image id; delta id 11 is a cross delta, the same height

ABULLETS     = 4              ; the aliens' bullets: up to this many on screen
ABULLET_SPEED = 4             ; pixels per frame, down
ABULLET_BOTTOM = 256 - 4      ; lowest top row on screen
BURST_GAP    = 6              ; frames between shots in a burst
AFIRE_LOW    = PLAYER_Y - 24  ; no shots from closer to the player than this
GLYPHS       = 14             ; "0"-"9" then "WAVE"
GLYPH_W      = 10
BANNER_Y     = 120            ; "WAVE n" between waves: text row 15
BANNER_COL   = 7
BANNER_TIME  = 100            ; frames it shows
DROP_Y       = 8              ; each row of a new wave appears here, then drops into place
ORDER_N      = 4 + ABULLETS   ; beam-order entries: formation, 2 bullets, diver, enemy bullets
DEFER_Y      = 112            ; objects this low draw at the next frame's start instead
EARLY_Y      = 144            ; and objects this low update before the rest
QUEUE_MAX    = 24             ; deferred plots per frame

ALIVE_GONE   = 0              ; alive[] states
ALIVE_HOME   = 1
ALIVE_DIVING = 2

DIVER_NONE   = 0              ; diver_state values
DIVER_DIVE   = 1
DIVER_RETURN = 2

; ---------------------------------------------------------------- zero page (&40-&71)
; &00-&8F belongs to the current language; Galaxa never returns to BASIC.
ptr0         = &40            ; 2: screen address of sprite byte column 0 (cell row 0)
                              ; ptr1.. follow, SPR_BYTES in all: ptr0 + 8 * n, byte column n
draw_x       = &4C            ; plotter inputs: pixel x, pixel y, sprite id
draw_y       = &4D
draw_id      = &4E
draw_h       = &4F
tmp          = &50
tmp2         = &51
guard_bot    = &52
player_x     = &53
bullet_on    = &54            ; working copy of the bullet being updated (see bullets_on)
bullet_x     = &55
bullet_y     = &56
old_x        = &57
dive_timer   = &58
diver_state  = &59
diver_slot   = &5A            ; formation slot the diver came from
diver_x      = &5B
diver_y      = &5C
diver_pick   = &5D
alive_count  = &5E            ; aliens still alive, including the diver
slot_x       = &5F            ; diver's home position this frame
slot_y       = &60
loop_i       = &61
frame        = &62
new_x        = &63
new_y        = &64
form_row     = &65
keys         = &66            ; KEY_* bits read at the start of the frame
hud_dirty    = &67            ; non-zero: redraw the score digits after the next vsync
abullet_idx  = &68            ; the aliens' bullet being updated
afire_req    = &69            ; non-zero: the diver fires this frame, from afire_x / afire_y
afire_x      = &6A
afire_y      = &6B
order_done   = &6C
order_vec    = &6D            ; 2: update routine being called
diver_wrap   = &6F            ; non-zero: the diver jumps to the top at the next frame start
bullet_idx   = &70            ; which bullet the working copy belongs to
fire_cool    = &71            ; frames until the next shot is allowed
defer        = &72            ; non-zero: plots are queued for the next frame's start
rnd          = &73            ; random byte, never 0: see random
pl_last_id   = &74            ; the image plot last patched in: draw_id, then its address
pl_last_lo   = &75
pl_last_hi   = &76
sfx          = &77            ; bit n: play sound n at the end of this frame
sfx_x        = &78
bg_colour    = &79            ; ULA palette byte for logical colour 0, set at each vsync
wing_on      = &7A            ; non-zero: the diver has a wingman, its row neighbour
wing_slot    = &7B
wing_x       = &7C            ; at the diver's y, its slot's offset from the diver's slot
wing_nx      = &7D
lead_gone    = &7E            ; non-zero: the diver was shot; its path flies on for the wingman
wing_req     = &7F            ; non-zero: the wingman fires this frame, from wing_fx / afire_y
wing_fx      = &80
keyv_os      = &81            ; and &82: the OS's KEYV, put back for the title
power        = &83            ; non-zero: double shot, until the ship is lost
bonus_on     = &84            ; the capsule: 0 none, 1 falling, 2 just dropped (it waits a frame)
bonus_x      = &85
bonus_y      = &86
dive_kills   = &87            ; swooping aliens shot towards the next capsule
tune_x       = &88            ; the tune being played: its next note in sfx_data
tune_n       = &89            ; and notes still to send, one a frame
ptr1         = ptr0 + 2
ptr2         = ptr0 + 4
ptr3         = ptr0 + 6
ASSERT ptr0 + 2 * SPR_BYTES <= draw_x

; ---------------------------------------------------------------- run-time state
; The language workspace: Galaxa never returns to BASIC. Nothing here is saved to disc.
ORG &0400
GUARD &0800
.row_x
    SKIP FORM_ROWS
.row_dir
    SKIP FORM_ROWS
.row_anim                           ; 0 or 1: which flap frame the row shows
    SKIP FORM_ROWS
.row_bofs                           ; breath * FORM_COLS: the row's base index into breath
    SKIP FORM_ROWS
.row_bdir                           ; FORM_COLS or -FORM_COLS
    SKIP FORM_ROWS
.row_y                              ; top pixel row now
    SKIP FORM_ROWS
.alive
    SKIP FORM_COUNT
.bullets_on
    SKIP BULLETS
.bullets_x
    SKIP BULLETS
.bullets_y
    SKIP BULLETS
.score_lo
    SKIP 1
.score_hi
    SKIP 1
.lives
    SKIP 1
.diver_anim                         ; flap frame the diver is drawn with
    SKIP 1
.new_anim
    SKIP 1
.diver_t                            ; frames into the dive
    SKIP 1
.diver_left                         ; &FF: the loop turns left
    SKIP 1
.diver_xf                           ; x fraction, 1/16 pixels
    SKIP 1
.diver_vx                           ; sideways speed, 1/16 pixels per frame (signed)
    SKIP 1
.font_buf
    SKIP 9
.digits                             ; also the letters of WAVE
    SKIP GLYPHS * 32
.star_x
    SKIP NUM_STARS
.star_y
    SKIP NUM_STARS
.star_lo                            ; screen address of the star's byte
    SKIP NUM_STARS
.star_hi
    SKIP NUM_STARS
.star_bit                           ; &80 left pixel, &40 right pixel: colour bit 3
    SKIP NUM_STARS
.star_vis                           ; star_bit while shown, 0 while twinkled out
    SKIP NUM_STARS
.star_done                          ; the frame the star last moved
    SKIP NUM_STARS
.twinkle_i
    SKIP 1
.order_key                          ; beam-order sort keys: see update_in_beam_order
    SKIP ORDER_N
.order_idx
    SKIP 1
.queue_n
    SKIP 1
.queue_x
    SKIP QUEUE_MAX
.queue_y
    SKIP QUEUE_MAX
.queue_id                           ; bit 7: a delta
    SKIP QUEUE_MAX
.abullets_on
    SKIP ABULLETS
.abullets_x
    SKIP ABULLETS
.abullets_y
    SKIP ABULLETS
.burst_left                         ; shots still to fire in this burst
    SKIP 1
.burst_gap                          ; frames to the next shot
    SKIP 1
.afire_armed                        ; non-zero: the diver's burst is still to come
    SKIP 1
.wave                               ; BCD
    SKIP 1
.intro                              ; 1: the wave banner shows; 2: the rows drop in; 0: play
    SKIP 1
.intro_t
    SKIP 1
.level                              ; min(wave, LEVELS) - 1
    SKIP 1
.ships_shown                        ; spare ships drawn in the bottom left corner
    SKIP 1
.player_state                       ; PS_*
    SKIP 1
.player_t                           ; PS_DYING: frames left
    SKIP 1
.player_row                         ; the ship's top row: PLAYER_Y unless sliding in
    SKIP 1
.sound_blk                          ; OSWORD 7: channel, amplitude, pitch, duration
    SKIP 8
.state_end                          ; the bonus capsule's code follows: see hi_start

LOAD_ADDR    = &1900          ; where *RUN puts the file (PAGE with DFS)

ORG &0900                           ; OS buffers (envelopes 5-16, serial, cassette, soft keys,
GUARD &0DF0                         ; characters 224-255) and the disc NMI code: free in play
.lo_start

; ======================================================================================
; Start-up and game flow
; ======================================================================================

; The MODE 7 title screen, with the initials of a new high score typed in first.
.title
    SEI
    LDA keyv_os : STA KEYV : LDA keyv_os + 1 : STA KEYV + 1
    CLI
    LDA #122 : JSR OSBYTE           ; wait for every key up: one held from the game
    INX : BNE title                 ; mustn't skip the title
    LDA #&81 : STA SYS_IER          ; the OS reads the keyboard while the title shows
    LDA #21 : LDX #0 : JSR OSBYTE   ; empty the keyboard buffer
    LDX #LO(txt_mode7) : LDY #HI(txt_mode7) : JSR print_vdu
    JSR draw_title
    LDX hs_new : BMI ti_wait
    JSR enter_initials
.ti_wait
    LDX #PROMPT_ANY : JSR show_prompt
    JSR OSRDCH
    LDA #&FF : STA hs_new
    LDA #&01 : STA SYS_IER          ; no keyboard interrupt: OSBYTE 129 scans keys itself,
                                    ; and the OS key handler would steal time mid-frame
    SEI                             ; nor the 100Hz poll of a held key: ~1ms a tick
    LDA #LO(keyv_none) : STA KEYV : LDA #HI(keyv_none) : STA KEYV + 1
    CLI
    LDX #LO(vdu_setup) : LDY #HI(vdu_setup) : JSR print_vdu

.new_game
    LDA #12 : JSR OSWRCH            ; CLS (also resets hardware scroll)
    LDA #0 : STA score_lo : STA score_hi : STA wave
    LDA #3 : STA lives
    LDA #PLAYER_START : STA player_x
    LDA #PLAYER_Y : STA player_row
    JSR draw_player
    JSR init_stars
    LDX #LO(txt_hud) : LDY #HI(txt_hud) : JSR print_vdu
    JSR print_hud
    LDA #0 : STA keys : STA fire_cool : STA defer : STA queue_n : STA sfx : STA tune_n
    STA ships_shown : STA player_state
    STA power : STA bonus_on : STA dive_kills
    STA bullets_on : STA bullets_on + 1   ; CLS has wiped them
    LDX #ABULLETS - 1
.ng_abullets
    STA abullets_on,X
    DEX : BPL ng_abullets
    LDA rnd : BNE ng_seeded
    INC rnd
.ng_seeded
    JSR new_wave

.main_loop
    JSR wait_vsync
    LDA diver_wrap : BEQ ml_stars
    JSR diver_reenter               ; first: it draws at DIVER_TOP, which the beam reaches soonest
    JSR update_stars_top            ; that took a while: the stars the beam reaches next
    JSR twinkle_stars
    JSR update_stars_rest
    JMP ml_stars_done
.ml_stars
    JSR twinkle_stars
    JSR update_stars
.ml_stars_done
    JSR flush_plots                 ; last frame's low objects, long before the beam gets there
    INC frame
    JSR pulse_flagships
    LDA fire_cool : BEQ ml_cool_done
    DEC fire_cool
.ml_cool_done
    ; The beam is in the bottom border: the ship is safe to move now.
    JSR read_keys
    JSR update_player
    LDA hud_dirty : BEQ ml_hud_done   ; the HUD is at the top: also safe now
    JSR print_hud
.ml_hud_done
    JSR alien_fire
    ; Then follow the beam down the screen.
    JSR update_in_beam_order
    JSR check_player_hit
    JSR play_sfx                    ; the beam is done with the sprites: time to spare
    LDA player_state : CMP #PS_OVER : BEQ game_over
    LDA alive_count : BNE main_loop
    JSR new_wave                    ; every alien destroyed
    JMP main_loop

.game_over
    LDX #LO(txt_game_over) : LDY #HI(txt_game_over) : JSR print_vdu
    LDX #SND_OVER : JSR play_tune
    LDA #GAME_OVER_TIME : STA intro_t
.go_wait
    LDA #19 : JSR OSBYTE
    DEC intro_t : BNE go_wait
    JSR insert_score
    JMP title

; Reset the formation and timers, show "WAVE n", then drop the rows in from the top;
; the player can move throughout and the HUD stays on screen.
.new_wave
    SED : LDA wave : CLC : ADC #1 : STA wave : CLD
    CMP #LEVELS + 1 : BCC nw_level
    LDA #LEVELS : CLC
.nw_level
    SBC #0 : STA level              ; carry clear: - 1
    LDX #FORM_COUNT - 1
.nw_fill
    LDA slot_start,X : STA alive,X
    DEX : BPL nw_fill
    LDX #FORM_ROWS - 1
.nw_rows
    LDA #FX_START : STA row_x,X
    LDA #1 : STA row_dir,X
    LDA #0 : STA row_anim,X : STA row_bofs,X : STA row_y,X     ; row_y 0: not dropped in yet
    LDA #FORM_COLS : STA row_bdir,X
    DEX : BPL nw_rows
    LDA #WAVE_COUNT : STA alive_count
    LDX level : LDA dive_delays,X : STA dive_timer
    LDA #DIVER_NONE : STA diver_state : STA diver_pick : STA diver_wrap
    LDA #1 : STA intro
    JSR intro_frame                 ; flushes plots queued by the last frame
    LDX #BULLETS - 1                ; erase any bullet still in flight
.nw_bullets
    LDA bullets_on,X : BEQ nw_next_bullet
    JSR bullet_load
    JSR kill_bullet
    LDX bullet_idx
    JSR bullet_save
.nw_next_bullet
    DEX : BPL nw_bullets
    JSR bonus_clear
    LDX #ABULLETS - 1
.nw_abullets
    LDA abullets_on,X : BEQ nw_next_abullet
    STX abullet_idx
    JSR abullet_pos
    LDA draw_y : CLC : ADC #3 : TAX : JSR beam_guard
    JSR abullet_draw                ; erase
    LDX abullet_idx : LDA #0 : STA abullets_on,X
.nw_next_abullet
    DEX : BPL nw_abullets
    LDA #0 : STA burst_left : STA afire_armed
    JSR intro_frame
    JSR toggle_banner
    LDX #SND_WAVE : JSR play_tune
    LDA #BANNER_TIME : STA intro_t
.nw_banner
    JSR intro_frame
    DEC intro_t : BNE nw_banner
    JSR toggle_banner               ; EOR again: gone
    LDA #2 : STA intro
.nw_drop
    JSR intro_frame
    JSR drop_rows
    LDA row_y : CMP row_y0 : BNE nw_drop    ; the rows all land together
    LDA #0 : STA intro
    RTS

; A frame between waves: stars and the player only.
.intro_frame
    JSR wait_vsync
    JSR twinkle_stars
    JSR update_stars
    JSR flush_plots
    INC frame
    JSR pulse_flagships
    JSR read_keys
    JSR update_player
    JMP tune_step                   ; a hit tune started by the wave's last kill goes on

.wait_vsync
    LDA #19 : JSR OSBYTE
    LDA bg_colour : STA ULA_PALETTE ; before the beam reaches the screen: a hit ship's
                                    ; flash goes on between waves too
    LDA #&FF : STA USR_T2L : STA USR_T2H    ; restart the raster clock
    RTS

; "WAVE n" in the middle of the screen, on or off.
.toggle_banner
FOR i, 0, 3
    LDA #GLYPH_W + i : LDX #BANNER_COL + i : JSR eor_glyph
NEXT
    LDX #BANNER_COL + 5
    LDA wave : LSR A : LSR A : LSR A : LSR A : BEQ tb_units
    JSR eor_glyph
    LDX #BANNER_COL + 6
.tb_units
    LDA wave : AND #&0F
    JMP eor_glyph

; Top down, in beam order: the bottom row appears at DROP_Y first and each row above
; follows once the one below is a row step down. They drop 1px per frame and land
; together.
.drop_rows
    LDX #0
.dr_row
    STX form_row
    LDA row_y,X : BNE dr_move
    CPX #FORM_ROWS - 1 : BEQ dr_start
    LDA row_y + 1,X : CMP #DROP_Y + ROW_STEP - 1 : BNE dr_next
.dr_start
    LDA #DROP_Y : STA row_y,X : STA draw_y
    JSR uf_guard
.dr_draw
    LDX loop_i
    LDA alive,X : BEQ dr_draw_next
    JSR draw_slot
.dr_draw_next
    INC loop_i
    LDX loop_i : LDA slot_col,X : BNE dr_draw
    BEQ dr_next
.dr_move
    CMP row_y0,X : BEQ dr_next      ; landed
    STA draw_y
    LDA row_spr,X : ORA row_anim,X : CLC : ADC #VERT_OFS : STA draw_id
    LDA #ALIEN_H : JSR uf_guard_h   ; old and new rows: ALIEN_H + 1 high
.dr_col
    LDX loop_i
    LDA alive,X : BEQ dr_col_next
    LDA slot_px,X : CLC : ADC #FX_START : STA draw_x  ; slot_pos while dropping: row_x = FX_START, no breath
    JSR plot_delta
.dr_col_next
    INC loop_i
    LDX loop_i : LDA slot_col,X : BNE dr_col
    LDX form_row : INC row_y,X
.dr_next
    LDX form_row : INX : CPX #FORM_ROWS : BNE dr_row
    RTS


; The new entry's row flashes while up to three characters are typed into it; DELETE
; goes back one and RETURN ends it.
.enter_initials
    JSR hs_row
    LDY #0 : LDA #TT_FLASH : STA (ptr1),Y
    LDX #PROMPT_INITIALS : JSR show_prompt
    LDY #HS_NAME
.ei_key
    JSR OSRDCH
    CMP #13 : BEQ ei_done
    CMP #127 : BNE ei_char
    CPY #HS_NAME + 1 : BCC ei_key
    DEY : LDA #' ' : STA (ptr1),Y
    BNE ei_key
.ei_char
    CPY #HS_NAME + 3 : BCS ei_key   ; full: only DELETE or RETURN now
    CMP #'a' : BCC ei_upper
    AND #&DF
.ei_upper
    CMP #' ' : BCC ei_key
    CMP #127 : BCS ei_key
    STA (ptr1),Y
    INY : BNE ei_key
.ei_done
    LDX hs_new
    LDY #HS_NAME
.ei_save
    LDA (ptr1),Y : STA hs_data,X
    INX : INY : CPY #HS_NAME + 3 : BNE ei_save
    LDY #0 : LDA #TT_WHITE : STA (ptr1),Y
    RTS

.stamp_scores
    LDX #0
.ss_entry
    JSR hs_row
    LDY #HS_NAME
.ss_name
    LDA hs_data,X : STA (ptr1),Y
    INX : INY : CPY #HS_NAME + 3 : BNE ss_name
    LDY #HS_DIGITS
    LDA hs_data,X : JSR ss_bcd : INX
    LDA hs_data,X : JSR ss_bcd : INX
    CPX #HS_ENTRIES * 5 : BNE ss_entry
    RTS
.ss_bcd                             ; two BCD digits from A to the screen at Y, Y + 1
    PHA : LSR A : LSR A : LSR A : LSR A
    ORA #'0' : STA (ptr1),Y : INY
    PLA : AND #&0F
    ORA #'0' : STA (ptr1),Y : INY
    RTS

.flash_ula                          ; logical colour 0, last frame first: back to black
    EQUB &07, &06, &06, &06, &04, &04, &00, &00

; ptr1 = the screen address of entry X's row at HS_COL (X = entry * 5).
.hs_row
    LDA #LO(MODE7_SCREEN + HS_ROW * 40 + HS_COL) : STA ptr1
    LDA #HI(MODE7_SCREEN + HS_ROW * 40 + HS_COL) : STA ptr1 + 1
    STX tmp
.hr_next
    LDA tmp : BEQ hr_done
    SEC : SBC #5 : STA tmp
    LDA ptr1 : CLC : ADC #40 : STA ptr1
    BCC hr_next
    INC ptr1 + 1 : BCS hr_next
.hr_done
    RTS

; X = PROMPT_ANY or PROMPT_INITIALS.
.show_prompt
    LDY #PROMPT_LEN - 1
.sp_copy
    LDA txt_prompts,X : STA MODE7_SCREEN + PROMPT_ROW * 40 + PROMPT_COL,Y
    DEX : DEY : BPL sp_copy
    RTS

; Make room in the table for the score, if it beats an entry. hs_new = its offset, or
; &FF. A tie goes below the older score.
.insert_score
    LDA #&FF : STA hs_new
    LDX #0
.is_find
    LDA hs_data + 3,X : CMP score_hi : BCC is_found : BNE is_next
    LDA hs_data + 4,X : CMP score_lo : BCC is_found
.is_next
    TXA : CLC : ADC #5 : TAX
    CPX #HS_ENTRIES * 5 : BNE is_find
    RTS
.is_found
    STX hs_new
    TXA : CLC : ADC #5 : STA tmp
    LDY #HS_ENTRIES * 5 - 1
.is_shift                           ; the entries below move down one, the last drops off
    CPY tmp : BCC is_put
    LDA hs_data - 5,Y : STA hs_data,Y
    DEY : BPL is_shift
.is_put
    LDA #' ' : STA hs_data,X : STA hs_data + 1,X : STA hs_data + 2,X
    LDA score_hi : STA hs_data + 3,X
    LDA score_lo : STA hs_data + 4,X
    RTS

; Sound X / 4 from sfx_data as an OSWORD 7 block; returns X = the next sound's.
.sound
    LDY #0
.snd_copy
    LDA sfx_data,X : STA sound_blk,Y
    LDA #0 : STA sound_blk + 1,Y    ; every amplitude is an envelope: high bytes 0
    INX : INY : INY : CPY #8 : BNE snd_copy
    STX sfx_x
    LDX #LO(sound_blk) : LDY #HI(sound_blk) : LDA #7 : JSR OSWORD
    LDX sfx_x
    RTS

.play_sfx
    LDX #0
.ps_bit
    LSR sfx : BCS ps_play
    INX : INX : INX : INX
    BNE ps_next
.ps_play
    CPX #SND_HIT : BCC ps_one
    BEQ ps_tune
    LDX #SND_POWER
.ps_tune                            ; a tune: tune_step sends a note a frame, well before
    STX tune_x : LDA #4 : STA tune_n    ; the last one ends. A jingle straight after the hit
    LDX #SND_HIT + 4                ; tune replaces it: its first note cuts the tune off
    BNE ps_next
.ps_one
    JSR sound
.ps_next
    LDA sfx : BNE ps_bit
.tune_step
    LDA tune_n : BEQ keyv_none
    DEC tune_n
    LDX tune_x : JSR sound : STX tune_x
.keyv_none
    RTS

.play_tune                          ; four notes, queued
    LDA #0 : STA tune_n             ; they cut off a tune still going out
    JSR sound : JSR sound : JSR sound
    JMP sound

; channel (+ &10: cut off what it is playing), envelope (or -15..-1: a fixed loudness),
; pitch (noise: its type), duration
.sfx_data
    EQUB &11, 1, 220, 3             ; SFX_FIRE
    EQUB &12, 3, 230, 24            ; SFX_DIVE
    EQUB &10, 2, 6, 20              ; SFX_DIE: a second of crash
    EQUB &12, 3, 125, 20            ; SFX_RUMBLE: under it, falling (cuts off a dive)
    EQUB &13, 4, 101, 1 : EQUB 3, 4, 117, 1 : EQUB 3, 4, 129, 1 : EQUB 3, 4, 149, 3
    EQUB &13, 4, 129, 1 : EQUB 3, 4, 149, 1 : EQUB 3, 4, 165, 1 : EQUB 3, 4, 197, 4
    EQUB &13, 4, 101, 2 : EQUB 3, 4, 117, 2 : EQUB 3, 4, 129, 2 : EQUB 3, 4, 149, 6
    EQUB &13, 4, 129, 4 : EQUB 3, 4, 117, 4 : EQUB 3, 4, 105, 4 : EQUB 3, 4, 89, 10
SND_HIT = 4 * 4
SND_POWER = 8 * 4
SND_WAVE = 12 * 4
SND_OVER = 16 * 4

; VDU strings

.vdu_setup
    EQUB vdu_setup_end - vdu_setup - 1
    EQUB 22, 2                      ; MODE 2: logical colours 0-7 are the physical ones
    EQUB 23, 1, 0, 0, 0, 0, 0, 0, 0, 0   ; cursor off
    EQUB 19, PULSE_COLOUR, 3, 0, 0, 0    ; yellow until the pulse takes over
    EQUB 19, STAR_COLOUR, 7, 0, 0, 0     ; a star alone: white
    EQUB 19, 9, 1, 0, 0, 0          ; 9-15: a sprite colour over a star shows the sprite
    EQUB 19, 10, 3, 0, 0, 0
    EQUB 19, 11, 3, 0, 0, 0
    EQUB 19, 12, 4, 0, 0, 0
    EQUB 19, 13, 5, 0, 0, 0
    EQUB 19, 14, 6, 0, 0, 0
    EQUB 19, 15, 7, 0, 0, 0
.vdu_setup_end

.txt_hud                            ; digits are drawn by print_hud
    EQUB 6, 17, 7, 31, 4, 0 : EQUS "0"

.lo_end

ORG &0E00

.main_start

; ======================================================================================
; Title screen and high scores
; ======================================================================================

; Unpack title_screen onto the clear MODE 7 screen (see tools/title.mjs), then fill in
; the table.
.draw_title
    LDA #LO(title_screen) : STA ptr0 : LDA #HI(title_screen) : STA ptr0 + 1
    LDA #LO(MODE7_SCREEN) : STA ptr1 : LDA #HI(MODE7_SCREEN) : STA ptr1 + 1
.dt_next
    JSR dt_byte : BEQ dt_run
    CMP #32 : BCS dt_one
    ADC ptr1 : STA ptr1             ; carry clear: skip A cells
    BCC dt_next
    INC ptr1 + 1 : BCS dt_next
.dt_run
    JSR dt_byte : BNE dt_count
    JMP stamp_scores
.dt_count
    TAX
    JSR dt_byte
    BNE dt_put                      ; never 0
.dt_one
    LDX #1
.dt_put                             ; X copies of A; Y = 0
    STA (ptr1),Y
    INC ptr1 : BNE dt_more
    INC ptr1 + 1
.dt_more
    DEX : BNE dt_put
    BEQ dt_next
.dt_byte                            ; A = the next byte, flags set; Y = 0
    LDY #0
    LDA (ptr0),Y
    INC ptr0 : BNE dt_got
    INC ptr0 + 1
.dt_got
    CMP #0
    RTS

; Run update_formation, each bullet's update and update_diver in the order the beam
; passes them. Objects low on screen go first, their plots queued for the start of the
; next frame: chasing the beam down to them would leave too little time before vsync,
; and drawn then, ahead of the beam, they still show in the same frame as the rest. An
; idle ship's bullet fires low on screen, so it goes first too. An idle enemy bullet or
; diver goes last: a launch needs no drawing and a shot starts high up.
.update_in_beam_order
    LDA frame : AND #3 : TAX
    LDA row_y,X : STA order_key
    LDX #BULLETS - 1
.ubo_bullet
    LDA #PLAYER_Y - 4 : STA order_key + 1,X
    LDA bullets_on,X : BEQ ubo_bullet_next
    LDA bullets_y,X : STA order_key + 1,X
.ubo_bullet_next
    DEX : BPL ubo_bullet
    LDA bonus_on : BEQ ubo_diver    ; the capsule takes the second bullet's turn
    LDA bonus_y : STA order_key + 2
.ubo_diver
    LDA #&FF : STA order_key + 3
    LDA diver_state : BEQ ubo_abullets
    LDA diver_y : STA order_key + 3
.ubo_abullets
    LDX #ABULLETS - 1
.ubo_abullet
    LDA #&FF : STA order_key + 4,X
    LDA abullets_on,X : BEQ ubo_abullet_next
    LDA abullets_y,X : STA order_key + 4,X
.ubo_abullet_next
    DEX : BPL ubo_abullet
    LDA #0 : STA order_done
    INC defer
    LDY #ORDER_N - 1
.ubo_low
    LDA order_key,Y : CMP #EARLY_Y : BCC ubo_low_next
    CMP #&FF : BEQ ubo_low_next
    LDA #&FF : STA order_key,Y
    STY order_idx
    JSR ubo_run
    LDY order_idx
.ubo_low_next
    DEY : BPL ubo_low
    LDA #0 : STA defer
.ubo_next                           ; the active entry highest on screen; its key becomes &FF
    LDA #&FF : STA tmp
    LDX #ORDER_N - 1
.ubo_scan
    LDA order_key,X : CMP tmp : BCS ubo_skip
    STA tmp : TXA : TAY
.ubo_skip
    DEX : BPL ubo_scan
    LDA tmp : CMP #&FF : BEQ ubo_rest
    CMP #DEFER_Y : BCC ubo_now      ; low: queued, and so is everything after it
    STA defer
.ubo_now
    LDA #&FF : STA order_key,Y
    JSR ubo_run
    JMP ubo_next
.ubo_rest                           ; then the idle ones, which may fire
    LDA #0 : STA defer
    LDY #ORDER_N - 1
.ubo_idle
    LDA order_done : AND bit_of,Y : BNE ubo_idle_next
    STY order_key                   ; free now: holds the index across the call
    JSR ubo_run
    LDY order_key
.ubo_idle_next
    DEY : BPL ubo_idle
    RTS
.ubo_run                            ; Y = entry
    LDA order_done : ORA bit_of,Y : STA order_done
    LDA ubo_lo,Y : STA order_vec
    LDA ubo_hi,Y : STA order_vec + 1
    JMP (order_vec)

.bit_of
    EQUB 1, 2, 4, 8, 16, 32, 64, 128
.ubo_lo
    EQUB LO(update_formation), LO(update_bullet_0), LO(update_bullet_1), LO(update_diver)
    EQUB LO(update_abullet_0), LO(update_abullet_1), LO(update_abullet_2), LO(update_abullet_3)
.ubo_hi
    EQUB HI(update_formation), HI(update_bullet_0), HI(update_bullet_1), HI(update_diver)
    EQUB HI(update_abullet_0), HI(update_abullet_1), HI(update_abullet_2), HI(update_abullet_3)

; Cycle the flagships' yellow (PULSE_COLOUR) through pulse_colours, while the beam is
; in vblank. In MODE 2 each logical colour is one ULA palette entry.
.pulse_flagships
    LDA frame : LSR A : LSR A : AND #7 : TAX
    LDA pulse_colours,X : EOR #PULSE_COLOUR * 16 + 7    ; the ULA stores colours inverted
    STA ULA_PALETTE
    EOR #STAR_COLOUR * 16           ; and its copy with the star bit set
    STA ULA_PALETTE
    RTS

.pulse_colours                      ; physical colours, 8 frames each
    EQUB 3, 3, 7, 7, 3, 3, 1, 1

; ======================================================================================
; Starfield
; ======================================================================================

; Each moving star: erase it, step it down a row, draw it. A star that leaves the
; bottom comes back at STAR_TOP further right. About 45us a moving star, 55us at 2px.
.update_stars_top                   ; the top band, and stars about to wrap into it
    LDA #&80 : BNE us_begin
.update_stars_rest                  ; after update_stars_top: the stars it didn't move
    LDA #&40 : BNE us_begin
.update_stars                       ; every star
    LDA #0
.us_begin                           ; stars 0-9 move 2px a frame, 10-19 1px, 20-29 1px on even frames
    STA tmp2
    LDA #0 : STA ptr0               ; ptr0 = star_hi * 256, Y = star_lo
    LDX #NUM_STARS - 1
    LDA frame : LSR A : BCC us_star
    LDX #2 * NUM_STARS / 3 - 1
.us_star
    BIT tmp2 : BMI us_top : BVC us_go
    LDA frame : CMP star_done,X : BNE us_go
    BEQ us_next
.us_top
    LDA star_y,X : CMP #STAR_BAND : BCC us_mark
    CMP #256 - 2 : BCC us_next      ; 2px a frame at most
.us_mark
    LDA frame : STA star_done,X
.us_go
    LDA star_hi,X : STA ptr0 + 1
    LDY star_lo,X
    LDA (ptr0),Y : EOR star_vis,X : STA (ptr0),Y        ; erase
    CPX #NUM_STARS / 3 : BCS us_one
    INC star_y,X : BEQ us_wrap
    LDA star_y,X : AND #7 : BEQ us_cell2
    INY
.us_one
    INC star_y,X : BEQ us_wrap
    LDA star_y,X : AND #7 : BEQ us_cell1
    INY
.us_draw
    TYA : STA star_lo,X
    LDA (ptr0),Y : EOR star_vis,X : STA (ptr0),Y        ; draw
.us_next
    DEX : BPL us_star
    RTS
.us_cell2
    JSR us_cell : JMP us_one
.us_cell1
    JSR us_cell : JMP us_draw
.us_cell                            ; row 7 to the top row of the next character row
    TYA : CLC : ADC #LO(640 - 7) : TAY
    LDA ptr0 + 1 : ADC #HI(640 - 7) : STA ptr0 + 1 : STA star_hi,X
    RTS
.us_wrap
    LDA #STAR_TOP : STA star_y,X
    LDA star_x,X : CLC : ADC #STAR_X_STEP : CMP #160 : BCC us_x
    SBC #160
.us_x
    STA star_x,X
    JSR star_place
    LDY ptr0 : LDA #0 : STA ptr0
    LDA star_vis,X : BEQ us_draw    ; twinkled out: stays out
    LDA star_bit,X : STA star_vis,X
    JMP us_draw

; Every TWINKLE_RATE frames, bring back the two stars that are out and blink out the
; next two.
.twinkle_stars
    LDA frame : AND #TWINKLE_RATE - 1 : BNE ts_done
    JSR twinkle_pair
    LDA twinkle_i : CLC : ADC #TWINKLE_STEP : CMP #NUM_STARS / 2 : BCC ts_next
    SBC #NUM_STARS / 2
.ts_next
    STA twinkle_i
    JMP twinkle_pair
.ts_done
    RTS

; Toggle stars twinkle_i and twinkle_i + NUM_STARS / 2, in the order before grouping.
.twinkle_pair
    LDX twinkle_i : LDA star_of,X : TAX : JSR star_toggle
    TXA : CLC : ADC #NUM_STARS / 6 : TAX    ; the same speed group: 5 on
    ; fall through

; X = star. Flip its pixel and whether it is shown.
.star_toggle
    LDA star_lo,X : STA ptr0 : LDA star_hi,X : STA ptr0 + 1
    LDY #0
    LDA (ptr0),Y : EOR star_bit,X : STA (ptr0),Y
    LDA star_vis,X : EOR star_bit,X : STA star_vis,X
    RTS

; X = star. From star_x / star_y: star_lo / star_hi / star_bit, ptr0 = the address,
; Y = 0. star_vis is left alone.
.star_place
    LDA star_y,X : LSR A : LSR A : LSR A : TAY
    LDA star_x,X : LSR A
    LDA #&80 : BCC spl_left         ; odd x: the right pixel
    LSR A
.spl_left
    STA star_bit,X
    LDA star_x,X : ROL A : ROL A : ROL A : AND #3 : STA tmp   ; as screen_ptrs
    LDA star_x,X : AND #&3E : ASL A : ASL A
    ADC crow_lo,Y : STA ptr0
    LDA crow_hi,Y : ADC tmp : STA ptr0 + 1 : STA star_hi,X
    LDA star_y,X : AND #7 : ORA ptr0 : STA ptr0 : STA star_lo,X  ; cell addresses are multiples of 8
    LDY #0
    RTS

; Place and draw every star, all shown, then twinkle the first pair out.
.init_stars
    LDX #NUM_STARS - 1
.is_star
    LDA star_x0,X : STA star_x,X
    LDA star_y0,X : STA star_y,X
    JSR star_place
    LDA star_bit,X : STA star_vis,X
    EOR (ptr0),Y : STA (ptr0),Y
    DEX : BPL is_star
    LDA #0 : STA twinkle_i
    JMP twinkle_pair

; ======================================================================================
; Raster clock
; ======================================================================================

; Wait until the beam has passed pixel rows A..X, so the object drawn there next is
; not scanned until the following frame. (A is unused: everything above X is passed.)
.beam_guard
    LDA defer : BNE bg_done         ; queued: drawn next frame, ahead of the beam
    TXA : LSR A : LSR A : CLC : ADC #BEAM_TOP + 2 : STA guard_bot
.bg_wait
    LDA USR_T2H : EOR #&FF          ; elapsed time in 256us units
    CMP guard_bot : BCC bg_wait
.bg_done
    RTS

; ======================================================================================
; Player
; ======================================================================================

; One pixel per frame. Runs straight after vsync, so no beam guard is needed: the beam
; is far from the bottom rows. Spare ships are drawn here too, one a frame up to lives - 1.
; A hit ship blinks out, then the last spare slides along and up to PLAYER_START.
.update_player
    LDA player_state : BEQ up_play
    LDX #0 : STX keys               ; out of play: no moving or firing
    CMP #PS_SLIDE : BEQ up_slide : BCS up_ret
    DEC player_t : BEQ up_gone
    LDA player_t : SEC : SBC #DIE_TIME - FLASH_TIME : BCC up_blink
    TAX : LDA flash_ula,X : STA bg_colour
.up_blink
    LDA player_t : AND #DIE_BLINK - 1 : BNE up_ret
    JMP draw_player
.up_gone                            ; the last blink hid it
    LDA #PS_OVER
    LDX lives : BEQ up_state
    DEC ships_shown
    LDA ships_shown : JSR spare_x : STA player_x    ; the last spare becomes the ship
    LDA #SPARE_Y : STA player_row
    LDA #PS_SLIDE
.up_state
    STA player_state
.up_ret
    RTS
.up_slide
    JSR draw_player                 ; erase
    LDA player_x : CMP #PLAYER_START : BEQ up_rise
    INC player_x : INC player_x     ; spares sit at even x, as PLAYER_START is
    JMP draw_player
.up_rise
    DEC player_row
    JSR draw_player
    LDA player_row : CMP #PLAYER_Y : BNE up_ret
    LDA #PS_PLAY : STA player_state
    RTS
.up_play
    LDX ships_shown : INX : CPX lives : BCS up_keys
    STX ships_shown : DEX : TXA : JSR spare_x : STA draw_x
    LDA #SPARE_Y : STA draw_y
    LDA #SPR_PLAYER : STA draw_id
    JSR plot_image
.up_keys
    LDA keys : AND #KEY_LEFT : BEQ up_not_left
    LDA player_x : BEQ up_done
    DEC player_x
    LDA player_x                    ; moving left: delta sits at the new x
    JMP up_move
.up_not_left
    LDA keys : AND #KEY_RIGHT : BEQ up_done
    LDA player_x : CMP #PLAYER_MAX_X : BCS up_done
    INC player_x                    ; moving right: delta sits at the old x (still in A)
.up_move
    STA draw_x
    LDA #PLAYER_Y : STA draw_y
    LDA #SPR_PLAYER : STA draw_id
    JMP plot_delta
.up_done
    RTS

; A = spare ship: A = its x
.spare_x
    STA tmp : ASL A : ASL A : ADC tmp : ASL A
    RTS

.draw_player
    LDA #SPR_PLAYER : STA draw_id
    LDA player_x : STA draw_x
    LDA player_row : STA draw_y
    JMP plot_image


; ======================================================================================
; Player bullets (one on screen at a time, two with the double shot)
; ======================================================================================

; Each bullet lives in bullets_on/x/y and is updated through the zero page working copy.
.update_bullet_0
    LDX #0 : BEQ ub_slot
.update_bullet_1                    ; a single shot leaves this slot to the capsule
    LDA power : ORA bullets_on + 1 : BNE ub_1
    LDA bonus_on : BEQ up_done
    JMP update_bonus
.ub_1
    LDX #1
.ub_slot
    JSR bullet_load
    JSR update_bullet
    LDX bullet_idx
    JMP bullet_save

.bullet_load
    STX bullet_idx
    LDA bullets_on,X : STA bullet_on
    LDA bullets_x,X : STA bullet_x
    LDA bullets_y,X : STA bullet_y
    RTS

.bullet_save
    LDA bullet_on : STA bullets_on,X
    LDA bullet_x : STA bullets_x,X
    LDA bullet_y : STA bullets_y,X
    RTS

.update_bullet
    LDA bullet_on : BNE ub_move
    LDA fire_cool : BNE ub_done
    LDA keys : AND #KEY_FIRE : BEQ ub_done
    LDA #FIRE_DELAY : STA fire_cool
    LDA player_x : CLC : ADC #3 : STA bullet_x  ; over the ship's nose
    LDA #PLAYER_Y - 4 : STA bullet_y
    LDA #1 : STA bullet_on
    SFX SFX_FIRE
    LDA #PLAYER_Y - 4 : LDX #PLAYER_Y - 1 : JSR beam_guard
    JMP draw_bullet
.ub_move
    LDA bullet_y : CLC : ADC #3 : TAX
    LDA bullet_y : SEC : SBC #BULLET_SPEED
    JSR beam_guard                  ; old and new positions together
    LDA bullet_y : SEC : SBC #BULLET_SPEED
    CMP #BULLET_TOP : BCC ub_off
    STA bullet_y : STA draw_y
    LDA bullet_x : STA draw_x
    LDA #SPR_BULLET_STEP : STA draw_id
    JSR plot_image                  ; erases the old bullet and draws the new one
    JMP check_bullet_hits
.ub_off
    JSR draw_bullet                 ; erase
    LDA #0 : STA bullet_on
.ub_done
    RTS

.draw_bullet
    LDA #SPR_BULLET : STA draw_id
    LDA bullet_x : STA draw_x
    LDA bullet_y : STA draw_y
    JMP plot_image

.kill_bullet
    LDA bullet_y : LDX bullet_y : JSR beam_guard_alien
    JSR draw_bullet
    LDA #0 : STA bullet_on
    RTS

; The bullet is 2 pixels wide and 4 rows tall. It overlaps an alien at (ax, ay)
; when bullet_x - ax is -1..ALIEN_W - 1 and bullet_y - ay is -3..ALIEN_H - 1.
.check_bullet_hits
    LDA diver_state : BEQ cbh_form
    LDA bullet_y : SEC : SBC diver_y : CLC : ADC #3
    CMP #ALIEN_H + 3 : BCS cbh_form
    LDA lead_gone : BNE cbh_wing
    LDA bullet_x : SEC : SBC diver_x : CLC : ADC #1
    CMP #ALIEN_W + 1 : BCS cbh_wing
    JSR kill_bullet
    LDA diver_y : LDX diver_y : JSR beam_guard_alien
    JSR draw_diver                  ; erase
    LDX diver_slot : LDA #ALIVE_GONE : STA alive,X
    LDA wing_on : STA lead_gone     ; a wingman flies on along the diver's path
    BNE cbh_scored
    BEQ cbh_over
.cbh_wing
    LDA wing_on : BEQ cbh_form
    LDA bullet_x : SEC : SBC wing_x : CLC : ADC #1
    CMP #ALIEN_W + 1 : BCS cbh_form
    JSR kill_bullet
    LDA diver_y : LDX diver_y : JSR beam_guard_alien
    JSR draw_wing                   ; erase
    LDX wing_slot : LDA #ALIVE_GONE : STA alive,X
    STA wing_on
    LDA lead_gone : BEQ cbh_scored
    LDA #0
.cbh_over                           ; A = 0: the dive is over
    STA diver_state : STA diver_wrap
.cbh_scored
    DEC alive_count
    JSR bonus_drop
    SFX SFX_HIT
    LDA #&05 : JMP add_score        ; 50 points (BCD, HUD adds a trailing 0)

.cbh_form
    ; the row whose aliens the bullet's rows overlap: bullet_y + 3 - row_y is 0..ALIEN_H + 2
    LDX #FORM_ROWS - 1
.cbh_row
    LDA bullet_y : CLC : ADC #3 : SEC : SBC row_y,X
    CMP #ALIEN_H + 3 : BCC cbh_rowok
    DEX : BPL cbh_row
    RTS
.cbh_rowok
    STX tmp2
    TXA : ASL A : ADC tmp2 : ASL A : TAX  ; first slot = row * 6
.cbh_col                            ; breathing spaces the columns unevenly: try each
    LDA alive,X : CMP #ALIVE_HOME : BNE cbh_next
    JSR slot_pos
    LDA bullet_x : CLC : ADC #1 : SEC : SBC slot_x
    CMP #ALIEN_W + 1 : BCC cbh_hit
.cbh_next
    INX : LDA slot_col,X : BNE cbh_col
    RTS
.cbh_hit
    STX loop_i
    JSR kill_bullet
    LDX loop_i : JSR slot_pos : LDA slot_y : TAX : JSR beam_guard_alien
    LDX loop_i
    JSR draw_slot                   ; erase the alien
    LDX loop_i : LDA #ALIVE_GONE : STA alive,X
    DEC alive_count
    SFX SFX_HIT
    LDA #&01 : JMP add_score        ; 10 points

; beam_guard for an alien-high object: A = top row of one position, X = top row of another.
.beam_guard_alien
    STX tmp
    CMP tmp : BCC bg8_ordered       ; A < X
    TAX : LDA tmp
.bg8_ordered
    PHA : TXA : CLC : ADC #ALIEN_H - 1 : TAX : PLA
    JMP beam_guard

; ======================================================================================
; Any alien fires while it swoops: one burst of 2 or 3 shots straight down, once it is
; low and near the player. alien_fire only decides; the shot is drawn by an idle enemy
; bullet in beam order.
; ======================================================================================

.alien_fire
    LDA #0 : STA afire_req : STA wing_req   ; a shot no bullet was free for is dropped
    LDA player_state : BNE af_end   ; no shots at a ship that is out of play
    LDA diver_state : CMP #DIVER_DIVE : BNE af_end
    LDA burst_left : BNE af_burst
    LDA afire_armed : BEQ af_done
    LDX level
    LDA diver_y : CMP afire_tops,X : BCC af_done
    LDA afire_ranges,X : ASL A : STA tmp
    LDA diver_x : SEC : SBC player_x : SEC : SBC #(6 - ALIEN_MID) AND &FF  ; middles: x + ALIEN_MID and x + 6
    CLC : ADC afire_ranges,X
    CMP tmp : BEQ af_near : BCS af_done
.af_near
    LDA #0 : STA afire_armed
    JSR random : AND #1 : CLC : ADC burst_mins,X : STA burst_left    ; min or min + 1
    LDA #1 : STA burst_gap
.af_burst
    DEC burst_gap : BNE af_done
    LDA #BURST_GAP : STA burst_gap
    LDA diver_y : CLC : ADC #ALIEN_H : STA afire_y
    CMP #AFIRE_LOW + 1 : BCS af_end ; too close: the rest of the burst is lost
    LDA lead_gone : BNE af_wing
    LDA diver_x : CLC : ADC #ALIEN_MID : STA afire_x  ; under its middle
    INC afire_req
.af_wing
    LDA wing_on : BEQ af_shot
    LDA wing_x : CLC : ADC #ALIEN_MID : STA wing_fx
    INC wing_req
.af_shot
    DEC burst_left
.af_done
    RTS
.af_end
    LDA #0 : STA burst_left
    RTS

; A = rnd = the next byte of an 8-bit maximal-length LFSR (x^8 + x^4 + x^3 + x^2 + 1).
.random
    LDA rnd : ASL A : BCC rn_done
    EOR #&1D
.rn_done
    STA rnd
    RTS

.update_abullet_0
    LDX #0 : BEQ ua_slot
.update_abullet_1
    LDX #1 : BNE ua_slot
.update_abullet_2
    LDX #2 : BNE ua_slot
.update_abullet_3
    LDX #3
.ua_slot
    STX abullet_idx
    LDA abullets_on,X : BNE ua_move
    LDA afire_req : BEQ ua_wing     ; idle: take this frame's shot, if any
    LDA #0 : STA afire_req
    LDA afire_x
.ua_shoot
    STA abullets_x,X
    LDA #1 : STA abullets_on,X
    LDA afire_y : STA abullets_y,X
    JSR abullet_pos
    CMP #DEFER_Y : BCC ua_now       ; A = draw_y
    INC defer                       ; low: queued, drawn at the next frame's start
    JSR abullet_draw
    DEC defer
    RTS
.ua_now
    CLC : ADC #3 : TAX : JSR beam_guard
    JMP abullet_draw
.ua_wing
    LDA wing_req : BEQ ua_done
    LDA #0 : STA wing_req
    LDA wing_fx
    JMP ua_shoot
.ua_move
    LDA abullets_y,X : CLC : ADC #ABULLET_SPEED + 3 : BCC ua_guard
    LDA #255                        ; leaving the bottom: only the old position is on screen
.ua_guard
    TAX : JSR beam_guard            ; old and new positions together
    LDX abullet_idx
    LDA abullets_y,X : CMP #ABULLET_BOTTOM - ABULLET_SPEED + 1 : BCS ua_off
    JSR abullet_pos
    LDA #SPR_ABULLET_STEP : STA draw_id
    JSR plot_image                  ; erases the old bullet and draws the new one
    LDX abullet_idx
    LDA abullets_y,X : CLC : ADC #ABULLET_SPEED : STA abullets_y,X
    ; the ship: bullet_x - player_x is 0..7 and the bullet's rows meet its 8
    SEC : SBC #PLAYER_Y - 3 : CMP #11 : BCS ua_done
    LDA abullets_x,X : SEC : SBC player_x : CMP #8 : BCS ua_done
    LDA player_state : BNE ua_done  ; a ship out of play: the bullet passes
    JSR player_hit
.ua_off
    JSR abullet_pos
    JSR abullet_draw                ; erase
    LDX abullet_idx : LDA #0 : STA abullets_on,X
.ua_done
    RTS

; X = enemy bullet: draw_x / draw_y = where it is.
.abullet_pos
    LDA abullets_x,X : STA draw_x
    LDA abullets_y,X : STA draw_y
    RTS

.abullet_draw
    LDA #SPR_ABULLET : STA draw_id
    JMP plot_image

; ======================================================================================
; Formation: four rows. Row (frame MOD 4) steps this frame, so the block ripples. Its
; steps take turns: sway (the row slides a pixel, flapping every other time) and breathe (the formation
; spreads out or draws in a pixel from its middle, the outer columns and rows most
; often, without flapping). A breath moves an alien across, up or down, or diagonally.
; ======================================================================================

.update_formation
    LDA frame : AND #3 : STA form_row : TAX
    LDA row_y,X : STA draw_y
    LDA row_spr,X : ORA row_anim,X : STA draw_id
    LDA frame : AND #FLAP_MASK : BEQ uf_sway
    JMP uf_breathe

.uf_sway
    LDA row_x,X : STA old_x
    CLC : ADC row_dir,X : STA row_x,X       ; row_dir is 1 or -1
    CMP #FX_MIN : BEQ uf_flip
    CMP #FX_MAX : BNE uf_moved
.uf_flip
    LDA row_dir,X : EOR #&FE : STA row_dir,X    ; 1 <-> &FF
.uf_moved
    LDY #0
    LDA row_x,X : CMP old_x : BCS uf_right
    LDA frame : AND #FLAP_SKIP : BNE uf_dir     ; no flap: the plain delta
    LDA draw_id : EOR #1 : STA draw_id          ; moving left: the delta starts at the new frame
    BNE uf_flap
.uf_right
    DEY                             ; moving right: it sits at the old x
    LDA frame : AND #FLAP_SKIP : BNE uf_dir
.uf_flap
    LDA row_anim,X : EOR #1 : STA row_anim,X    ; flap: cross delta from frame to frame
    LDA draw_id : CLC : ADC #CROSS_OFS : STA draw_id
.uf_dir
    STY tmp2                        ; added to each alien's new x
    JSR uf_guard
.uf_col
    LDX loop_i
    LDA alive,X : CMP #ALIVE_HOME : BNE uf_next
    JSR slot_pos
    LDA slot_x : CLC : ADC tmp2 : STA draw_x
    JSR plot_delta
.uf_next
    INC loop_i
    LDX loop_i : LDA slot_col,X : BNE uf_col    ; stop when the next slot starts a row
    RTS

.uf_breathe
    LDA row_bofs,X : STA old_x
    CLC : ADC row_bdir,X : STA row_bofs,X
    BEQ uf_bflip
    CMP #BREATH_MAX * FORM_COLS : BNE uf_bmoved
.uf_bflip
    LDA #0 : SEC : SBC row_bdir,X : STA row_bdir,X
.uf_bmoved
    LDA row_bofs,X : CLC : ADC form_row : TAY : LDA vbreath,Y : STA new_y
    LDA old_x : CLC : ADC form_row : TAY : LDA vbreath,Y
    EOR #&FF : SEC : ADC new_y : STA new_y                  ; dy = new - old
    CLC : ADC row_y,X : STA row_y,X
    LDY new_y : BPL uf_bguard
    STA draw_y                      ; moving up: the deltas start at the new y
.uf_bguard
    LDA #ALIEN_H : JSR uf_guard_h   ; old and new rows: ALIEN_H + 1 high
.uf_bcol
    LDX loop_i
    LDA alive,X : CMP #ALIVE_HOME : BNE uf_bnext
    LDY form_row
    LDA row_bofs,Y : CLC : ADC slot_col,X : TAY : LDA breath,Y : STA tmp2
    LDA old_x : CLC : ADC slot_col,X : TAY : LDA breath,Y
    EOR #&FF : SEC : ADC tmp2 : STA tmp2                    ; dx = new - old
    ORA new_y : BEQ uf_bnext        ; this alien stays put
    JSR slot_pos
    LDA slot_x
    LDY tmp2 : CPY #1 : BNE uf_bx
    SBC #1                          ; moving right: the delta starts at the old x
.uf_bx
    STA draw_x
    LDY form_row : LDA row_spr,Y : ORA row_anim,Y
    LDY new_y : BEQ uf_bplot        ; across: the plain delta
    LDY tmp2 : BNE uf_bdiag
    CLC : ADC #VERT_OFS
    JMP uf_bplot
.uf_bdiag
    CPY new_y : BEQ uf_bdown        ; dx = dy: along the down diagonal
    CLC : ADC #UP_OFS
    JMP uf_bplot
.uf_bdown
    CLC : ADC #DOWN_OFS
.uf_bplot
    STA draw_id
    JSR plot_delta
.uf_bnext
    INC loop_i
    LDX loop_i : LDA slot_col,X : BNE uf_bcol
    RTS

; Wait for the beam to pass the row; loop_i = its first slot.
.uf_guard
    LDA #ALIEN_H - 1
.uf_guard_h                         ; A = height - 1
    CLC : ADC draw_y : TAX : LDA draw_y
    JSR beam_guard
    LDA form_row : ASL A : ADC form_row : ASL A : STA loop_i   ; row * 6
    RTS

; X = slot. EOR that alien at its formation position.
.draw_slot
    JSR slot_pos
    LDA slot_x : STA draw_x
    LDA slot_y : STA draw_y
    LDY slot_row,X
    LDA row_spr,Y : ORA row_anim,Y : STA draw_id
    JMP plot_image

; X = slot. slot_x / slot_y = where that alien sits in the formation now; X is preserved.
.slot_pos
    LDY slot_row,X
    LDA row_x,Y : CLC : ADC slot_px,X : STA slot_x
    LDA row_bofs,Y : ADC slot_col,X : TAY       ; carry clear: x < 256
    LDA slot_x : CLC : ADC breath,Y : STA slot_x
    LDY slot_row,X : LDA row_y,Y : STA slot_y
    RTS

; ======================================================================================
; Diver: one alien at a time peels off the formation in a half loop, swoops at the
; player, wraps from the bottom to the top and flies back to its slot.
; ======================================================================================

.update_diver
    LDA diver_state : BEQ ud_idle
    JMP ud_active
.ud_idle
    LDA player_state : BNE ud_done  ; no new dives until the next ship is in place
    LDA alive_count : CMP #RUSH_COUNT + 1 : BCS ud_count
    LDA dive_timer : CMP #RUSH_DELAY + 1 : BCC ud_count
    LDA #RUSH_DELAY : STA dive_timer
.ud_count
    DEC dive_timer : BNE ud_done
    LDX level : LDA dive_delays,X : STA dive_timer
    LDY #FORM_COUNT                 ; try every slot once at most
.ud_pick
    LDA diver_pick : CLC : ADC #DIVE_STRIDE
    CMP #FORM_COUNT : BCC ud_picked
    SBC #FORM_COUNT
.ud_picked
    STA diver_pick : TAX
    LDA alive,X : CMP #ALIVE_HOME : BEQ ud_launch
    DEY : BNE ud_pick
.ud_done
    RTS

.ud_launch                          ; the alien is already drawn where the diver starts
    LDA slot_row,X : CMP form_row : BNE ud_go
    LDA #1 : STA dive_timer         ; its row stepped this frame: launch next frame instead,
    TXA : SEC : SBC #DIVE_STRIDE    ; or the step and the first dive move would show together
    BCS ud_retry                    ; the same alien: the next one is likely in the next
    ADC #FORM_COUNT                 ; frame's row
.ud_retry
    STA diver_pick
    RTS
.ud_go
    SFX SFX_DIVE
    STX diver_slot
    LDA #ALIVE_DIVING : STA alive,X
    LDA #0 : STA wing_on : STA lead_gone
    INX                             ; the wingman: the next alien along the row, else the last
    LDA slot_col,X : BEQ ud_wing_left
    LDA alive,X : CMP #ALIVE_HOME : BEQ ud_wing
.ud_wing_left
    DEX : LDA slot_col,X : BEQ ud_solo
    DEX
    LDA alive,X : CMP #ALIVE_HOME : BNE ud_solo
.ud_wing
    STX wing_slot
    LDA #ALIVE_DIVING : STA alive,X
    JSR slot_pos : LDA slot_x : STA wing_x
    INC wing_on
.ud_solo
    LDX diver_slot
    JSR slot_pos
    LDA slot_x : STA diver_x
    LDA slot_y : STA diver_y
    LDY slot_row,X : LDA row_anim,Y : STA diver_anim
    LDA #0 : STA diver_t : STA diver_vx
    LDA #8 : STA diver_xf
    ; loop outward, unless that would run off the screen edge
    LDY #0
    LDA diver_x : CMP #PLAYER_MAX_X - 2 * LOOP_R + 1 : BCS ud_loop_left
    CMP #PLAYER_MAX_X / 2 : BCS ud_loop_set
    CMP #2 * LOOP_R : BCC ud_loop_set
.ud_loop_left
    DEY
.ud_loop_set
    STY diver_left
    LDA #DIVER_DIVE : STA diver_state
    STA afire_armed                 ; A = DIVER_DIVE
    ; fall through: it takes its first step this frame

.ud_active
    LDA diver_x : STA new_x
    LDA diver_y : STA new_y
    LDA diver_state : CMP #DIVER_DIVE : BEQ ud_dive
    JMP ud_return
.ud_dive
    LDA diver_anim : STA new_anim
    LDA frame : AND #FLAP_MASK OR FLAP_SKIP OR 3 : BNE ud_path
    LDA new_anim : EOR #1 : STA new_anim    ; flaps at the formation's rate
.ud_path
    LDX diver_t : CPX #LOOP_LEN : BCS ud_swoop
    INC diver_t
    LDA loop_dx,X
    LDY diver_left : BEQ ud_loop_dx
    EOR #&FF : CLC : ADC #1
.ud_loop_dx
    CLC : ADC new_x : STA new_x
    LDA loop_dy,X : CLC : ADC new_y : STA new_y
    JMP ud_clamp

.ud_swoop
    LDA new_y : CLC : ADC #DIVER_SPEED : STA new_y
    CMP #DIVER_BOTTOM : BCC ud_steer
    LDA #DIVER_RETURN : STA diver_state
    INC diver_wrap                  ; leave it drawn where it is; diver_reenter moves it
    RTS
.ud_steer                           ; accelerate toward the player; overshoot gives the weave
    LDA player_x : CMP new_x : BEQ ud_glide : BCC ud_pull_left
    LDA diver_vx : CMP #DIVE_VMAX : BEQ ud_glide
    INC diver_vx
    JMP ud_glide
.ud_pull_left
    LDA diver_vx : CMP #256 - DIVE_VMAX : BEQ ud_glide
    DEC diver_vx
.ud_glide                           ; x += vx / 16, keeping the fraction
    LDA diver_xf : CLC : ADC diver_vx       ; -24..39
    TAY : AND #15 : STA diver_xf
    TYA : CMP #&80 : ROR A : CMP #&80 : ROR A : CMP #&80 : ROR A : CMP #&80 : ROR A
    CLC : ADC new_x : STA new_x
.ud_clamp
    LDA new_x : CMP #PLAYER_MAX_X + 1 : BCC ud_move
    CMP #&C0 : LDA #0 : BCS ud_clamped      ; went below 0
    LDA #PLAYER_MAX_X
.ud_clamped
    STA new_x
    LDA #0 : STA diver_vx
    JMP ud_move

.ud_return                          ; descend to the slot row, slide to the slot column, dock
    LDX diver_slot : JSR slot_pos
    LDY slot_row,X : LDA row_anim,Y : STA new_anim  ; match the row's frame to dock
    LDA new_y : CMP slot_y : BEQ ud_slide : BCC ud_descend
    DEC new_y                       ; the row breathed up past it
    JMP ud_slide
.ud_descend
    ADC #DIVER_SPEED : STA new_y    ; carry clear
    CMP slot_y : BCC ud_slide
    LDA slot_y : STA new_y          ; don't overshoot a row at an odd height
.ud_slide
    LDA slot_x : CMP new_x : BEQ ud_move : BCC ud_rleft
    INC new_x
    JMP ud_move
.ud_rleft
    DEC new_x
.ud_move
    LDA wing_on : BEQ ud_draw       ; the wingman keeps its slot's offset, to dock with it
    LDX wing_slot : JSR slot_pos : LDA slot_x : STA wing_nx
    LDX diver_slot : JSR slot_pos   ; leaves the diver's slot in slot_x / slot_y
    LDA wing_nx : SEC : SBC slot_x : CLC : ADC new_x : STA wing_nx
    CMP #PLAYER_MAX_X + 1 : BCC ud_draw
    LDY #PLAYER_MAX_X
    CMP #&C0 : BCC ud_wfix
    LDY #0
.ud_wfix                            ; off the edge: slide the pair back on screen
    STY tmp
    LDA new_x : SEC : SBC wing_nx : CLC : ADC tmp : STA new_x
    STY wing_nx
.ud_draw
    LDA diver_y : LDX new_y : JSR beam_guard_alien
    JSR draw_pair                   ; erase
    LDA new_x : STA diver_x
    LDA new_y : STA diver_y
    LDA new_anim : STA diver_anim
    LDA wing_nx : STA wing_x
    JSR draw_pair
    LDA diver_state : CMP #DIVER_RETURN : BNE ud_flying
    LDA diver_y : CMP slot_y : BNE ud_flying
    LDA diver_x : CMP slot_x : BNE ud_flying
    LDA #DIVER_NONE : STA diver_state       ; docked: the images are already in the slots
    LDA #ALIVE_HOME
    LDX lead_gone : BNE ud_dock_wing
    LDX diver_slot : STA alive,X
.ud_dock_wing
    LDX wing_on : BEQ ud_flying
    LDX wing_slot : STA alive,X
.ud_flying
    RTS

; A diver that passed the bottom (or hit the ship) is still drawn down there. Move it
; to DIVER_TOP straight after vsync, while the beam is above both positions. Chasing
; the beam to the bottom instead would leave no time before the next vsync. The diver
; still takes its normal step later this frame, so it never pauses on screen.
.diver_reenter                      ; only called with diver_wrap set
    LDA #0 : STA diver_wrap
    LDA diver_y : PHA
    LDA #DIVER_TOP : STA diver_y
    JSR draw_pair                   ; draw at the top before the beam gets there
    PLA : STA diver_y
    JSR draw_pair                   ; erase at the bottom
    LDA #DIVER_TOP : STA diver_y
    RTS

.draw_pair
    JSR draw_diver
.draw_wing
    LDA wing_on : BEQ dd_done
    LDX wing_slot : LDA wing_x
    JMP dd_plot
.draw_diver                         ; unless it was shot
    LDA lead_gone : BNE dd_done
    LDX diver_slot : LDA diver_x
.dd_plot                            ; X = slot, A = x
    STA draw_x
    LDY slot_row,X
    LDA row_spr,Y : ORA diver_anim : STA draw_id
    LDA diver_y : STA draw_y
    JMP plot_image
.dd_done
    RTS

; A diving alien that reaches the ship costs a life and flies home from the top.
.check_player_hit
    LDA player_state : BNE cph_none
    LDA diver_state : CMP #DIVER_DIVE : BNE cph_none
    LDA diver_y : CMP #PLAYER_Y - ALIEN_H + 1 : BCC cph_none
    LDA lead_gone : BNE cph_wing
    LDA diver_x : JSR cph_near : BCC cph_crash
.cph_wing
    LDA wing_on : BEQ cph_none
    LDA wing_x : JSR cph_near : BCS cph_none
.cph_crash
    LDA #DIVER_RETURN : STA diver_state
    INC diver_wrap
    ; fall through

.player_hit
    SFX SFX_DIE OR SFX_RUMBLE
    LDA #0 : STA power
    DEC lives
    LDA #PS_DYING : STA player_state
    LDA #DIE_TIME : STA player_t
.cph_none
    RTS
.cph_near                           ; A = an alien's x: carry clear if it overlaps the ship
    SEC : SBC player_x : CLC : ADC #ALIEN_W - 1   ; 8-wide ship
    CMP #ALIEN_W + 7
    RTS

; ======================================================================================
; Sprite plotter
; ======================================================================================

; While defer is set, plots are queued instead; flush_plots draws them. EOR plots
; give the same picture in any order.
.queue_image
    LDA #0 : BEQ queue_plot
.queue_delta
    LDA #&80
.queue_plot
    ORA draw_id
    LDX queue_n
    STA queue_id,X
    LDA draw_x : STA queue_x,X
    LDA draw_y : STA queue_y,X
    INC queue_n
    RTS

.flush_plots
    LDX queue_n : BEQ fp_done
.fp_plot
    DEX : STX queue_n
    LDA queue_x,X : STA draw_x
    LDA queue_y,X : STA draw_y
    LDA queue_id,X : BMI fp_delta
    STA draw_id
    JSR plot_image
    JMP fp_next
.fp_delta
    AND #&7F : STA draw_id
    JSR plot_delta
.fp_next
    LDX queue_n : BNE fp_plot
.fp_done
    RTS

; EOR the pre-shifted image of sprite draw_id at pixel (draw_x, draw_y).
; Image data is stored column by column (all rows of byte 0, then byte 1, ...) so one
; X index walks every column; the column addresses are patched into the loop. Each
; image stores only the columns it uses, and the row loop starts at its last one.
.plot_image
    LDA defer : BNE queue_image
    LDA draw_x : AND #1 : STA tmp
    LDA draw_id : ASL A : ORA tmp : TAX
    LDA img_lo,X : STA PL_COL0 + 1
    LDA img_hi,X : STA PL_COL0 + 2
    LDA img_entry,X
    JMP plot

; EOR the delta image that moves sprite draw_id one pixel right, from draw_x to
; draw_x + 1. Applying it again moves it back, so a move left from x to x - 1 uses
; the delta at x - 1.
.plot_delta
    LDA defer : BNE queue_delta
    LDA draw_x : AND #1 : STA tmp
    LDA draw_id : ASL A : ORA tmp : TAX
    LDA dlt_lo,X : STA PL_COL0 + 1
    LDA dlt_hi,X : STA PL_COL0 + 2
    LDA dlt_entry,X

.plot                               ; A = offset of the first column's code from pl_col
    CLC : ADC #LO(pl_col) : STA pl_row + 1
    LDA #HI(pl_col) : ADC #0 : STA pl_row + 2
    LDY draw_id : LDA spr_h,Y : STA draw_h
    CPY pl_last_id : BNE pl_patch   ; the same image as last time (a row of aliens):
    LDA PL_COL0 + 1 : CMP pl_last_lo : BNE pl_patch   ; its columns are patched in already
    LDA PL_COL0 + 2 : CMP pl_last_hi : BEQ pl_patched
.pl_patch
    STY pl_last_id
    LDA PL_COL0 + 1 : STA pl_last_lo
    LDA PL_COL0 + 2 : STA pl_last_hi
    CLC
FOR c, 1, SPR_BYTES - 1
    LDA PL_COL0 - 9 * (c - 1) + 1 : ADC draw_h : STA PL_COL0 - 9 * c + 1
    LDA PL_COL0 - 9 * (c - 1) + 2 : ADC #0 : STA PL_COL0 - 9 * c + 2
NEXT
.pl_patched
    JSR screen_ptrs
    LDX #0
.pl_row
    JMP &FFFF                       ; patched: the image's last column
.pl_col                             ; 9 bytes per column, last column first
FOR c, SPR_BYTES - 1, 0, -1
    LDA &FFFF,X : BEQ P% + 6 : EOR (ptr0 + 2 * c),Y : STA (ptr0 + 2 * c),Y   ; a zero byte changes nothing
NEXT
    INX : CPX draw_h : BEQ pl_done
    INY : CPY #8 : BNE pl_row
    JSR next_cell
    JMP pl_row
.pl_done
    RTS
PL_COL0 = pl_col + 9 * (SPR_BYTES - 1)  ; column 0's LDA

; ptr0.. = the character cells holding byte columns draw_x DIV 2 .. + SPR_BYTES - 1 on the
; character row containing draw_y; Y = draw_y AND 7, the row inside the cell.
.screen_ptrs
    LDA draw_y : LSR A : LSR A : LSR A : TAY
    LDA draw_x : ROL A : ROL A : ROL A : AND #3 : STA tmp     ; draw_x DIV 64: the byte column * 8, high
    LDA draw_x : AND #&3E : ASL A : ASL A                     ; and low; carry clear (x < 160)
    ADC crow_lo,Y : STA ptr0
    LDA crow_hi,Y : ADC tmp : STA ptr0 + 1
FOR c, 1, SPR_BYTES - 1
    LDA ptr0 : ADC #8 * c : STA ptr0 + 2 * c
    LDA ptr0 + 1 : ADC #0 : STA ptr0 + 2 * c + 1
NEXT
    LDA draw_y : AND #7 : TAY
    RTS

; Step ptr0.. down one character row (640 bytes); Y = 0, the top row of the cell.
.next_cell                          ; unrolled: ptr0,Y would be absolute,Y
    CLC                             ; the high bytes never carry: screen < &8000
FOR c, 0, SPR_BYTES - 1
    LDA ptr0 + 2 * c : ADC #LO(640) : STA ptr0 + 2 * c
    LDA ptr0 + 2 * c + 1 : ADC #HI(640) : STA ptr0 + 2 * c + 1
NEXT
    LDY #0
    RTS

; ======================================================================================
; Keyboard, score and text
; ======================================================================================

; keys = KEY_* bits for Z, X and RETURN. Z wins if both directions are held.
.read_keys
    LDA #0 : STA keys
    LDX #KEY_Z : JSR key_down : BNE rk_right
    LDA #KEY_LEFT : STA keys
    BNE rk_fire
.rk_right
    LDX #KEY_X : JSR key_down : BNE rk_fire
    LDA #KEY_RIGHT : STA keys
.rk_fire
    LDX #KEY_RETURN : JSR key_down : BNE rk_done
    LDA keys : ORA #KEY_FIRE : STA keys
.rk_done
    RTS

; X = keyboard matrix code. Returns Z set if the key is down. Reading the VIA takes
; a few microseconds; OSBYTE 129 took ~130 a key. Interrupts are off so the OS can't
; reprogram port A halfway through.
.key_down
    SEI
    LDA #&03 : STA SYS_ORB          ; latch bit 3 low: stop the keyboard auto-scan
    LDA #&7F : STA SYS_DDRA         ; bits 0-6 select the key, bit 7 reads it
    STX SYS_ORA_NH
    LDA SYS_ORA_NH
    LDX #&0B : STX SYS_ORB          ; auto-scan back on
    CLI
    AND #&80 : EOR #&80             ; bit 7 set = down
    RTS

; A = BCD points to add.
.add_score
    SED
    CLC : ADC score_lo : STA score_lo
    LDA score_hi : ADC #0 : STA score_hi
    CLD
    INC hud_dirty
    RTS

.print_hud
    LDA #0 : STA hud_dirty
    LDA score_hi : LSR A : LSR A : LSR A : LSR A
    LDX #0 : JSR print_digit
    LDA score_hi : AND #&0F
    LDX #1 : JSR print_digit
    LDA score_lo : LSR A : LSR A : LSR A : LSR A
    LDX #2 : JSR print_digit
    LDA score_lo : AND #&0F
    LDX #3
    ; fall through

; Copy digit A (0-9) into text column X of the top text row. Writing screen memory
; directly costs ~400 cycles a digit; printing through OSWRCH costs thousands.
.print_digit
    ASL A : ASL A : ASL A : PHA             ; digit * 8
    TXA : ASL A : ASL A : ASL A : STA draw_x    ; column * 8 pixels
    LDA #0 : STA draw_y
    JSR screen_ptrs                         ; Y = 0
    PLA : TAX
.pd_copy
    LDA digits,X : STA (ptr0),Y
    LDA digits + GLYPHS * 8,X : STA (ptr1),Y
    LDA digits + GLYPHS * 16,X : STA (ptr2),Y
    LDA digits + GLYPHS * 24,X : STA (ptr3),Y
    INX : INY : CPY #8 : BNE pd_copy
    RTS

; EOR glyph A into text column X of the banner row. It uses colours 0-7 and the stars
; colour 8, so a star under it survives, and EORing it again removes it.
.eor_glyph
    ASL A : ASL A : ASL A : PHA
    TXA : ASL A : ASL A : ASL A : STA draw_x
    LDA #BANNER_Y : STA draw_y
    JSR screen_ptrs                         ; Y = 0
    PLA : TAX
.eg_copy
    LDA digits,X : EOR (ptr0),Y : STA (ptr0),Y
    LDA digits + GLYPHS * 8,X : EOR (ptr1),Y : STA (ptr1),Y
    LDA digits + GLYPHS * 16,X : EOR (ptr2),Y : STA (ptr2),Y
    LDA digits + GLYPHS * 24,X : EOR (ptr3),Y : STA (ptr3),Y
    INX : INY : CPY #8 : BNE eg_copy
    RTS

; X/Y = address of a length-prefixed VDU byte string.
.print_vdu
    STX ptr0 : STY ptr0 + 1
    LDY #0
    LDA (ptr0),Y : STA tmp
.pv_loop
    INY
    LDA (ptr0),Y : JSR OSWRCH
    CPY tmp : BNE pv_loop
    RTS

; ======================================================================================
; Data
; ======================================================================================

INCLUDE "title.asm"

.hs_data                            ; 5 x (3 characters, BCD score high, low)
    EQUS "LDA" : EQUB &05, &00
    EQUS "STA" : EQUB &04, &00
    EQUS "JMP" : EQUB &03, &00
    EQUS "RTS" : EQUB &02, &00
    EQUS "NOP" : EQUB &01, &00
.hs_new                             ; offset of the entry to type initials into, or &FF
    EQUB &FF
.txt_prompts
    EQUS "PRESS ANY KEY"
    EQUS "TYPE INITIALS"
.txt_game_over
    EQUB 12, 31, 6, 15 : EQUS "GAME OVER"
.txt_mode7
    EQUB 12, 22, 7, 23, 1, 0, 0, 0, 0, 0, 0, 0, 0      ; MODE 7, cursor off

; Screen address of each character row
.crow_lo
FOR r, 0, 31 : EQUB LO(SCREEN + r * 640) : NEXT
.crow_hi
FOR r, 0, 31 : EQUB HI(SCREEN + r * 640) : NEXT

; Formation slot layout, slot = row * FORM_COLS + col
.slot_px
FOR i, 0, FORM_COUNT - 1 : EQUB (i MOD FORM_COLS) * COL_STEP : NEXT
.slot_row
FOR i, 0, FORM_COUNT - 1 : EQUB i DIV FORM_COLS : NEXT
.star_of                            ; star j for i < NUM_STARS / 2: i = 3 * (j MOD 10) + j DIV 10
FOR i, 0, NUM_STARS / 2 - 1 : EQUB 10 * (i MOD 3) + i DIV 3 : NEXT
.star_x0
FOR j, 0, NUM_STARS - 1 : i = 3 * (j MOD 10) + j DIV 10 : EQUB (i * 135 + i * i * 10 + 7) MOD 160 : NEXT    ; quadratic: no lines
.star_y0
FOR j, 0, NUM_STARS - 1 : i = 3 * (j MOD 10) + j DIV 10 : EQUB STAR_TOP + (i * 189 + i * i * 8) MOD (256 - STAR_TOP) : NEXT

.slot_start                         ; alive[] at the start of a wave
FOR i, 0, FORM_COUNT - 1
    inset = VAL(MID$(FORM_INSET, i DIV FORM_COLS + 1, 1))
    EQUB -((i MOD FORM_COLS >= inset) AND (i MOD FORM_COLS < FORM_COLS - inset)) * ALIVE_HOME
NEXT
.slot_col                           ; one extra entry so the last row's walk ends on 0
FOR i, 0, FORM_COUNT : EQUB i MOD FORM_COLS : NEXT

; Per level: wave 1 to 5, then 6 on
.dive_delays                        ; frames between dives
    EQUB 80, 55, 40, 30, 22, 16
.burst_mins                         ; a burst is this many shots or one more
    EQUB 2, 3, 3, 3, 3, 3
.afire_tops                         ; a diver opens fire once it is below this row
    EQUB 96, 80, 64, 56, 48, 40
.afire_ranges                       ; and its middle is within this many pixels of the player's
    EQUB 24, 32, 40, 44, 48, 52

.row_y0
FOR r, 0, FORM_ROWS - 1 : EQUB FORM_Y + r * ROW_STEP : NEXT
.breath                             ; [breath * FORM_COLS + col]: x offset from the centre out
FOR b, 0, BREATH_MAX
    FOR c, 0, FORM_COLS - 1
        EQUB ((1 + 2 * (2 * c < FORM_COLS - 1)) * INT(ABS(2 * c - FORM_COLS + 1) * b / (FORM_COLS - 1) + 0.5)) AND &FF
    NEXT
NEXT
.vbreath                            ; [breath * FORM_COLS + row]: y offset from the middle out
FOR b, 0, BREATH_MAX
    FOR r, 0, FORM_COLS - 1
        IF r < FORM_ROWS
            EQUB ((1 + 2 * (2 * r < FORM_ROWS - 1)) * INT(ABS(2 * r - FORM_ROWS + 1) * b * VBREATH_MAX / ((FORM_ROWS - 1) * BREATH_MAX) + 0.5)) AND &FF
        ELSE
            EQUB 0
        ENDIF
    NEXT
NEXT
.row_spr                            ; flap frame 0; frame 1 is id + 1
    EQUB SPR_FLAGSHIP, SPR_ESCORT, SPR_DRONE, SPR_DRONE
; Peel-off half loop: per-frame steps of a semicircle that starts heading up and ends
; heading down, LOOP_R pixels from its centre. dx is for a loop to the right.
.loop_dx
FOR i, 0, LOOP_LEN - 1
    EQUB (INT(LOOP_R * (1 - COS(PI * (i + 1) / LOOP_LEN)) + 0.5) - INT(LOOP_R * (1 - COS(PI * i / LOOP_LEN)) + 0.5)) AND &FF
NEXT
.loop_dy
FOR i, 0, LOOP_LEN - 1
    EQUB (INT(LOOP_R * SIN(PI * i / LOOP_LEN) + 0.5) - INT(LOOP_R * SIN(PI * (i + 1) / LOOP_LEN) + 0.5)) AND &FF
NEXT



; ---------------------------------------------------------------- sprites
; Art is one string per sprite: 8 characters per row, each a logical colour 0-3
; (1 = magenta, 2 = cyan, 3 = white). The macros below build the shifted copies.

; MODE 5 byte from four logical colours: pixel p keeps colour bit 1 in bit 7-p and
; colour bit 0 in bit 3-p.
; Two MODE 2 pixels (logical colours 0-15): left in bits 7,5,3,1, right in bits 6,4,2,0.
MACRO PIXELS2 kl, kr
    EQUB (kl AND 8)*16 + (kl AND 4)*8 + (kl AND 2)*4 + (kl AND 1)*2 + (kr AND 8)*8 + (kr AND 4)*4 + (kr AND 2)*2 + (kr AND 1)
ENDMACRO

; Art is w digits per row (logical colours 0-9), h rows, with no blank left column.
; Images and deltas store only the byte columns they use: an image shifted right by
; s covers (s + w + 1) DIV 2 columns, a delta from shift s to s + 1 (s + w) DIV 2 + 1.

; The sprite shifted right by s pixels.
MACRO IMAGE art, w, h, s
FOR b, 0, (s + w + 1) DIV 2 - 1
FOR r, 0, h - 1
    q = "00" + MID$(art, r * w + 1, w) + "000000"
    PIXELS2 VAL(MID$(q, b*2 + 3 - s, 1)), VAL(MID$(q, b*2 + 4 - s, 1))
NEXT
NEXT
ENDMACRO

; Image of art1 at shift s EOR image of art2 at shift s + 1.
MACRO DELTA art1, art2, w, h, s
FOR b, 0, (s + w) DIV 2
FOR r, 0, h - 1
    q = "00" + MID$(art1, r * w + 1, w) + "000000"
    p = "00" + MID$(art2, r * w + 1, w) + "000000"
    PIXELS2 VAL(MID$(q, b*2 + 3 - s, 1)) EOR VAL(MID$(p, b*2 + 2 - s, 1)), VAL(MID$(q, b*2 + 4 - s, 1)) EOR VAL(MID$(p, b*2 + 3 - s, 1))
NEXT
NEXT
ENDMACRO

; Image of art at shift s and row 0 EOR the same at row d: h + d rows.
MACRO VDELTA art, w, h, s, d
FOR b, 0, (s + w + 1) DIV 2 - 1
FOR r, 0, h + d - 1
    IF r < h : q = "00" + MID$(art, r * w + 1, w) + "000000" : ELSE : q = STRING$(w + 8, "0") : ENDIF
    IF r >= d : p = "00" + MID$(art, (r - d) * w + 1, w) + "000000" : ELSE : p = STRING$(w + 8, "0") : ENDIF
    PIXELS2 VAL(MID$(q, b*2 + 3 - s, 1)) EOR VAL(MID$(p, b*2 + 3 - s, 1)), VAL(MID$(q, b*2 + 4 - s, 1)) EOR VAL(MID$(p, b*2 + 4 - s, 1))
NEXT
NEXT
ENDMACRO
MACRO VDELTAS art, w, h, d          ; art at y becomes art at y + d
FOR s, 0, 1 : VDELTA art, w, h, s, d : NEXT
ENDMACRO

; Diagonal: art at shift s and row u EOR art at shift s + 1 and row 1 - u: h + 1 rows.
; u = 0 moves down and right, u = 1 up and right.
MACRO DDELTA art, w, h, s, u
FOR b, 0, (s + w) DIV 2
FOR r, 0, h
    IF r - u >= 0 AND r - u < h : q = "00" + MID$(art, (r - u) * w + 1, w) + "000000" : ELSE : q = STRING$(w + 8, "0") : ENDIF
    IF r + u - 1 >= 0 AND r + u - 1 < h : p = "00" + MID$(art, (r + u - 1) * w + 1, w) + "000000" : ELSE : p = STRING$(w + 8, "0") : ENDIF
    PIXELS2 VAL(MID$(q, b*2 + 3 - s, 1)) EOR VAL(MID$(p, b*2 + 2 - s, 1)), VAL(MID$(q, b*2 + 4 - s, 1)) EOR VAL(MID$(p, b*2 + 3 - s, 1))
NEXT
NEXT
ENDMACRO
MACRO DDELTAS art, w, h, u
FOR s, 0, 1 : DDELTA art, w, h, s, u : NEXT
ENDMACRO

MACRO IMAGES art, w, h
FOR s, 0, 1 : IMAGE art, w, h, s : NEXT
ENDMACRO
MACRO DELTAS art1, art2, w, h       ; art1 at x becomes art2 at x + 1
FOR s, 0, 1 : DELTA art1, art2, w, h, s : NEXT
ENDMACRO

; Table entries for the two shifts: address low / high byte, and the plotter's entry
; offset (7 bytes of code per unused column).
MACRO IMG_LO base, w, h
    EQUB LO(base), LO(base + ((w + 1) DIV 2) * h)
ENDMACRO
MACRO IMG_HI base, w, h
    EQUB HI(base), HI(base + ((w + 1) DIV 2) * h)
ENDMACRO
MACRO IMG_ENTRY w
    EQUB 9 * (SPR_BYTES - (w + 1) DIV 2), 9 * (SPR_BYTES - (w + 2) DIV 2)
ENDMACRO
MACRO DLT_LO base, w, h
    EQUB LO(base), LO(base + (w DIV 2 + 1) * h)
ENDMACRO
MACRO DLT_HI base, w, h
    EQUB HI(base), HI(base + (w DIV 2 + 1) * h)
ENDMACRO
MACRO DLT_ENTRY w
    EQUB 9 * (SPR_BYTES - w DIV 2 - 1), 9 * (SPR_BYTES - (w + 1) DIV 2 - 1)
ENDMACRO

; Logical colours: 1 red, 2 pulsing yellow, 3 yellow, 4 blue, 5 magenta, 6 cyan, 7 white
ART_PLAYER = "00077000" + "00077000" + "00777700" + "06755760" + "66777766" + "67777776" + "60077006" + "00500500"
ART_BULLET = "77" + "77" + "77" + "77"
ART_BULLET_STEP = "77" + "77" + "77" + "77" + "77" + "77" + "77" + "77"
ART_ABULLET = "1" + "3" + "3" + "7"
ART_BONUS   = "0222220" + "2244422" + "2222422" + "2244422" + "2242222" + "2244422" + "0222220" + "0000000"
ART_FLAGSHIP   = "4000220004" + "4002222004" + "4122112214" + "4121111214" + "4441111444" + "0440110440" + "0000110000" + "0000110000"
ART_FLAGSHIP_B = "0000220000" + "4002222004" + "4122112214" + "4121111214" + "4441111444" + "4440110444" + "0000110000" + "0000110000"
ART_ESCORT     = "0000110000" + "0001111000" + "5013113105" + "5111111115" + "5011111105" + "5001111005" + "5000110005" + "5500000055"
ART_ESCORT_B   = "0000110000" + "5001111005" + "5113113115" + "5111111115" + "0511111150" + "0011111100" + "0001111000" + "0000110000"
ART_DRONE      = "0400000040" + "0040000400" + "0055555500" + "0574554750" + "6555555556" + "6056556506" + "6060000606" + "0606006060"
ART_DRONE_B    = "0040000400" + "0040000400" + "6055555506" + "6574554756" + "0555555550" + "0056556500" + "0606006060" + "6006006006"

.gfx_player       : IMAGES ART_PLAYER, 8, 8
.gfx_player_d     : DELTAS ART_PLAYER, ART_PLAYER, 8, 8
.gfx_bullet       : IMAGES ART_BULLET, 2, 4
.gfx_bullet_step  : IMAGES ART_BULLET_STEP, 2, 8
.gfx_abullet      : IMAGES ART_ABULLET, 1, 4
.gfx_abullet_step : VDELTAS ART_ABULLET, 1, 4, ABULLET_SPEED
.gfx_bonus_0      : IMAGE ART_BONUS, BONUS_W, ALIEN_H, 0  ; shift 1 is in the hi block
.gfx_flagship     : IMAGES ART_FLAGSHIP, ALIEN_W, ALIEN_H
.gfx_flagship_d   : DELTAS ART_FLAGSHIP, ART_FLAGSHIP, ALIEN_W, ALIEN_H
.gfx_flagship_b   : IMAGES ART_FLAGSHIP_B, ALIEN_W, ALIEN_H
.gfx_flagship_b_d : DELTAS ART_FLAGSHIP_B, ART_FLAGSHIP_B, ALIEN_W, ALIEN_H
.gfx_escort       : IMAGES ART_ESCORT, ALIEN_W, ALIEN_H
.gfx_escort_d     : DELTAS ART_ESCORT, ART_ESCORT, ALIEN_W, ALIEN_H
.gfx_escort_b     : IMAGES ART_ESCORT_B, ALIEN_W, ALIEN_H
.gfx_escort_b_d   : DELTAS ART_ESCORT_B, ART_ESCORT_B, ALIEN_W, ALIEN_H
.gfx_drone        : IMAGES ART_DRONE, ALIEN_W, ALIEN_H
.gfx_drone_d      : DELTAS ART_DRONE, ART_DRONE, ALIEN_W, ALIEN_H
.gfx_drone_b      : IMAGES ART_DRONE_B, ALIEN_W, ALIEN_H
.gfx_drone_b_d    : DELTAS ART_DRONE_B, ART_DRONE_B, ALIEN_W, ALIEN_H
.gfx_flagship_ab  : DELTAS ART_FLAGSHIP, ART_FLAGSHIP_B, ALIEN_W, ALIEN_H
.gfx_flagship_ba  : DELTAS ART_FLAGSHIP_B, ART_FLAGSHIP, ALIEN_W, ALIEN_H
.gfx_escort_ab    : DELTAS ART_ESCORT, ART_ESCORT_B, ALIEN_W, ALIEN_H
.gfx_escort_ba    : DELTAS ART_ESCORT_B, ART_ESCORT, ALIEN_W, ALIEN_H
.gfx_drone_ab     : DELTAS ART_DRONE, ART_DRONE_B, ALIEN_W, ALIEN_H
.gfx_drone_ba     : DELTAS ART_DRONE_B, ART_DRONE, ALIEN_W, ALIEN_H
.gfx_flagship_v   : VDELTAS ART_FLAGSHIP, ALIEN_W, ALIEN_H, 1
.gfx_flagship_b_v : VDELTAS ART_FLAGSHIP_B, ALIEN_W, ALIEN_H, 1
.gfx_escort_v     : VDELTAS ART_ESCORT, ALIEN_W, ALIEN_H, 1
.gfx_escort_b_v   : VDELTAS ART_ESCORT_B, ALIEN_W, ALIEN_H, 1
.gfx_drone_v      : VDELTAS ART_DRONE, ALIEN_W, ALIEN_H, 1
.gfx_drone_b_v    : VDELTAS ART_DRONE_B, ALIEN_W, ALIEN_H, 1
.gfx_flagship_dn  : DDELTAS ART_FLAGSHIP, ALIEN_W, ALIEN_H, 0
.gfx_flagship_b_dn: DDELTAS ART_FLAGSHIP_B, ALIEN_W, ALIEN_H, 0
.gfx_escort_dn    : DDELTAS ART_ESCORT, ALIEN_W, ALIEN_H, 0
.gfx_escort_b_dn  : DDELTAS ART_ESCORT_B, ALIEN_W, ALIEN_H, 0
.gfx_drone_dn     : DDELTAS ART_DRONE, ALIEN_W, ALIEN_H, 0
.gfx_drone_b_dn   : DDELTAS ART_DRONE_B, ALIEN_W, ALIEN_H, 0
.gfx_flagship_up  : DDELTAS ART_FLAGSHIP, ALIEN_W, ALIEN_H, 1
.gfx_flagship_b_up: DDELTAS ART_FLAGSHIP_B, ALIEN_W, ALIEN_H, 1
.gfx_escort_up    : DDELTAS ART_ESCORT, ALIEN_W, ALIEN_H, 1
.gfx_escort_b_up  : DDELTAS ART_ESCORT_B, ALIEN_W, ALIEN_H, 1
.gfx_drone_up     : DDELTAS ART_DRONE, ALIEN_W, ALIEN_H, 1
.gfx_drone_b_up   : DDELTAS ART_DRONE_B, ALIEN_W, ALIEN_H, 1

; ids: 0 player, 1 bullet, 2-3 flagship, 4-5 escort, 6-7 drone, 8 bullet step,
;      9 enemy bullet, 10 its step, 11 the bonus capsule (an image only),
;      11-16 cross deltas (id - CROSS_OFS = the frame it starts from),
;      17-22 vertical deltas (id - VERT_OFS = the frame), image-shaped and ALIEN_H + 1 rows,
;      23-28 and 29-34 diagonal deltas (id - DOWN_OFS / UP_OFS = the frame), ALIEN_H + 1 rows
.spr_h
    EQUB 8, 4
    FOR i, 2, 7 : EQUB ALIEN_H : NEXT
    EQUB 8, 4, 4 + ABULLET_SPEED
    FOR i, 11, 16 : EQUB ALIEN_H : NEXT
    FOR i, 17, 34 : EQUB ALIEN_H + 1 : NEXT
.img_lo
    IMG_LO gfx_player, 8, 8 : IMG_LO gfx_bullet, 2, 4
    IMG_LO gfx_flagship, ALIEN_W, ALIEN_H : IMG_LO gfx_flagship_b, ALIEN_W, ALIEN_H
    IMG_LO gfx_escort, ALIEN_W, ALIEN_H : IMG_LO gfx_escort_b, ALIEN_W, ALIEN_H
    IMG_LO gfx_drone, ALIEN_W, ALIEN_H : IMG_LO gfx_drone_b, ALIEN_W, ALIEN_H
    IMG_LO gfx_bullet_step, 2, 8
    IMG_LO gfx_abullet, 1, 4 : IMG_LO gfx_abullet_step, 1, 4 + ABULLET_SPEED
    EQUB LO(gfx_bonus_0), LO(gfx_bonus_1)
.img_hi
    IMG_HI gfx_player, 8, 8 : IMG_HI gfx_bullet, 2, 4
    IMG_HI gfx_flagship, ALIEN_W, ALIEN_H : IMG_HI gfx_flagship_b, ALIEN_W, ALIEN_H
    IMG_HI gfx_escort, ALIEN_W, ALIEN_H : IMG_HI gfx_escort_b, ALIEN_W, ALIEN_H
    IMG_HI gfx_drone, ALIEN_W, ALIEN_H : IMG_HI gfx_drone_b, ALIEN_W, ALIEN_H
    IMG_HI gfx_bullet_step, 2, 8
    IMG_HI gfx_abullet, 1, 4 : IMG_HI gfx_abullet_step, 1, 4 + ABULLET_SPEED
    EQUB HI(gfx_bonus_0), HI(gfx_bonus_1)
.img_entry
    IMG_ENTRY 8 : IMG_ENTRY 2
    IMG_ENTRY ALIEN_W : IMG_ENTRY ALIEN_W : IMG_ENTRY ALIEN_W : IMG_ENTRY ALIEN_W : IMG_ENTRY ALIEN_W : IMG_ENTRY ALIEN_W
    IMG_ENTRY 2
    IMG_ENTRY 1 : IMG_ENTRY 1
    IMG_ENTRY BONUS_W
.dlt_lo                             ; the bullets only move vertically: no deltas
    DLT_LO gfx_player_d, 8, 8 : EQUB 0, 0
    DLT_LO gfx_flagship_d, ALIEN_W, ALIEN_H : DLT_LO gfx_flagship_b_d, ALIEN_W, ALIEN_H
    DLT_LO gfx_escort_d, ALIEN_W, ALIEN_H : DLT_LO gfx_escort_b_d, ALIEN_W, ALIEN_H
    DLT_LO gfx_drone_d, ALIEN_W, ALIEN_H : DLT_LO gfx_drone_b_d, ALIEN_W, ALIEN_H
    EQUB 0, 0, 0, 0, 0, 0             ; ids 8-10 only move vertically
    DLT_LO gfx_flagship_ab, ALIEN_W, ALIEN_H : DLT_LO gfx_flagship_ba, ALIEN_W, ALIEN_H
    DLT_LO gfx_escort_ab, ALIEN_W, ALIEN_H : DLT_LO gfx_escort_ba, ALIEN_W, ALIEN_H
    DLT_LO gfx_drone_ab, ALIEN_W, ALIEN_H : DLT_LO gfx_drone_ba, ALIEN_W, ALIEN_H
    IMG_LO gfx_flagship_v, ALIEN_W, ALIEN_H + 1 : IMG_LO gfx_flagship_b_v, ALIEN_W, ALIEN_H + 1
    IMG_LO gfx_escort_v, ALIEN_W, ALIEN_H + 1 : IMG_LO gfx_escort_b_v, ALIEN_W, ALIEN_H + 1
    IMG_LO gfx_drone_v, ALIEN_W, ALIEN_H + 1 : IMG_LO gfx_drone_b_v, ALIEN_W, ALIEN_H + 1
    DLT_LO gfx_flagship_dn, ALIEN_W, ALIEN_H + 1 : DLT_LO gfx_flagship_b_dn, ALIEN_W, ALIEN_H + 1
    DLT_LO gfx_escort_dn, ALIEN_W, ALIEN_H + 1 : DLT_LO gfx_escort_b_dn, ALIEN_W, ALIEN_H + 1
    DLT_LO gfx_drone_dn, ALIEN_W, ALIEN_H + 1 : DLT_LO gfx_drone_b_dn, ALIEN_W, ALIEN_H + 1
    DLT_LO gfx_flagship_up, ALIEN_W, ALIEN_H + 1 : DLT_LO gfx_flagship_b_up, ALIEN_W, ALIEN_H + 1
    DLT_LO gfx_escort_up, ALIEN_W, ALIEN_H + 1 : DLT_LO gfx_escort_b_up, ALIEN_W, ALIEN_H + 1
    DLT_LO gfx_drone_up, ALIEN_W, ALIEN_H + 1 : DLT_LO gfx_drone_b_up, ALIEN_W, ALIEN_H + 1
.dlt_hi
    DLT_HI gfx_player_d, 8, 8 : EQUB 0, 0
    DLT_HI gfx_flagship_d, ALIEN_W, ALIEN_H : DLT_HI gfx_flagship_b_d, ALIEN_W, ALIEN_H
    DLT_HI gfx_escort_d, ALIEN_W, ALIEN_H : DLT_HI gfx_escort_b_d, ALIEN_W, ALIEN_H
    DLT_HI gfx_drone_d, ALIEN_W, ALIEN_H : DLT_HI gfx_drone_b_d, ALIEN_W, ALIEN_H
    EQUB 0, 0, 0, 0, 0, 0             ; ids 8-10 only move vertically
    DLT_HI gfx_flagship_ab, ALIEN_W, ALIEN_H : DLT_HI gfx_flagship_ba, ALIEN_W, ALIEN_H
    DLT_HI gfx_escort_ab, ALIEN_W, ALIEN_H : DLT_HI gfx_escort_ba, ALIEN_W, ALIEN_H
    DLT_HI gfx_drone_ab, ALIEN_W, ALIEN_H : DLT_HI gfx_drone_ba, ALIEN_W, ALIEN_H
    IMG_HI gfx_flagship_v, ALIEN_W, ALIEN_H + 1 : IMG_HI gfx_flagship_b_v, ALIEN_W, ALIEN_H + 1
    IMG_HI gfx_escort_v, ALIEN_W, ALIEN_H + 1 : IMG_HI gfx_escort_b_v, ALIEN_W, ALIEN_H + 1
    IMG_HI gfx_drone_v, ALIEN_W, ALIEN_H + 1 : IMG_HI gfx_drone_b_v, ALIEN_W, ALIEN_H + 1
    DLT_HI gfx_flagship_dn, ALIEN_W, ALIEN_H + 1 : DLT_HI gfx_flagship_b_dn, ALIEN_W, ALIEN_H + 1
    DLT_HI gfx_escort_dn, ALIEN_W, ALIEN_H + 1 : DLT_HI gfx_escort_b_dn, ALIEN_W, ALIEN_H + 1
    DLT_HI gfx_drone_dn, ALIEN_W, ALIEN_H + 1 : DLT_HI gfx_drone_b_dn, ALIEN_W, ALIEN_H + 1
    DLT_HI gfx_flagship_up, ALIEN_W, ALIEN_H + 1 : DLT_HI gfx_flagship_b_up, ALIEN_W, ALIEN_H + 1
    DLT_HI gfx_escort_up, ALIEN_W, ALIEN_H + 1 : DLT_HI gfx_escort_b_up, ALIEN_W, ALIEN_H + 1
    DLT_HI gfx_drone_up, ALIEN_W, ALIEN_H + 1 : DLT_HI gfx_drone_b_up, ALIEN_W, ALIEN_H + 1
.dlt_entry
    DLT_ENTRY 8 : EQUB 0, 0
    DLT_ENTRY ALIEN_W : DLT_ENTRY ALIEN_W : DLT_ENTRY ALIEN_W : DLT_ENTRY ALIEN_W : DLT_ENTRY ALIEN_W : DLT_ENTRY ALIEN_W
    EQUB 0, 0, 0, 0, 0, 0
    DLT_ENTRY ALIEN_W : DLT_ENTRY ALIEN_W : DLT_ENTRY ALIEN_W : DLT_ENTRY ALIEN_W : DLT_ENTRY ALIEN_W : DLT_ENTRY ALIEN_W
    IMG_ENTRY ALIEN_W : IMG_ENTRY ALIEN_W : IMG_ENTRY ALIEN_W : IMG_ENTRY ALIEN_W : IMG_ENTRY ALIEN_W : IMG_ENTRY ALIEN_W
    FOR i, 21, 32 : DLT_ENTRY ALIEN_W : NEXT

.end
ASSERT end <= SCREEN              ; the loader below only runs at load time

; ======================================================================================
; Bonus capsule: shoot BONUS_KILLS swooping aliens with a single shot and one drops
; from the last, falling a pixel a frame. The ship catches it for the double shot.
; Its code fills the end of the run-time state page; the loader puts it there.
; ======================================================================================

ORG state_end
GUARD &0800
.hi_start

; A swooping alien was shot at diver_y, by the bullet at bullet_x; the beam is past its
; rows, which the capsule's are.
.bonus_drop
    LDA power : ORA bonus_on : BNE bn_ret
    INC dive_kills
    LDA dive_kills : CMP #BONUS_KILLS : BCC bn_ret
    LDA alive_count : BEQ bn_ret    ; the wave's last alien: the next wave's first, then
    LDA bullets_on + 1 : BNE bn_ret ; a double shot's last bullet still flying: next time
    STA dive_kills
    LDA #2 : STA bonus_on
    LDA bullet_x : SEC : SBC #(BONUS_W - 1) DIV 2 : STA bonus_x
    LDA diver_y : STA bonus_y
    JMP bonus_draw
.bn_ret
    RTS

; In beam order, in the second bullet's turn.
.update_bonus
    LDA bonus_on : CMP #2 : BNE ubn_move
    DEC bonus_on
    RTS
.ubn_move
    LDA bonus_y : CLC : ADC #ALIEN_H : TAX
    LDA bonus_y : JSR beam_guard    ; old and new positions together
    JSR bonus_draw                  ; erase
    INC bonus_y
    LDA bonus_y : CMP #BONUS_BOTTOM : BCS ubn_off
    LDX player_state : BNE bonus_draw
    CMP #PLAYER_Y - 6 : BCC bonus_draw          ; its 7 rows meet the ship's 8
    CMP #PLAYER_Y + 8 : BCS bonus_draw
    LDA bonus_x : SEC : SBC player_x : CLC : ADC #BONUS_W - 1
    CMP #BONUS_W + 7 : BCS bonus_draw           ; and its 7 columns the ship's 8
    INC power
    SFX SFX_POWER
.ubn_off
    LDA #0 : STA bonus_on
    RTS

.bonus_draw
    LDA #SPR_BONUS : STA draw_id
    LDA bonus_x : STA draw_x
    LDA bonus_y : STA draw_y
    JMP plot_image

; Between waves: the capsule is lost.
.bonus_clear
    LDA bonus_on : BEQ bn_ret
    LDA bonus_y : TAX : JSR beam_guard_alien
    JSR bonus_draw
    LDA #0 : STA bonus_on
    RTS

.gfx_bonus_1 : IMAGE ART_BONUS, BONUS_W, ALIEN_H, 1   ; shift 0 is in the main block
.hi_end

; Loader: assembled where *RUN puts it, just after the main block's bytes, with the
; &0900 block's bytes after it. It copies both blocks into place, then runs the
; one-time set-up from here, so none of it takes room in the game.
LOADER = LOAD_ADDR + end - main_start
ORG LOADER
.loader
    LDA #119 : JSR OSBYTE           ; close !BOOT's EXEC file while the DFS workspace is intact
    LDA #LO(loader_end) : STA ptr0 : LDA #HI(loader_end) : STA ptr0 + 1
    LDA #LO(lo_start) : STA ptr1 : LDA #HI(lo_start) : STA ptr1 + 1
    LDX #HI(lo_end - lo_start)
    LDY #0
.mv_lo
    LDA (ptr0),Y : STA (ptr1),Y
    INY : BNE mv_lo
    INC ptr0 + 1 : INC ptr1 + 1
    DEX : BNE mv_lo
.mv_lo_part                         ; exactly: the ROM workspace table follows at &0DF0
    LDA (ptr0),Y : STA (ptr1),Y
    INY : CPY #LO(lo_end - lo_start) : BNE mv_lo_part
    LDY #0
    LDX #hi_end - hi_start
.mv_hi
    LDA loader_end + lo_end - lo_start - 1,X : STA hi_start - 1,X
    DEX : BNE mv_hi
    LDA #LO(LOAD_ADDR) : STA ptr0 : LDA #HI(LOAD_ADDR) : STA ptr0 + 1
    LDA #LO(main_start) : STA ptr1 : LDA #HI(main_start) : STA ptr1 + 1
    LDX #HI(end - main_start + 255)
.mv_copy                            ; ascending: the destination is always below the source
    LDA (ptr0),Y : STA (ptr1),Y
    INY : BNE mv_copy
    INC ptr0 + 1 : INC ptr1 + 1
    DEX : BNE mv_copy

; digits: GLYPHS glyphs from the OS font in white, as 4 byte columns of GLYPHS * 8 bytes
; (glyph * 8 + row). A font bit pair (left, right) becomes pair * &15 on screen.
.build_digits
    LDA #0 : STA loop_i
.bd_char
    LDX loop_i : LDA glyph_chars,X : STA font_buf
    LDA #10 : LDX #LO(font_buf) : LDY #HI(font_buf) : JSR OSWORD
    LDA loop_i : ASL A : ASL A : ASL A : TAX    ; glyph * 8
    LDY #0
.bd_row
    LDA font_buf + 1,Y : STA tmp
FOR c, 0, 3
    LDA #0 : ASL tmp : ROL A : ASL tmp : ROL A
    STA tmp2 : ASL A : ASL A : ORA tmp2 : STA tmp2 : ASL A : ASL A : ORA tmp2
    STA digits + GLYPHS * 8 * c,X
NEXT
    INX : INY : CPY #8 : BNE bd_row
    INC loop_i : LDA loop_i : CMP #GLYPHS : BEQ bd_done
    JMP bd_char
.bd_done
    LDA KEYV : STA keyv_os : LDA KEYV + 1 : STA keyv_os + 1
    LDA #&FF : STA pl_last_id       ; no image patched into plot yet
    LDA #&07 : STA bg_colour        ; black (the ULA stores colours inverted)
FOR e, 0, 3                         ; envelopes 1-4: the OS keeps them at &08C0
    LDX #LO(envelopes + 14 * e) : LDY #HI(envelopes + 14 * e) : LDA #8 : JSR OSWORD
NEXT
    LDA #229 : LDX #1 : LDY #0 : JSR OSBYTE    ; ESCAPE is an ordinary key
    LDA USR_ACR : AND #&DF : STA USR_ACR    ; timer 2 counts down once per microsecond
    LDA #&20 : STA USR_IER                  ; and never interrupts
    JMP title
.glyph_chars
    EQUS "0123456789WAVE"
; number, step (cs; + 128: the pitch doesn't repeat), pitch change per step and steps
; in 3 sections, then amplitude: attack, decay, sustain and release rates, attack and
; decay levels
.envelopes
    EQUB 1, 129, -8, 0, 0, 8, 0, 0, 126, -12, 0, -12, 126, 0         ; fire: a falling zap
    EQUB 2, 1, 0, 0, 0, 0, 0, 0, 126, -3, -1, -6, 126, 80            ; explosions
    EQUB 3, 130, -2, 0, 0, 60, 0, 0, 60, -1, 0, -4, 60, 59           ; dive: a falling whistle
    EQUB 4, 1, 0, 0, 0, 0, 0, 0, 126, -8, -2, -10, 110, 60           ; tune notes
.loader_end
ASSERT HI(lo_end - lo_start) > 0 AND LO(lo_end - lo_start) > 0
ASSERT main_start + HI(end - main_start + 255) * 256 <= loader  ; the copy never reaches the loader
HI_SIZE = hi_end - hi_start
ASSERT HI_SIZE > 0 AND HI_SIZE < 256
ASSERT loader_end + lo_end - lo_start + HI_SIZE <= &7C00        ; the file loads below MODE 7's screen
ASSERT end + loader_end - loader + lo_end - lo_start + HI_SIZE <= loader  ; the file image below doesn't overlap it
ASSERT SPR_BONUS * 2 + 1 < img_hi - img_lo AND SPR_BONUS = CROSS_OFS + 2   ; spr_h: ALIEN_H, as the capsule

COPYBLOCK loader, loader_end, end
COPYBLOCK lo_start, lo_end, end + loader_end - loader
COPYBLOCK hi_start, hi_end, end + loader_end - loader + lo_end - lo_start
SAVE "GALAXA", main_start, end + loader_end - loader + lo_end - lo_start + HI_SIZE, loader, LOAD_ADDR
PUTTEXT "!BOOT", "!BOOT", &FFFF
