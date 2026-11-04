; ------------------------------------------------------------------------------------------------------
; Paul Newell 2026 - Version 0.9.1
; Galaxa - BBC Micro Model B fixed shooter (MODE 2, 6502, BeebAsm)
; Sprites are EORed and pre-shifted twice so they sit on any pixel; a 1px move is one delta plot,
; so no byte ever shows blank mid-frame. Objects redraw top to bottom just behind the beam
; (User VIA T2 restarts at vsync), so nothing tears. Sprites use colour bits 0-2, stars bit 3,
; so neither disturbs the other. Loads at &1900, copies down to &0E00 (DFS workspace, free once loaded).
; ------------------------------------------------------------------------------------------------------

VERSION = "0.9.1"                  ; tools/title.mjs puts it on the title screen

OSRDCH = &FFE0
OSWRCH = &FFEE
OSWORD = &FFF1
OSBYTE = &FFF4
IRQ2V  = &0206
KEYV   = &0228

SCREEN       = &3000
MODE7_SCREEN = &7C00

; User VIA timer 2: the raster clock (1 tick = 1us)
USR_T1CL     = &FE64          ; timer 1: the ship's palette split
USR_T1CH     = &FE65
USR_T2L      = &FE68
USR_T2H      = &FE69
USR_ACR      = &FE6B
USR_IER      = &FE6E

; beam position in 256us units (4 scan lines): row y at BEAM_TOP + y DIV 4
BEAM_TOP     = 7              ; measured in jsbeeb: the timer starts after OSBYTE 19 returns

SYS_IER      = &FE4E

KEY_LEFT     = 1
KEY_RIGHT    = 2
KEY_FIRE     = 4

; keyboard matrix codes (INKEY -n is code n - 1)
KEY_Z        = &61
KEY_X        = &42
KEY_RETURN   = &49
KEY_P        = &37

DEBUG =? 0                    ; make run-debug: P cycles the power level

SYS_ORB      = &FE40          ; addressable latch: bit 3 = keyboard auto-scan
SYS_DDRA     = &FE43
SYS_ORA_NH   = &FE4F          ; port A, no handshake

ULA_PALETTE  = &FE21

SPR_PLAYER   = 0
SPR_BULLET   = 1
SPR_FLAGSHIP = 2              ; id EOR 1 is the other flap frame
SPR_ESCORT   = 4
SPR_DRONE    = 6
SPR_BULLET_STEP = 8           ; old and new bullet together: one plot moves it
SPR_ABULLET  = 9
SPR_ABULLET_STEP = 10
CROSS_OFS    = 9              ; delta id of "frame id at x -> other frame at x + 1"
VERT_OFS     = 15             ; delta id of "frame id at y -> same frame at y + 1"
ALIEN_W      = 10
ALIEN_H      = 8
ALIEN_MID    = ALIEN_W DIV 2 - 1
SPR_BYTES    = (ALIEN_W + 1) DIV 2 + 1

FLAG_COLOUR  = 2              ; logical: the capsule, flashing
FLAG_PHYS    = 3              ; yellow,
FLAG_FLASH   = 2              ; then red: frame bit 3, shifted twice
BOSS_COLOUR  = 3
BOSS_PHYS    = 3              ; yellow
STAR_COLOUR  = 8              ; 9-15 repeat 1-7: a star never shows over a sprite

NUM_STARS    = 30
STAR_TOP     = 16             ; below the HUD: the beam has passed it when stars move
STAR_X_STEP  = 67
TWINKLE_RATE = 4
TWINKLE_STEP = 7
STAR_BAND    = 48             ; stars above this (or about to wrap) move first, ahead of the beam

FLAP_PERIOD  = 16             ; a power of 2: frames between wing beats

SFX_FIRE     = 1              ; in sfx_data order
SFX_DIVE     = 2
SFX_DIE      = 4
SFX_RUMBLE   = 8
SFX_HIT      = 16
SFX_POWER    = 32             ; must stay the last bit: play_sfx assumes it

MACRO SFX bit
    LDA #bit : ORA sfx : STA sfx
ENDMACRO

PLAYER_Y     = 232
PLAYER_MAX_X = 148
PLAYER_START = 72
SPARE_Y      = 256 - 8
WING_COLOUR  = 6              ; logical: cyan, the ship's wings; below SPLIT_Y it shows the power level
SPLIT_Y      = PLAYER_Y - 12
DIE_TIME     = 144
FLASH_TIME   = 8
DIE_BLINK    = 8              ; a power of 2
ASSERT (DIE_TIME DIV DIE_BLINK) MOD 2 = 0       ; so it ends hidden
ASSERT PLAYER_START MOD 2 = 0

PS_PLAY      = 0
PS_DYING     = 1
PS_SLIDE     = 2
PS_OVER      = 3
GAME_OVER_TIME = 100

HS_ENTRIES   = 5
HS_DIGITS    = 16
TT_FLASH     = 136
TT_GREEN     = 146              ; graphics: the stage squares are sixels
ASSERT PLAYER_MAX_X + ALIEN_W <= 160

FORM_COLS    = 7
FORM_ROWS    = 4
FORM_COUNT   = FORM_COLS * FORM_ROWS
FORM_SHAPE   = "0011100" + "0110110" + "0111110" + "1111111"   ; top down: 3, 4, 5, 7 under the boss
FORM_PULL    = "0800"         ; px each side moves in, per row: the 4 sit between the columns
WAVE_COUNT   = 3 + 4 + 5 + 7  ; the 1s in FORM_SHAPE
ASSERT FORM_COLS MOD 2 = 1    ; the middle column under the boss; uf_col's walk
FORM_Y       = 32
COL_STEP     = ALIEN_W + 5
ROW_STEP     = ALIEN_H + 5
BREATH_MAX   = 8
VBREATH_MAX  = 3
BREATH_STEPS = BREATH_MAX + VBREATH_MAX   ; a step moves a row across or up and down, never both
FX_START     = 40
BOSS_SLOT    = FORM_COUNT
FORM_SLOTS   = FORM_COUNT + 1
BOSS_DX      = FORM_COLS DIV 2 * COL_STEP      ; over the middle column, where breathing is 0
FLANK        = ALIEN_W + 1
FX_MIN       = 4 + BREATH_MAX
FX_MAX       = PLAYER_MAX_X - (FORM_COLS - 1) * COL_STEP - BREATH_MAX
ASSERT FX_MIN < FX_START AND FX_START < FX_MAX    ; or the sway never turns
BREATH_COL1  = INT((FORM_COLS - 3) * BREATH_MAX / (FORM_COLS - 1) + 0.5)    ; how far the second column breathes out
SHIP_MIN_X   = FX_MIN + COL_STEP - BREATH_COL1 + 1                     ; under the second column at its furthest: the outer one is out of reach
SHIP_MAX_X   = FX_MAX + (FORM_COLS - 2) * COL_STEP + BREATH_COL1 + 1
ASSERT SHIP_MIN_X < PLAYER_START AND PLAYER_START < SHIP_MAX_X

LEVELS       = 8
DIVE_LAST    = 11             ; the last level's dive gap, a frame less each wave after it
RUSH_COUNT   = 10             ; this few left: dives come fast, fire again and turn harder
RUSH_DELAY   = 8
DIVE_STRIDE  = 7              ; coprime with 25: visits every slot
DIVER_SPEED  = 3
DIVER_BOTTOM = 240
DIVER_TOP    = 8
REENTER_Y    = 16             ; low enough that a group's redraw, after its erase, beats the beam there
LATE_HIT     = 17408 DIV 256  ; timer 2 units: past this, a frame leaves its shots' hits for the next
LOOP_LEN     = 32
LOOP_R       = 14
LAP_ROW      = 2              ; from this row down, a dive opens with a full, round loop
TRAIL        = 8              ; frames between aliens in a line: they just clear each other over a loop's top
TRAIL_LEN    = 2 * TRAIL      ; a power of 2: the lead's last positions
LAP_Y        = 140            ; a line drops to here to loop: a loop's top clears the formation
BOSS_POINTS  = &10
LINE_TOTAL   = &25
BOSS_TOTAL   = &50
CAPSULE_MIN  = &05
CAPSULE_MAX  = &08
DIVE_VMAX    = 24
DIVE_XMAX    = 2
WARP_TIME    = 150
WARP_VMAX    = 8
INTRO_WARP   = 3

BULLETS      = 3              ; the third: rapid fire only
BULLET_SPEED = 6              ; over the 4px height: the step image has a gap between old and new
FIRE_DELAY   = 16
RAPID_DELAY  = 12
BULLET_TOP   = 8

BONUS_W      = 7
BONUS_BOTTOM = 256 - ALIEN_H
BONUS_LIFT   = 24
BONUS_LOW    = 150            ; the lowest it starts: a second or more to fall to the ship
SPR_BONUS    = 11             ; delta id 11 is a cross delta of the same height
SPR_BOSS     = 12
SPR_EXPL    = 13             ; delta id 13 is a cross delta of the same height
EXPL_W      = 7
EXPL_TIME   = 6              ; frames an explosion shows

ABULLETS     = 3
ABULLET_SPEED = 4
ABULLET_BOTTOM = 256 - 4
BURST_GAP    = 6
BURST_PAUSE  = 2 * BURST_GAP  ; the rush: before the next burst
AFIRE_LOW    = PLAYER_Y - 24
GLYPHS       = 15
GLYPH_PLUS   = 14
GLYPH_W      = 10
GLYPH_COLOUR = 7               ; white
BANNER_Y     = 120
BANNER_COL   = 7
BANNER_TIME  = 100
BONUS_DELAY  = 35                 ; the banner and its tune first: the tick flushes channel 3
BONUS_TICK   = 5                  ; each tick a semitone higher
TICK_PITCH   = 101
TICK_TOP     = 249                ; the tick's pitch stops rising here
DROP_Y       = 8
ORDER_N      = 2 + BULLETS + ABULLETS   ; formation, bullets, diver, enemy bullets
DEFER_Y      = 112            ; this low: drawn at the next frame's start, ahead of the beam
EARLY_Y      = 144
QUEUE_MAX    = 24

ALIVE_GONE   = 0
ALIVE_HOME   = 1
ALIVE_DIVING = 2

DIVER_NONE   = 0
DIVER_DIVE   = 1
DIVER_RETURN = 2

; --- Zero page (&40-&89) ---
; language workspace: free, Galaxa never returns to BASIC
ptr0         = &40            ; one per sprite byte column, SPR_BYTES in all
draw_x       = &4C
draw_y       = &4D
draw_id      = &4E
draw_h       = &4F
tmp          = &50
tmp2         = &51
guard_bot    = &52
player_x     = &53
bullet_on    = &54            ; working copy of bullets_*[bullet_idx]
bullet_x     = &55
bullet_y     = &56
old_x        = &57
dive_timer   = &58
diver_state  = &59
diver_slot   = &5A
diver_x      = &5B
diver_y      = &5C
diver_pick   = &5D
alive_count  = &5E
slot_x       = &5F
slot_y       = &60
loop_i       = &61
frame        = &62
new_x        = &63
new_y        = &64
form_row     = &65
keys         = &66
hud_dirty    = &67
abullet_idx  = &68
fire_n       = &69
order_done   = &6C
order_vec    = &6D
diver_wrap   = &6F
bullet_idx   = &70
fire_cool    = &71
defer        = &72
rnd          = &73            ; never 0
pl_last_id   = &74            ; self-modified plot: last id patched in, then its address
sfx          = &77
sfx_x        = &78
bg_colour    = &79
boss_x       = &7A
boss_y       = &7B
hit_y        = &7C
wing_k       = &7D
lead_gone    = &7E            ; diver shot: its path flies on for its wings
moved        = &7F
keyv_os      = &81            ; 2: OS KEYV, restored for the title
power        = &83            ; 0 single shot, 1 double, 2 double and rapid fire
bonus_on     = &84
bonus_x      = &85
bonus_y      = &86
stage_bonus  = &87
tune_x       = &88
tune_n       = &89
expl_t      = &6A            ; frames the explosion has left, 0: none
expl_x      = &6B
; &90-&CF: filing system workspace, unused once loaded (checked in jsbeeb)
WINGS        = 2
wing_on      = &90
wing_slot    = &92
wing_ox      = &94
wing_oy      = &96
wing_anim    = &98
wing_nox     = &9A
wing_noy     = &9C
wing_nanim   = &9E
fire_x       = &A0
fire_y       = &A3
lead_d       = &A6
lead_hx      = &A8
lead_hy      = &A9
wing_tgt     = &AA
warp_n       = &AE
star_n       = &80
shown        = &AF
glyph_mode   = &B3
glyph_i      = &B4
hud_k        = &B5
ptr1         = ptr0 + 2
ptr2         = ptr0 + 4
ptr3         = ptr0 + 6
ASSERT ptr0 + 2 * SPR_BYTES <= draw_x

; --- Zero page: hot state ---
; &00-&3F, &8A-&8F: nothing writes them once loaded (checked in jsbeeb)
ORG &00
GUARD &40
.row_x
    SKIP FORM_ROWS
.row_anim
    SKIP FORM_ROWS
.row_y
    SKIP FORM_ROWS
.abullets_on
    SKIP ABULLETS
.abullets_x
    SKIP ABULLETS
.abullets_y
    SKIP ABULLETS
.wing_shot
    SKIP WINGS
.afb_x
    SKIP 1
.player_state
    SKIP 1
.player_t
    SKIP 1
.player_row
    SKIP 1
.ships_shown
    SKIP 1
.lives
    SKIP 1
.score_lo
    SKIP 1
.score_hi
    SKIP 1
.wave
    SKIP 1
.level
    SKIP 1
.intro
    SKIP 1
.intro_t
    SKIP 1
.twinkle_i
    SKIP 1
.queue_n
    SKIP 1
.order_idx
    SKIP 1
.burst_left
    SKIP 1
.burst_gap
    SKIP 1
.afire_armed
    SKIP 1
.diver_anim
    SKIP 1
.new_anim
    SKIP 1
.diver_t
    SKIP 1
.diver_left
    SKIP 1
.diver_lap                          ; 0 the half loop; a full loop: 3 dropping to it, 2 its first half, 1 its second
    SKIP 1
.trail_i
    SKIP 1
.diver_half                         ; a full loop flies each step of the half loop's table twice
    SKIP 1
.line_left
    SKIP 1
.diver_xf
    SKIP 1
.diver_vx
    SKIP 1
.order_n
    SKIP 1
.order_pos
    SKIP 1
.sort_idx
    SKIP ORDER_N
.swoop_pts
    SKIP 1
.bonus_wait
    SKIP 1
.expl_y
    SKIP 1

; --- Run-time state ---
; language workspace: free, never saved to disc
ORG &0400
GUARD &0800
.row_dir
    SKIP FORM_ROWS
.row_bofs
    SKIP FORM_ROWS
.row_bdir
    SKIP FORM_ROWS
.capsule_pts
    SKIP 1
.alive
    SKIP FORM_SLOTS
.font1
    SKIP GLYPHS * 8
.star_x
    SKIP NUM_STARS
.star_y
    SKIP NUM_STARS
.star_lo
    SKIP NUM_STARS
.star_hi
    SKIP NUM_STARS
.star_bit
    SKIP NUM_STARS
.star_vis
    SKIP NUM_STARS
.star_done
    SKIP NUM_STARS
.order_key
    SKIP ORDER_N
.bullets_on
    SKIP BULLETS
.bullets_x
    SKIP BULLETS
.bullets_y
    SKIP BULLETS
.queue_x
.font_buf                           ; OSWORD 10 scratch during the loader only
    SKIP QUEUE_MAX
ASSERT QUEUE_MAX >= 9
.queue_y
    SKIP QUEUE_MAX
.queue_id
    SKIP QUEUE_MAX
.sound_blk
    SKIP 8
.state_end                          ; capsule code follows (see hi_start)

LOAD_ADDR    = &1900          ; PAGE with DFS

ORG &0900                           ; OS buffers and disc NMI code: free in play
GUARD &0DF0
.lo_start

; --- Start-up and game flow ---

.title
    SEI
    LDA keyv_os : STA KEYV : LDA keyv_os + 1 : STA KEYV + 1
    CLI
    LDA #122 : JSR OSBYTE           ; wait for every key up: one held from the game
    INX : BNE title                 ; mustn't skip the title
    LDA #&81 : STA SYS_IER          ; OS keyboard IRQ on for the title
    LDA #21 : JSR OSBYTE            ; X = 0 from the loop: flush the keyboard buffer
    LDX #LO(txt_mode7) : LDY #HI(txt_mode7) : JSR print_vdu
    JSR draw_title
    LDX hs_new : JSR hs_row
    LDY #0 : LDA #TT_FLASH : STA (ptr1),Y
    JSR OSRDCH
    LDA #&01 : STA SYS_IER          ; keyboard IRQ off: the OS handler would steal time mid-frame
    SEI                             ; nor the 100Hz held-key poll: ~1ms a tick
    LDA #LO(keyv_none) : STA KEYV : LDA #HI(keyv_none) : STA KEYV + 1
    CLI
    JSR clear_screen
    LDX #LO(vdu_setup) : LDY #HI(vdu_setup) : JSR print_vdu
    LDX #ula_setup_end - ula_setup - 1
.ng_palette                         ; straight into the ULA: shorter than VDU 19s
    LDA ula_setup,X : STA ULA_PALETTE
    DEX : BPL ng_palette

.new_game
    LDA #0 : STA score_lo : STA score_hi : STA wave
    LDA #CAPSULE_MIN : STA capsule_pts
    LDA #DIVE_LAST : STA dive_delays + LEVELS - 1
    LDA #3 : STA lives
    LDA #PLAYER_START : STA player_x
    LDA #PLAYER_Y : STA player_row
    JSR draw_player
    JSR init_stars
    LDX #LO(txt_hud) : LDY #HI(txt_hud) : JSR print_vdu
    LDX #3 : LDA #&FF
.ng_shown
    STA shown,X : DEX : BPL ng_shown
    JSR print_hud
    LDA #0 : STA keys : STA fire_cool : STA defer : STA queue_n : STA sfx : STA tune_n
    STA ships_shown : STA player_state
    STA power : STA bonus_on : STA stage_bonus
    STA bullets_on : STA bullets_on + 1 : STA bullets_on + 2   ; CLS has wiped them
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
    LDA #0 : STA diver_wrap
    JSR diver_reenter               ; first: REENTER_Y is where the beam gets soonest
    JSR update_stars_rest           ; no twinkle: the beam may be past a star it would show
    BMI ml_stars_done               ; N set: update_stars ends on X = &FF
.ml_stars
    JSR twinkle_stars
    JSR update_stars
.ml_stars_done
    JSR frame_start                 ; long before the beam gets there
    ; beam in the bottom border: safe to move the ship
    JSR read_keys
    JSR update_player
    LDA hud_dirty : BEQ ml_hud_done   ; HUD is at the top: also safe now
    JSR print_hud
.ml_hud_done
    JSR alien_fire
    JSR update_in_beam_order
    JSR update_expl
    JSR check_player_hit
    JSR play_sfx                    ; the beam is done with the sprites: time to spare
    LDA player_state : CMP #PS_OVER : BEQ game_over
    LDA alive_count : BNE main_loop
    JSR new_wave
    JMP main_loop

.game_over
    LDX #LO(txt_game_over) : LDY #HI(txt_game_over) : JSR print_vdu
    LDX #SND_OVER : JSR play_tune
    LDA #GAME_OVER_TIME : STA intro_t
.go_wait
    JSR wait_vsync
    DEC intro_t : BNE go_wait
    JSR insert_score
    JMP title

.new_wave
    SED : LDA wave : CLC : ADC #1 : STA wave : CLD
    JSR set_level
    LDX #FORM_SLOTS - 1
.nw_fill
    LDA slot_start,X : STA alive,X
    DEX : BPL nw_fill
    LDX #FORM_ROWS - 1
.nw_rows
    LDA #FX_START : STA row_x,X
    LDA #1 : STA row_dir,X
    LDA #0 : STA row_anim,X : STA row_bofs,X : STA row_y,X     ; 0: not dropped in yet
    LDA #FORM_COLS : STA row_bdir,X
    DEX : BPL nw_rows
    LDA #WAVE_COUNT + 1 : STA alive_count     ; + the boss
    LDX level : LDA dive_delays,X : STA dive_timer
    LDA #DIVER_NONE : STA diver_state : STA diver_pick : STA diver_wrap
    LDA #1 : STA intro
    JSR intro_frame                 ; flushes plots queued by the last frame
    LDX #BULLETS - 1
.nw_bullets
    LDA bullets_on,X : BEQ nw_next_bullet
    JSR bullet_load
    JSR kill_bullet
    LDX bullet_idx
    JSR bullet_save
.nw_next_bullet
    DEX : BPL nw_bullets
    JSR bonus_clear
    JSR expl_clear
    LDX #ABULLETS - 1
.nw_abullets
    LDA abullets_on,X : BEQ nw_next_abullet
    STX abullet_idx
    JSR abullet_pos
    JSR ua_show                     ; a low one is queued, not waited for: the beam may be 10ms off
    LDX abullet_idx : LDA #0 : STA abullets_on,X
.nw_next_abullet
    DEX : BPL nw_abullets
    STA burst_left : STA afire_armed   ; A = 0 either way out of the loop
    JSR intro_frame
    LDA wave : CMP #2 : BCS nw_bonus
    LSR A
.nw_bonus
    STA stage_bonus
    LDA #TICK_PITCH - 4 : STA sfx_data + SND_TICK + 2
    LDA #BONUS_DELAY : STA bonus_wait
    JSR toggle_banner
    LDX #SND_WAVE : JSR play_tune
    LDA #BANNER_TIME : STA intro_t
.nw_banner                          ; at least BANNER_TIME
    JSR intro_frame
    LDA intro_t : BEQ nw_counted
    DEC intro_t
.nw_counted
    ORA stage_bonus : BNE nw_banner
    JSR toggle_banner
    LDA #INTRO_WARP : STA intro     ; then the warp to the stage
    LDA #WARP_TIME : STA intro_t
.nw_warp
    JSR intro_frame
    DEC intro_t : BNE nw_warp
    LDA #2 : STA intro
.nw_drop
    JSR intro_frame
    JSR drop_rows
    LDA #0 : STA keys               ; no new shots as they drop in: these frames have no room for them
    LDA row_y : SBC row_y0 : BNE nw_drop    ; C set by drop_rows; the rows all land together
    STA intro
    RTS

.intro_frame
    JSR intro_shots                 ; last frame's: after the drop-in, so a wait for the beam holds nothing up
    LDA #0
    LDX intro : CPX #INTRO_WARP : BNE if_moves
    LDX intro_t : DEX : STX tmp
    LDA #WARP_TIME : SBC intro_t    ; C set by the CPX
    CMP tmp : BCC if_ease
    LDA tmp
.if_ease
    LSR A : LSR A
    CMP #WARP_VMAX : BCC if_moves
    LDA #WARP_VMAX - 1
.if_moves
    STA warp_n
    ASL A : EOR #&FF : ADC #255     ; C clear: 254 - 2 * warp_n, so a star about to wrap
    STA us_wrap_at + 1              ; moves in the first pass, before the beam is at the top
    JSR wait_vsync
    LDA warp_n : BNE if_warp
    JSR twinkle_stars
    JSR update_stars
    BMI if_stars                    ; N set: update_stars ends on X = &FF
.if_warp                            ; no twinkle: the beam would pass a star turned on unmoved
    JSR update_stars_top
    JSR update_stars_rest
.if_stars
    JSR frame_start
    JSR read_keys
    JSR update_player
    LDA stage_bonus : BEQ if_tune
    DEC bonus_wait : BNE if_tune
    LDA #BONUS_TICK : STA bonus_wait
    LDA #&10 : JSR add_score
    JSR print_hud                   ; the beam is past the HUD, as in the main loop
    LDA sfx_data + SND_TICK + 2 : CMP #TICK_TOP : BCS if_top
    ADC #4 : STA sfx_data + SND_TICK + 2
.if_top
    LDX #SND_TICK : JSR sound
    SED : LDA stage_bonus : SEC : SBC #1 : STA stage_bonus : CLD
.if_tune
    JMP play_sfx                    ; a tune started by the wave's last kill plays on

.frame_start
    JSR flush_plots
    INC frame
    JMP pulse_capsule

.draw_slot_expl                     ; a formation alien shot: it goes, the explosion shows
    JSR draw_slot
    JMP expl_start

.wait_vsync
    LDA #19 : JSR OSBYTE
    LDA bg_colour : STA ULA_PALETTE ; here so a hit ship's flash goes on between waves too
    LDA #&FF : STA USR_T2L : STA USR_T2H
    JMP split_start

.toggle_banner
    LDA #BANNER_Y : STA draw_y
    LDA #BANNER_COL : STA tmp2
.tb_wave
    CMP #BANNER_COL + 4 : BEQ tb_number ; C clear while below
    ADC #GLYPH_W - BANNER_COL : JSR col_glyph
    LDA tmp2 : BCS tb_wave          ; C set by glyph_at's last CPY
.tb_number
    INC tmp2
    LDA wave : LSR A : LSR A : LSR A : LSR A : BEQ tb_units
    JSR col_glyph
.tb_units
    LDA wave : AND #&0F : JMP col_glyph

; top down, in beam order
.drop_rows
    LDA row_y : CMP #FORM_Y - 1 : BNE dr_rows
    LDA #FX_START + BOSS_DX : STA boss_x    ; draw ahead of the beam while waiting for row 0
    LDA #FORM_Y - ROW_STEP : STA boss_y
    JSR boss_draw
.dr_rows
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
    CMP row_y0,X : BEQ dr_next
    STA draw_y
    LDA row_spr,X : ORA row_anim,X : CLC : ADC #VERT_OFS : STA draw_id
    LDA #ALIEN_H : JSR uf_guard_h   ; old and new rows: ALIEN_H + 1 high
    LDA #FX_START : STA tmp2 : JSR uf_col
    LDX form_row : INC row_y,X
.dr_next
    LDX form_row : INX : CPX #FORM_ROWS : BNE dr_row
    RTS

.stamp_scores
    LDX #0
.ss_entry
    JSR hs_row
    LDY #2
    LDA hs_data + 2,X
    BNE ss_stage
    LDA #'.'                        ; none: dots, after the title's blue
.ss_none
    INY : STA (ptr1),Y
    CPY #HS_DIGITS - 2 : BNE ss_none
    INY : INY : BNE ss_score        ; past the yellow
.ss_stage
    CMP #&10 : BCC ss_bin
    SBC #7
.ss_bin
    ADC #3 : STA tmp2
    LDA #TT_GREEN
.ss_dot
    CPY tmp2 : BCC ss_put
    LDA #' '
.ss_put
    STA (ptr1),Y
    LDA #&28                        ; one sixel: a small square
    INY : CPY #HS_DIGITS - 1 : BNE ss_dot
    INY                             ; past the yellow
.ss_score
    JSR ss_bcd : JSR ss_bcd
    INX
    CPX #HS_ENTRIES * 3 : BNE ss_entry
    RTS
.ss_bcd
    LDA hs_data,X : INX
    PHA : LSR A : LSR A : LSR A : LSR A
    JSR ss_digit
    PLA : AND #&0F
.ss_digit
    ORA #'0' : STA (ptr1),Y : INY
    RTS

; in: X = entry * 3, out: ptr1 = its row
.hs_row
    LDA #HI(MODE7_SCREEN + HS_ROW * 40 + HS_COL) : STA ptr1 + 1
    TXA : TAY
    LDA #(LO(MODE7_SCREEN + HS_ROW * 40 + HS_COL) - 40) AND &FF
.hr_next
    CLC : ADC #40
    BCC hr_page
    INC ptr1 + 1
.hr_page
    DEY : DEY : DEY : BPL hr_next
    STA ptr1
    RTS
ASSERT LO(MODE7_SCREEN + HS_ROW * 40 + HS_COL) >= 40

.insert_score
    LDX #0
.is_find
    LDA hs_data,X : CMP score_hi : BCC is_found : BNE is_next
    LDA hs_data + 1,X : CMP score_lo : BCC is_found
.is_next
    INX : INX : INX
    CPX #HS_ENTRIES * 3 : BNE is_find
.is_found
    STX hs_new
    BCS is_ret                      ; C set: none, from the CPX
    TXA : ADC #3 : STA tmp          ; C clear from the BCCs
    LDY #HS_ENTRIES * 3 - 1
.is_shift
    CPY tmp : BCC is_put
    LDA hs_data - 3,Y : STA hs_data,Y
    DEY : BPL is_shift
.is_put
    LDA score_hi : STA hs_data,X
    LDA score_lo : STA hs_data + 1,X
    LDA wave : STA hs_data + 2,X
.is_ret
    RTS

; X = sound * 4; returns X = the next sound's
.sound
    LDY #256 - 8
.snd_copy
    LDA sfx_data,X : STA sound_blk + 8 - 256,Y
    INX : INY : INY : BNE snd_copy
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
    CPX #SND_POWER : BNE ps_one
    STX tune_x : LDA #9 : STA tune_n
    BNE ps_next                     ; SFX_POWER is the last bit: X is done with
.ps_one
    JSR sound
.ps_next
    LDA sfx : BNE ps_bit
.tune_step
    LDA tune_n : BEQ keyv_none
    LDX tune_x : CPX #SND_POWER + 4 : BCC ts_go
    LDA #128 : LDX #&F8 : JSR OSBYTE    ; X = room in channel 3's queue: wait for it,
    TXA : BEQ keyv_none                 ; so OSWORD 7 never blocks
    LDX tune_x
.ts_go
    DEC tune_n
    JSR sound
    STX tune_x
.keyv_none
    RTS

; 8-bit maximal-length LFSR (x^8 + x^4 + x^3 + x^2 + 1)
.random
    LDA rnd : ASL A : BCC rn_done
    EOR #&1D
.rn_done
    STA rnd
    RTS

; channel (+&10 flush), envelope (or -15..-1 fixed), pitch (noise: type), duration
.sfx_data
    EQUB &11, 1, 220, 3             ; SFX_FIRE
    EQUB &12, 3, 230, 24            ; SFX_DIVE
    EQUB &10, 2, 6, 20              ; SFX_DIE
    EQUB &12, 3, 125, 20            ; SFX_RUMBLE: same channel, so it cuts off a dive
    EQUB &12, 4, 172, 8             ; SFX_HIT: Arcadians' warbling tone, cutting off a dive
    EQUB &13, 2, 129, 2 : EQUB 3, 2, 149, 2 : EQUB 3, 2, 165, 2     ; the jingle
    EQUB 3, 2, 149, 2 : EQUB 3, 2, 165, 2 : EQUB 3, 2, 177, 2
    EQUB 3, 2, 165, 2 : EQUB 3, 2, 177, 2 : EQUB 3, 2, 197, 8
    EQUB &13, 2, 101, 2 : EQUB 3, 2, 117, 2 : EQUB 3, 2, 129, 2 : EQUB 3, 2, 149, 6
    EQUB &13, 2, 129, 4 : EQUB 3, 2, 117, 4 : EQUB 3, 2, 105, 4 : EQUB 3, 2, 89, 10
    EQUB &13, 2, TICK_PITCH, 1      ; intro_frame raises its pitch
    EQUB &13, 2, 229, 4             ; the capsule shot
SND_POWER = 5 * 4
SND_WAVE = 14 * 4
SND_OVER = 18 * 4
SND_TICK = 22 * 4
SND_SHOT = 23 * 4

.lo_end
.trail_x                            ; not loaded: filled at each line's launch
    SKIP TRAIL_LEN
.trail_y
    SKIP TRAIL_LEN

ORG &0E00

.main_start

; --- Title screen ---

; format: see tools/title.mjs
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
.dt_byte                            ; out: A = next byte, flags set; Y = 0
    LDY #0
    LDA (ptr0),Y
    INC ptr0 : BNE dt_got
    INC ptr0 + 1
.dt_got
    CMP #0
    RTS

; Low objects go first, plots queued for the next frame's start: chasing the beam
; down to them leaves too little time before vsync. An idle ship bullet fires low,
; so it goes first too; an idle enemy bullet or diver goes last (nothing to draw).
.update_in_beam_order
    LDA frame : AND #1 : TAX        ; the upper of the two rows stepping
    LDA row_y,X : STA order_key
    LDX #BULLETS - 1
.ubo_bullet
    LDA #PLAYER_Y - 4 : STA order_key + 1,X
    LDA bullets_on,X : BEQ ubo_bullet_next
    LDA bullets_y,X : STA order_key + 1,X
.ubo_bullet_next
    DEX : BPL ubo_bullet
    LDA #&FF : STA order_key + 1 + BULLETS
    LDA diver_state : BEQ ubo_abullets
    JSR group_depth                 ; the diver's group goes by its lowest
    CLC : ADC diver_y : STA order_key + 1 + BULLETS
.ubo_abullets
    LDX #ABULLETS - 1
.ubo_abullet
    LDA #&FF : STA order_key + 2 + BULLETS,X
    LDA abullets_on,X : BEQ ubo_abullet_next
    LDA abullets_y,X : STA order_key + 2 + BULLETS,X
.ubo_abullet_next
    DEX : BPL ubo_abullet
    LDA #0 : STA order_done : STA order_n
    INC defer
    LDY #ORDER_N - 1
.ubo_low                            ; the lowest go now; the rest are sorted, highest first
    LDA order_key,Y : CMP #EARLY_Y : BCC ubo_insert
    CMP #&FF : BEQ ubo_low_next
    STY order_idx
    JSR ubo_run
    LDY order_idx
.ubo_low_next
    DEY : BPL ubo_low
    LDA #0 : STA defer : STA order_pos
.ubo_next
    LDX order_pos : CPX order_n : BEQ ubo_rest
    INC order_pos
    LDY sort_idx,X
    LDA order_key,Y : CMP #DEFER_Y : BCC ubo_now      ; low: queued, and so is everything after it
    STA defer
.ubo_now
    JSR ubo_run
    JMP ubo_next
.ubo_insert                         ; A = key, Y = entry; of equal keys the higher entry runs first
    STA tmp : STY tmp2
    LDX order_n : INC order_n
.ubo_shift
    TXA : BEQ ubo_put
    LDY sort_idx - 1,X
    LDA order_key,Y : CMP tmp : BCC ubo_put : BEQ ubo_put
    STY sort_idx,X
    DEX : BPL ubo_shift
.ubo_put
    LDA tmp2 : STA sort_idx,X
    TAY : BPL ubo_low_next
.ubo_rest
    LDA #0 : STA defer
    LDY #ORDER_N - 1
.ubo_idle
    LDA order_done : AND bit_of,Y : BNE ubo_idle_next
    STY order_key                   ; free now: holds the index across the call
    JSR ubo_run
    LDY order_key
.ubo_idle_next
    DEY : BPL ubo_idle
    JMP update_bonus                ; the capsule last: any wait for the beam holds nothing else up
.intro_shots                        ; the ship's bullets alone: orders 1-3
    LDA #NOT(&0E) AND &FF : STA order_done
    BNE ubo_rest
.ubo_run                            ; Y = entry
    LDA order_done : ORA bit_of,Y : STA order_done
    LDA ubo_lo,Y : STA order_vec
    LDA ubo_hi,Y : STA order_vec + 1
    JMP (order_vec)

.bit_of
    EQUB 1, 2, 4, 8, 16, 32, 64, 128
.ubo_lo
    EQUB LO(update_formation), LO(update_bullet_0), LO(update_bullet_1), LO(update_bullet_2), LO(update_diver)
    EQUB LO(update_abullet), LO(update_abullet), LO(update_abullet)
.ubo_hi
    EQUB HI(update_formation), HI(update_bullet_0), HI(update_bullet_1), HI(update_bullet_2), HI(update_diver)
    EQUB HI(update_abullet), HI(update_abullet), HI(update_abullet)
ASSERT ABULLETS = 3 AND BULLETS = 3 AND ORDER_N = 8   ; update_abullet: AND #3, - 1; update_bullet_0: Y - 1; order_done: a byte

; in vblank: in MODE 2 each logical colour is one ULA palette entry, so no plots
.pulse_capsule                      ; 8 frames each colour
    LDA frame : LSR A : LSR A : AND #FLAG_FLASH : EOR #FLAG_PHYS
    EOR #FLAG_COLOUR * 16 + 7       ; the ULA stores colours inverted
    STA ULA_PALETTE
    EOR #STAR_COLOUR * 16           ; and its copy with the star bit set
    STA ULA_PALETTE
    RTS

.split_start                        ; cyan wings down to SPLIT_Y, where timer 1 runs out
    LDA #LO((BEAM_TOP + SPLIT_Y DIV 4) * 256) : STA USR_T1CL
    LDA #HI((BEAM_TOP + SPLIT_Y DIV 4) * 256) : STA USR_T1CH
    LDA wing_ula : STA ULA_PALETTE
    EOR #STAR_COLOUR * 16 : STA ULA_PALETTE
    RTS

; IRQ2V: timer 1 runs out as the beam nears the ship, whose wings take the power level's colour
.ship_split
    LDA USR_T1CL                    ; clears the interrupt
    TXA : PHA
    LDX power : LDA wing_ula,X : STA ULA_PALETTE
    EOR #STAR_COLOUR * 16 : STA ULA_PALETTE
    PLA : TAX
    LDA &FC                         ; the OS saved A here
    RTI
.wing_ula                           ; single shot cyan, double yellow, rapid fire red
    EQUB WING_COLOUR * 16 + (6 EOR 7), WING_COLOUR * 16 + (3 EOR 7), WING_COLOUR * 16 + (1 EOR 7)

; --- Starfield ---

; ~45us a moving star, 55us at 2px
.update_stars_top
    LDA #&80 : BNE us_begin
.update_stars_rest                  ; must follow update_stars_top
    LDA #&40 : BNE us_begin
.update_stars
    LDA #0
.us_begin
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
.us_wrap_at
    CMP #256 - 2 : BCC us_next      ; self-modified by intro_frame
.us_mark
    LDA frame : STA star_done,X
.us_go
    LDA star_hi,X : STA ptr0 + 1
    LDY star_lo,X
    LDA (ptr0),Y : EOR star_vis,X : STA (ptr0),Y
    LDA warp_n : STA star_n
.us_move
    CPX #NUM_STARS / 3 : BCS us_one
    INC star_y,X : BEQ us_wrap
    LDA star_y,X : AND #7 : BEQ us_cell2
    INY
.us_one
    INC star_y,X : BEQ us_wrap
    LDA star_y,X : AND #7 : BEQ us_cell1
    INY
.us_moved
    DEC star_n : BPL us_move
.us_draw
    TYA : STA star_lo,X
    LDA (ptr0),Y : EOR star_vis,X : STA (ptr0),Y
.us_next
    DEX : BPL us_star
    RTS
.us_cell2
    JSR us_cell : JMP us_one
.us_cell1
    JSR us_cell : JMP us_moved
.us_cell
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
    LDA star_vis,X : BEQ us_moved
    LDA star_bit,X : STA star_vis,X
    JMP us_moved

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

; star_of: in the order before grouping
.twinkle_pair
    LDX twinkle_i : LDA star_of,X : TAX : JSR star_toggle
    TXA : CLC : ADC #NUM_STARS / 6 : TAX    ; the same speed group
    ; fall through

; X = star
.star_toggle
    LDA star_lo,X : STA ptr0 : LDA star_hi,X : STA ptr0 + 1
    LDY #0
    LDA (ptr0),Y : EOR star_bit,X : STA (ptr0),Y
    LDA star_vis,X : EOR star_bit,X : STA star_vis,X
    RTS

; X = star; out: star_lo/hi/bit, ptr0 = address, Y = 0. star_vis untouched
.star_place
    LDA star_y,X : LSR A : LSR A : LSR A : TAY
    LDA star_x,X : LSR A
    LDA #&80 : BCC spl_left
    LSR A
.spl_left
    STA star_bit,X
    LDA star_x,X : ROL A : ROL A : ROL A : AND #3 : STA tmp
    LDA star_x,X : AND #&3E : ASL A : ASL A
    ADC crow_lo,Y : STA ptr0
    LDA crow_hi,Y : ADC tmp : STA ptr0 + 1 : STA star_hi,X
    LDA star_y,X : AND #7 : ORA ptr0 : STA ptr0 : STA star_lo,X  ; cell addresses are multiples of 8
    LDY #0
    RTS

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

; --- Raster clock ---

; wait for the beam to pass row X, so a plot there shows next frame (A unused)
.beam_guard
    LDA defer : BNE bg_done         ; queued: drawn next frame, ahead of the beam
    TXA : CLC : ADC #2 : ROR A : LSR A          ; (X + 2) DIV 4, 9-bit: row 4k+1 ends 40us before unit k + 8
    CLC : ADC #BEAM_TOP + 1 : STA guard_bot
.bg_wait
    LDA USR_T2H : EOR #&FF          ; elapsed, in 256us units
    CMP guard_bot : BCC bg_wait
.bg_done
    RTS

; --- Player ---

; runs straight after vsync: the beam is far from the bottom rows, so no beam guard
.update_player
    LDA fire_cool : BEQ up_cooled
    DEC fire_cool
.up_cooled
    LDA player_state : BEQ up_play
    LDX #0 : STX keys
    CMP #PS_SLIDE : BEQ up_slide : BCS up_ret
    DEC player_t : BEQ up_gone
    LDA player_t : SEC : SBC #DIE_TIME - FLASH_TIME : BCC up_blink
    TAX : LDA flash_ula,X : STA bg_colour
.up_blink
    LDA player_t : AND #DIE_BLINK - 1 : BNE up_ret
    JMP draw_player
.up_gone
    LDA #PS_OVER
    LDX lives : BEQ up_state
    DEC ships_shown
    LDA ships_shown : JSR spare_x : STA player_x
    LDA #SPARE_Y : STA player_row
    LDA #PS_SLIDE
.up_state
    STA player_state
.up_ret
    RTS
.up_slide
    JSR draw_player
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
    STX ships_shown : DEX : TXA : JSR spare_x : TAX
    LDY #SPARE_Y : LDA #SPR_PLAYER : JSR plot_at
.up_keys
    JSR up_step                     ; 1.5px a frame: a second step every other frame
    LDA frame : LSR A : BCC up_done
.up_step
    LDA keys : AND #KEY_LEFT : BEQ up_not_left
    LDA player_x : CMP #SHIP_MIN_X : BEQ up_done
    DEC player_x
    LDA player_x                    ; moving left: delta sits at the new x
    JMP up_move
.up_not_left
    LDA keys : AND #KEY_RIGHT : BEQ up_done
    LDA player_x : CMP #SHIP_MAX_X : BCS up_done
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

; --- Player bullets ---

.update_bullet_2                    ; rapid fire's third shot
    LDA power : LSR A : ORA bullets_on + 2 : BEQ up_done
    LDY #3
    LDA bullets_on + 2 : BNE update_bullet_0
    INC defer                       ; idle: a shot fired now is drawn next frame, as in the low pass
    JSR update_bullet_0
    DEC defer
    RTS
.update_bullet_1                    ; the double shot's second
    LDA power : ORA bullets_on + 1 : BNE update_bullet_0
    RTS
.update_bullet_0                    ; Y = order entry 1-3 (from ubo_run): bullet Y - 1
    DEY : TYA : TAX
    JSR bullet_load
    JSR update_bullet
    LDX bullet_idx
    JMP bullet_save

.bullet_save
    LDA bullet_on : STA bullets_on,X
    LDA bullet_x : STA bullets_x,X
    LDA bullet_y : STA bullets_y,X
    RTS

.update_bullet
    LDA bullet_on : BNE ub_move
    LDA fire_cool : BNE ub_done
    LDA keys : AND #KEY_FIRE : BEQ ub_done
    LDX #FIRE_DELAY
    LDA power : LSR A : BEQ ub_cool
    LDX #RAPID_DELAY
.ub_cool
    STX fire_cool
    LDA player_x : CLC : ADC #3 : STA bullet_x
    LDA #PLAYER_Y - 4 : STA bullet_y
    LDA #1 : STA bullet_on
    SFX SFX_FIRE
    LDX #PLAYER_Y - 1 : JSR beam_guard
    JMP draw_bullet
.ub_move
    LDA bullet_y : CLC : ADC #3 : TAX
    JSR beam_guard                  ; old and new positions together
    LDA bullet_y : SEC : SBC #BULLET_SPEED
    CMP #BULLET_TOP : BCC ub_off
    STA bullet_y : STA draw_y
    LDA bullet_x : STA draw_x
    LDA #SPR_BULLET_STEP : STA draw_id
    JSR plot_image
    JMP check_bullet_hits
.ub_off
    JSR draw_bullet
    LDA #0 : STA bullet_on
.ub_done
    RTS

.draw_bullet
    LDA #SPR_BULLET : LDX bullet_x : LDY bullet_y
    JMP plot_at

.kill_bullet
    LDA bullet_y : JSR beam_guard_alien
    JSR draw_bullet
    LDA #0 : STA bullet_on
    RTS

; overlap: bullet_x - ax is -1..ALIEN_W - 1 and bullet_y - ay is -3..ALIEN_H - 1
.check_bullet_hits
    LDA USR_T2H : CMP #256 - LATE_HIT : BCC ub_done
    LDA intro : BNE ub_done         ; nothing to hit until the aliens have landed
    LDA bonus_on : BEQ cbh_aliens
    LDX bonus_x : DEX
    LDA bonus_y : JSR cbh_near : BCS cbh_aliens
    JMP shoot_capsule
.cbh_aliens
    LDA diver_state : BNE cbh_diver
    JMP cbh_form
.cbh_diver
    LDA lead_gone : BNE cbh_wings
    LDA diver_y : LDX diver_x : JSR cbh_near : BCS cbh_wings
    JSR kill_bullet
    LDA diver_y : STA hit_y : JSR beam_guard_alien
    JSR draw_diver
    LDX diver_slot : LDA #ALIVE_GONE : STA alive,X
    LDY diver_slot : JSR score_dive
    LDA wing_on : ORA wing_on + 1 : STA lead_gone
    BNE cbh_line
    BEQ cbh_over
.cbh_wings
    LDX #WINGS - 1
.cbh_wing
    STX wing_k
    LDA wing_on,X : BEQ cbh_wnext
    LDA diver_y : CLC : ADC wing_oy,X : STA hit_y
    LDA diver_x : CLC : ADC wing_ox,X : TAX
    LDA hit_y : JSR cbh_near : BCC cbh_whit
    LDX wing_k
.cbh_wnext
    DEX : BPL cbh_wing
    JMP cbh_form
.cbh_whit
    JSR kill_bullet
    LDA hit_y : JSR beam_guard_alien
    LDX wing_k : JSR draw_wing
    LDX wing_k : LDY wing_slot,X
    LDA #ALIVE_GONE : STA alive,Y : STA wing_on,X
    JSR score_dive
    LDA lead_gone : BEQ cbh_line
    LDA wing_on : ORA wing_on + 1 : BNE cbh_line
.cbh_over                           ; A = 0
    LDY diver_y : CPY #DIVER_BOTTOM : BCS cbh_line  ; some of a line may yet be out: it comes back
    STA diver_state : STA diver_wrap
.cbh_line
    DEC line_left : BNE cbh_scored
    LDA #LINE_TOTAL : LDY diver_slot : CPY #BOSS_SLOT : BNE cbh_bonus
    LDA #BOSS_TOTAL
.cbh_bonus
    SED : SEC : SBC swoop_pts : CLD
    JSR add_score
    SFX SFX_POWER
.cbh_scored                         ; X = the slot shot, or a wing's index
    JSR expl_start
    DEC alive_count
    JSR bonus_drop
    SFX SFX_HIT
    RTS

.play_tune
    LDA #0 : STA tune_n             ; they cut off a tune still going out
    JSR sound : JSR sound : JSR sound
    JMP sound

; --- Alien fire ---
; alien_fire only decides; an idle enemy bullet draws the shot in beam order

.af_end
    LDA #0 : STA burst_left
    RTS
.alien_fire
    LDA #0 : STA fire_n             ; a shot no bullet was free for is dropped
    LDA player_state : BNE af_end
    LDA diver_state : CMP #DIVER_DIVE : BNE af_end
    LDA diver_slot : CMP #BOSS_SLOT : BEQ af_wings  ; the boss never fires: af_queue sends its guards to af_guard
    LDA burst_left : BNE af_burst
    LDA afire_armed : BEQ af_done
    DEC burst_gap : BNE af_done     ; the rush's pause; 1 for a dive's first burst
    INC burst_gap                   ; 1: the burst fires as it opens
    LDX level
    LDA diver_t : CMP #LOOP_LEN : BCC af_done   ; still looping out of the formation
    LDA diver_y : CMP afire_tops,X : BCC af_done
    LDA diver_x : JSR af_range : BCC af_done
    LDA #0 : STA afire_armed
    JSR random : AND #1 : CLC : ADC burst_mins,X : STA burst_left
.af_burst
    DEC burst_gap : BNE af_done
    LDA #BURST_GAP : STA burst_gap
    LDA diver_y : CLC : ADC #ALIEN_H
    CMP #AFIRE_LOW + 1 : BCS af_end
.af_shot
    DEC burst_left : BNE af_lead
    LDA alive_count : CMP #RUSH_COUNT + 1 : BCS af_lead
    INC afire_armed                 ; the rush: another burst, after a pause
    LDA #BURST_PAUSE : STA burst_gap
.af_lead
    LDX lead_gone : BNE af_wings
    LDX diver_x : JSR af_queue
.af_wings
    LDY #WINGS - 1
.af_wing
    LDA wing_on,Y : BEQ af_wnext
    LDA diver_x : CLC : ADC wing_ox,Y : TAX
    LDA diver_y : CLC : ADC wing_oy,Y : ADC #ALIEN_H
    BCS af_wnext
    CMP #AFIRE_LOW + 1 : BCS af_wnext
    JSR af_queue
.af_wnext
    DEY : BPL af_wing
.af_done
    RTS
.update_abullet                     ; Y = order entry 5-7 (from ubo_run): bullet Y - 5
    TYA : AND #3 : TAX : DEX
    STX abullet_idx
    LDA abullets_on,X : BNE ua_move
    LDY fire_n : BEQ ua_done
    DEY : STY fire_n
    LDA fire_x,Y : STA abullets_x,X
    LDA #1 : STA abullets_on,X
    LDA fire_y,Y : STA abullets_y,X
    JSR abullet_pos
.ua_show                            ; A = draw_y
    CMP #DEFER_Y : BCC ua_now
    INC defer                       ; low: queued for the next frame's start
    JSR abullet_draw
    DEC defer
    RTS
.ua_now
    CLC : ADC #3 : TAX : JSR beam_guard
    JMP abullet_draw
.ua_move
    LDA abullets_y,X : CLC : ADC #ABULLET_SPEED + 3 : BCC ua_guard
    LDA #255                        ; leaving the bottom: only the old position is on screen
.ua_guard
    TAX : JSR beam_guard            ; old and new positions together
    LDX abullet_idx
    LDA abullets_y,X : CMP #ABULLET_BOTTOM - ABULLET_SPEED + 1 : BCS ua_off
    JSR abullet_pos
    LDA #SPR_ABULLET_STEP : STA draw_id
    JSR plot_image
    LDX abullet_idx
    LDA abullets_y,X : CLC : ADC #ABULLET_SPEED : STA abullets_y,X
    SEC : SBC #PLAYER_Y - 3 : CMP #11 : BCS ua_done
    LDA abullets_x,X : SEC : SBC player_x : CMP #8 : BCS ua_done
    LDA player_state : BNE ua_done
    JSR player_hit
.ua_off
    JSR abullet_pos
    JSR abullet_draw
    LDX abullet_idx : LDA #0 : STA abullets_on,X
.ua_done
    RTS

.abullet_pos
    LDA abullets_x,X : STA draw_x
    LDA abullets_y,X : STA draw_y
    RTS

.abullet_draw
    LDA #SPR_ABULLET : STA draw_id
    JMP plot_image

; --- Formation ---
; two rows step a frame, top first: 0 and 2, then 1 and 3, so the formation moves as one

.update_formation
    LDA frame : AND #1 : STA form_row
    JSR uf_row
    LDA form_row : BNE uf_lower
    JSR boss_follow
.uf_lower
    LDA form_row : ORA #2 : STA form_row
    JMP uf_row

; the beam is past row 0's rows, so past the boss's too
.boss_follow
    LDA alive + BOSS_SLOT : CMP #ALIVE_HOME : BNE bf_ret
    JSR boss_pos
    LDA slot_x : CMP boss_x : BNE bf_move
    LDA slot_y : CMP boss_y : BEQ bf_ret
.bf_move
    JSR boss_draw
.bf_place
    LDA slot_x : STA boss_x
    LDA slot_y : STA boss_y
.boss_draw
    LDA #SPR_BOSS : LDX boss_x : LDY boss_y
    JMP plot_at
.bf_ret
    RTS

.uf_row
    LDX form_row
    LDA row_y,X : STA draw_y
    LDA row_spr,X : ORA row_anim,X : STA draw_id
    LDA frame : AND #6 : CMP #2 : BNE uf_sway   ; one step in 4 breathes; never a wing beat's
    JMP uf_breathe
.uf_sway
    LDA row_x,X : STA tmp2
    CLC : ADC row_dir,X : STA row_x,X
    CMP #FX_MIN : BEQ uf_flip
    CMP #FX_MAX : BNE uf_moved
.uf_flip
    LDA row_dir,X : EOR #&FE : STA row_dir,X    ; 1 <-> &FF
.uf_moved
    LDA row_x,X : CMP tmp2 : BCS uf_right       ; moving right: it sits at the old x
    STA tmp2                                    ; moving left: the delta starts at the new x
    LDA frame : AND #FLAP_PERIOD - 2 : BNE uf_dir       ; a beat: both frames of a row pair's steps
    LDA draw_id : EOR #1 : STA draw_id          ; and at the new frame
    BNE uf_flap
.uf_right
    LDA frame : AND #FLAP_PERIOD - 2 : BNE uf_dir       ; a beat: both frames of a row pair's steps
.uf_flap
    LDA row_anim,X : EOR #1 : STA row_anim,X    ; flap: cross delta, so flapping costs no extra plot
    LDA draw_id : CLC : ADC #CROSS_OFS : STA draw_id
.uf_dir
    JSR uf_guard
    JMP uf_col

; out: loop_i = the row's first slot
.uf_guard
    LDA #ALIEN_H - 1
.uf_guard_h                         ; A = height - 1
    CLC : ADC draw_y : TAX
    JSR beam_guard
    LDA form_row : ASL A : ASL A : ASL A : SEC : SBC form_row : STA loop_i    ; * 7
    RTS

.uf_col
    LDX form_row : LDA row_bofs,X : STA old_x
.uf_col_loop
    LDX loop_i
    LDA alive,X : CMP #ALIVE_HOME : BNE uf_next
    LDA old_x : CLC : ADC slot_col,X : TAY
    LDA tmp2 : ADC slot_px,X : ADC breath,Y : STA draw_x
    JSR plot_delta
.uf_next
    LDX loop_i : INX : INX : STX loop_i
    LDA slot_col,X : LSR A : BNE uf_col_loop    ; even columns 0, 2, 4, 6 then odd 1, 3, 5: same x AND 1
    BCC uf_ret                                  ; after column 5: the next row's column 0
    TXA : SBC #FORM_COLS : STA loop_i : BPL uf_col_loop     ; after column 6: column 1, carry set
.uf_ret
    RTS

.uf_breathe
    LDA row_bofs,X : STA old_x
    CLC : ADC row_bdir,X : STA row_bofs,X
    BEQ uf_bflip
    CMP #BREATH_STEPS * FORM_COLS : BNE uf_bmoved
.uf_bflip
    LDA #0 : SEC : SBC row_bdir,X : STA row_bdir,X
.uf_bmoved
    LDA row_bofs,X : CLC : ADC form_row : TAY : LDA vbreath,Y : STA new_y
    LDA old_x : CLC : ADC form_row : TAY : LDA vbreath,Y
    EOR #&FF : SEC : ADC new_y : STA new_y
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
    EOR #&FF : SEC : ADC tmp2 : STA tmp2
    ORA new_y : BEQ uf_bnext
    JSR slot_pos
    LDA slot_x
    LDY tmp2 : CPY #1 : BNE uf_bx
    SBC #1                          ; moving right: the delta starts at the old x
.uf_bx
    STA draw_x
    LDY form_row : LDA row_spr,Y : ORA row_anim,Y
    LDY new_y : BEQ uf_bplot
    CLC : ADC #VERT_OFS
.uf_bplot
    STA draw_id
    JSR plot_delta
.uf_bnext
    INC loop_i
    LDX loop_i : LDA slot_col,X : BNE uf_bcol
    RTS

; X = slot (boss too), preserved; out: slot_x / slot_y = its home now
.home_pos
    CPX #BOSS_SLOT : BNE slot_pos
.boss_pos
    LDA row_x : CLC : ADC #BOSS_DX : STA slot_x
    LDY row_bofs                    ; a row above row 0: it breathes further
    LDA row_y : ADC vbreath + FORM_ROWS,Y : STA slot_y      ; C clear from the ADC
    RTS

; X = slot, preserved; out: slot_x / slot_y
.slot_pos
    LDY slot_row,X
    LDA row_x,Y : CLC : ADC slot_px,X : STA slot_x
    LDA row_bofs,Y : ADC slot_col,X : TAY       ; carry clear: x < 256
    LDA slot_x : CLC : ADC breath,Y : STA slot_x
    LDY slot_row,X : LDA row_y,Y : STA slot_y
    RTS

.bullet_load
    STX bullet_idx
    LDA bullets_on,X : STA bullet_on
    LDA bullets_x,X : STA bullet_x
    LDA bullets_y,X : STA bullet_y
    RTS

; --- Diver ---

.update_diver
    LDA diver_state : BEQ ud_idle
    JMP ud_active
.ud_idle
    LDA player_state : BNE ud_done
    LDA alive_count : CMP #RUSH_COUNT + 1 : BCS ud_count
    LDA dive_timer : CMP #RUSH_DELAY + 1 : BCC ud_count
    LDA #RUSH_DELAY : STA dive_timer
.ud_count
    DEC dive_timer : BNE ud_done
    LDX level : LDA dive_delays,X : STA dive_timer
    LDY #FORM_SLOTS
.ud_pick
    LDA diver_pick : CLC : ADC #DIVE_STRIDE
    CMP #FORM_SLOTS : BCC ud_picked
    SBC #FORM_SLOTS
.ud_picked
    STA diver_pick : TAX
    LDA alive,X : CMP #ALIVE_HOME : BEQ ud_launch
    DEY : BNE ud_pick
.ud_done
    RTS

.ud_launch                          ; the alien is already drawn where the diver starts
    LDA slot_row,X : EOR frame : LSR A : BCS ud_go
    LDA #1 : STA dive_timer         ; its row stepped this frame: launch next frame instead,
    TXA : SEC : SBC #DIVE_STRIDE    ; or the step and the first dive move would show together
    BCS ud_retry
    ADC #FORM_SLOTS
.ud_retry
    STA diver_pick
    RTS
.ud_go
    SFX SFX_DIVE
    STX diver_slot
    LDA #ALIVE_DIVING : STA alive,X
    LDA #0 : STA wing_on : STA wing_on + 1 : STA lead_gone
    STA wing_shot : STA wing_shot + 1 : STA line_left : STA diver_half : STA swoop_pts
    LDA #BOSS_SLOT : STA wing_slot : STA wing_slot + 1  ; never diving in a line: line_regroup skips it
    CPX #BOSS_SLOT : BEQ ud_guards
    LDA slot_row,X : STA tmp
    LDY #2
.ud_near                            ; an upper row takes a neighbour; a lower row a line of the two nearest, however far
    TYA : LSR A : BCC ud_near_side  ; Y / 2 columns away: right, then left
    EOR #&FF                        ; carry set: minus Y / 2
.ud_near_side
    ADC diver_slot : TAX
    CPX #BOSS_SLOT : BCS ud_near_next
    LDA slot_row,X : CMP tmp : BNE ud_near_next
    LDA alive,X : CMP #ALIVE_HOME : BNE ud_near_next
    TXA : LDX wing_on : STA wing_slot,X : INC wing_on,X
    DEX : BEQ ud_solo               ; that was the second
.ud_near_next
    INY
    CPY #4 : BCC ud_near
    LDA tmp : LSR A : BEQ ud_solo   ; rows above LAP_ROW: next door only
    CPY #2 * FORM_COLS : BCC ud_near
    BCS ud_solo
ASSERT LAP_ROW = 2 AND WINGS = 2 AND FORM_ROWS = 4
.ud_guards
    LDX #WINGS - 1
.ud_side
    TXA : TAY
.ud_guard
    LDA guard_order,Y : STA tmp
    STY tmp2 : LDY tmp
    LDA alive,Y : LDY tmp2
    CMP #ALIVE_HOME : BEQ ud_guard_ok
    INY : INY : CPY #GUARD_N : BCC ud_guard
    BCS ud_side_next
.ud_guard_ok
    LDA tmp : STA wing_slot,X
    INC wing_on,X
.ud_side_next
    DEX : BPL ud_side
    LDA wing_on : AND wing_on + 1 : BEQ ud_solo
    LDA #3 : STA line_left
.ud_solo
    LDX diver_slot
    JSR home_pos
    LDA slot_x : STA diver_x
    LDA slot_y : STA diver_y
    LDX #WINGS - 1
.ud_wset
    LDA wing_on,X : BEQ ud_wset_next
    STX wing_k
    LDA wing_slot,X : TAX
    LDA #ALIVE_DIVING : STA alive,X
    JSR slot_pos
    LDY slot_row,X : LDA row_anim,Y
    LDX wing_k : STA wing_anim,X
    LDA slot_x : SEC : SBC diver_x : STA wing_ox,X : STA wing_tgt,X
    LDA slot_y : SEC : SBC diver_y : STA wing_oy,X
.ud_wset_next
    DEX : BPL ud_wset
    LDX diver_slot
    LDY slot_row,X : LDA row_anim,Y : STA diver_anim
    LDA #0 : STA diver_t : STA diver_vx
    LDA #8 : STA diver_xf
    LDY #0
    LDA diver_x : CMP #PLAYER_MAX_X - 2 * LOOP_R + 1 : BCS ud_loop_left
    CMP #PLAYER_MAX_X / 2 : BCS ud_loop_set
    CMP #2 * LOOP_R : BCC ud_loop_set
.ud_loop_left
    DEY
.ud_loop_set
    STY diver_left
    LDA #0 : LDY slot_row,X : CPY #LAP_ROW : BCC ud_lap_set
    LDA diver_x : CMP #PLAYER_MAX_X / 2     ; loops towards the middle: it always fits on screen
    LDA #0 : SBC #0 : STA diver_left
    LDY #TRAIL_LEN - 1
.ud_trail_fill
    LDA diver_x : STA trail_x,Y
    LDA diver_y : STA trail_y,Y
    DEY : BPL ud_trail_fill
    LDA wing_on + 1 : ASL A : ORA wing_on + 1 : STA line_left   ; 3 with both wings, else 0
    LDA #3
.ud_lap_set
    STA diver_lap
    LDA #DIVER_DIVE : STA diver_state
    STA afire_armed                 ; A = DIVER_DIVE
    STA burst_gap                   ; the first burst opens with no pause
    CPX #BOSS_SLOT : BNE ud_active
    RTS                             ; the boss waits: a guard's row may have just stepped

.ud_active
    LDA diver_x : STA new_x
    LDA diver_y : STA new_y
    LDA diver_state : CMP #DIVER_DIVE : BEQ ud_dive
    JMP ud_return
.ud_dive
    LDA diver_anim : STA new_anim
    LDA frame : AND #FLAP_PERIOD - 1 : BNE ud_path
    LDA new_anim : EOR #1 : STA new_anim
.ud_path
    LDY diver_lap : CPY #3 : BNE ud_path_t
    LDA new_y : CLC : ADC #DIVER_SPEED : CMP #LAP_Y : BCC ud_dropping
    DEC diver_lap
    LDA #LAP_Y
.ud_dropping
    STA new_y
    JMP ud_move
.ud_path_t
    LDX diver_t : CPX #LOOP_LEN : BCC ud_arc
    LDY diver_lap : CPY #2 : BNE ud_swoop
    DEC diver_lap
    LDX #0 : STX diver_t
.ud_arc
    LDY diver_lap : BEQ ud_arc_on
    LDA diver_half : EOR #1 : STA diver_half : BNE ud_arc_go
.ud_arc_on
    INC diver_t
.ud_arc_go
    LDA loop_dx,X
    LDY diver_left : BEQ ud_loop_dx
    EOR #&FF : CLC : ADC #1
.ud_loop_dx
    LDY diver_lap : CPY #2 : BNE ud_loop_x  ; a full loop's first half is its second turned about:
    EOR #&FF : CLC : ADC #1                 ; down, across and up, ending heading down into the swoop
.ud_loop_x
    CLC : ADC new_x : STA new_x
    LDA loop_dy,X
    CPY #2 : BNE ud_loop_dy
    EOR #&FF : CLC : ADC #1
.ud_loop_dy
    CLC : ADC new_y
    CMP #DIVER_TOP : BCS ud_loop_y  ; the boss starts high: keep its loop under the HUD
    LDA #DIVER_TOP
.ud_loop_y
    STA new_y
    JMP ud_clamp

.ud_swoop
    LDA new_y : CLC : ADC #DIVER_SPEED : STA new_y
    JSR group_depth
    CLC : ADC new_y : BCS ud_wrap
    CMP #DIVER_BOTTOM : BCC ud_steer
    LDA diver_lap : BEQ ud_wrap
    LDA #DIVER_BOTTOM : STA new_y   ; a line's lead waits, hidden, for the rest to fly out after it
    LDA lead_gone : BEQ ud_to_move
    LDA wing_on : ORA wing_on + 1 : BNE ud_to_move
.ud_wrap
    LDA #DIVER_RETURN : STA diver_state
    INC diver_wrap                  ; leave it drawn where it is; diver_reenter moves it
    RTS
.ud_steer                           ; overshoot gives the weave
    LDY #1
    LDA alive_count : CMP #RUSH_COUNT + 1 : BCS ud_turn
    INY                             ; the rush: turns twice as hard
.ud_turn
    LDA player_x : CMP new_x : BEQ ud_glide : BCC ud_pull_left
    LDA diver_vx : CMP #DIVE_VMAX : BEQ ud_glide
    INC diver_vx
    JMP ud_turned
.ud_pull_left
    LDA diver_vx : CMP #256 - DIVE_VMAX : BEQ ud_glide
    DEC diver_vx
.ud_turned
    DEY : BNE ud_turn
.ud_glide
    LDA diver_xf : CLC : ADC diver_vx       ; -24..39
    TAY : AND #15 : STA diver_xf
    TYA : CMP #&80 : ROR A : CMP #&80 : ROR A : CMP #&80 : ROR A : CMP #&80 : ROR A
    CLC : ADC new_x : STA new_x
.ud_clamp
    LDA new_x : CMP #PLAYER_MAX_X + 1 : BCC ud_move
    CMP #&C0 : LDA #0 : BCS ud_clamped
    LDA #PLAYER_MAX_X
.ud_clamped
    STA new_x
    LDA #0 : STA diver_vx
.ud_to_move
    JMP ud_move

.ud_return
    LDA diver_y : BMI ud_wrap       ; crashed into the ship: its last move, queued, is drawn this frame; re-enter on the next
    LDX diver_slot : JSR home_pos
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
    LDA new_x : SEC : SBC diver_x : STA lead_d
    LDA new_y : SEC : SBC diver_y : STA lead_d + 1
    LDX diver_slot : JSR home_pos
    LDA slot_x : STA lead_hx
    LDA slot_y : STA lead_hy
    LDA #0 : STA moved
    LDX #WINGS - 1
.um_wing
    LDA wing_on,X : BEQ um_next
    JSR um_one
.um_next
    DEX : BPL um_wing

.ud_draw
    LDA trail_i : AND #TRAIL_LEN - 1 : TAY
    LDA new_x : STA trail_x,Y
    LDA new_y : STA trail_y,Y
    INY : STY trail_i
    JSR group_depth : STA tmp2
    LDA diver_y : CMP new_y : BCS ud_lower
    LDA new_y
.ud_lower
    SEC : ADC tmp2                  ; + 1: a wing may step down
    JSR beam_guard_alien
    JSR draw_group
    LDA new_x : STA diver_x
    LDA new_y : STA diver_y
    LDA new_anim : STA diver_anim
    LDX #3 * WINGS - 1
.ud_copy
    LDA wing_nox,X : STA wing_ox,X
    DEX : BPL ud_copy
    JSR line_hide
    JSR draw_group
    LDA diver_state : CMP #DIVER_RETURN : BNE ud_flying
    LDA moved : BNE ud_flying
    LDA diver_y : CMP lead_hy : BNE ud_flying
    LDA diver_x : CMP lead_hx : BNE ud_flying
    LDA #DIVER_NONE : STA diver_state       ; docked: the images are already in the slots
    LDA #ALIVE_HOME
    LDX lead_gone : BNE ud_dock_wings
    LDX diver_slot : STA alive,X
    CPX #BOSS_SLOT : BNE ud_dock_wings
    LDY diver_x : STY boss_x        ; where boss_follow finds its image
    LDY diver_y : STY boss_y
.ud_dock_wings
    LDX #WINGS - 1
.ud_dock_wing
    LDY wing_on,X : BEQ ud_dock_next
    LDY wing_slot,X : STA alive,Y
.ud_dock_next
    DEX : BPL ud_dock_wing
.ud_flying
    RTS

; X = an active wing, preserved
.um_one
    STX wing_k
    LDA wing_ox,X : STA wing_nox,X
    LDA wing_oy,X : STA wing_noy,X
    LDA diver_state : CMP #DIVER_DIVE : BNE um_home
    LDA diver_lap : BNE um_trail
    LDA diver_slot : CMP #BOSS_SLOT : BNE um_home
    LDA flank,X : STA wing_tgt,X
    LDA #ROW_STEP : BNE um_tgt_y    ; a row below the boss, as in formation
.um_home
    LDA wing_slot,X : TAX : JSR slot_pos : LDX wing_k
    LDA slot_x : SEC : SBC lead_hx : STA wing_tgt,X
    LDA slot_y : SEC : SBC lead_hy
.um_tgt_y
    STA wing_tgt + 2,X
    ; one axis at a time, so a guard never crosses the boss
    TXA
    LDY diver_state : CPY #DIVER_DIVE : BEQ um_first
    ORA #2
.um_first
    TAX : JSR um_axis
    LDA wing_nox,X : CMP wing_tgt,X : BNE um_anim
    TXA : EOR #2 : TAX : JSR um_axis
.um_anim
    LDX wing_k
    LDA diver_state : CMP #DIVER_DIVE : BNE um_ranim
    LDA new_anim : EOR diver_anim : EOR wing_anim,X
    BPL um_aset
.um_ranim
    LDY wing_slot,X : LDA slot_row,Y : TAY : LDA row_anim,Y
.um_aset
    STA wing_nanim,X
    LDA new_x : CLC : ADC wing_nox,X
    CMP #PLAYER_MAX_X + 1 : BCC um_ret
    LDY #PLAYER_MAX_X
    CMP #&C0 : BCC um_edge
    LDY #0
.um_edge
    TYA : SEC : SBC wing_nox,X : STA new_x
.um_ret
    RTS
; on the lead's own path, TRAIL frames per place behind; wing_tgt: how far off it still is, as it joins
.trail_back
    EQUB TRAIL, 2 * TRAIL
.um_trail
    LDA trail_i : SEC : SBC trail_back,X : AND #TRAIL_LEN - 1 : TAY
    LDA trail_y,Y : SEC : SBC new_y : STA wing_noy,X
    LDA trail_x,Y : CLC : ADC wing_tgt,X : SEC : SBC new_x : STA wing_nox,X
    LDA wing_tgt,X : BEQ um_trailed : BMI um_join_up
    DEC wing_tgt,X
    BPL um_trailed
.um_join_up
    INC wing_tgt,X
.um_trailed
    JMP um_anim

; A line leaves the bottom one at a time, each hidden as it gets there
.line_hide
    LDA diver_lap : BEQ lh_done
    LDA diver_y : CMP #DIVER_BOTTOM : BCC lh_wings
    STA lead_gone
.lh_wings
    LDX #WINGS - 1
.lh_wing
    LDA diver_y : CLC : ADC wing_oy,X : CMP #DIVER_BOTTOM : BCC lh_next
    LDA #0 : STA wing_on,X
.lh_next
    DEX : BPL lh_wing
.lh_done
    RTS

; Everyone still alive back in view, side by side as at home, above the lead's slot
.line_regroup
    LDX diver_slot : LDA alive,X : CMP #ALIVE_DIVING : BNE lr_slot
    LDA #0 : STA lead_gone
.lr_slot
    JSR home_pos
    LDA slot_x : STA diver_x
    LDX #WINGS - 1
.lr_wing
    STX wing_k
    LDY wing_slot,X : LDA alive,Y : CMP #ALIVE_DIVING : BNE lr_next
    LDA #1 : STA wing_on,X
    TYA : TAX : JSR slot_pos
    LDX wing_k
    LDA slot_x : SEC : SBC diver_x : STA wing_ox,X
    LDA #0 : STA wing_oy,X
.lr_next
    DEX : BPL lr_wing
    RTS

; Move the diver to REENTER_Y straight after vsync, while the beam is above both
; positions: chasing the beam to the bottom would leave no time before vsync.
.diver_reenter
    JSR draw_group
    LDA diver_lap : BEQ dr_top
    JSR line_regroup
.dr_top
    LDA #REENTER_Y : STA diver_y
    JSR draw_diver                  ; the highest here: it must beat the beam
    LDX #1 : JSR draw_wing
    LDX #0 : JSR draw_wing
    JMP update_stars_top


.draw_group                         ; the last in a line first: queued, the highest must beat the beam
    LDX #1 : JSR draw_wing
    LDX #0 : JSR draw_wing
    JMP draw_diver
.draw_wing                          ; X = wing
    LDA wing_on,X : BEQ dd_done
    LDA diver_y : CLC : ADC wing_oy,X : STA draw_y
    LDA diver_x : CLC : ADC wing_ox,X : STA draw_x
    LDY wing_anim,X
    LDA wing_slot,X : TAX
    JMP dd_plot
.draw_diver
    LDA lead_gone : BNE dd_done
    LDA diver_y : STA draw_y
    LDA diver_x : STA draw_x
    LDY diver_anim
    LDX diver_slot
.dd_plot                            ; X = slot, Y = flap frame
    STY draw_id
    LDA #SPR_BOSS
    CPX #BOSS_SLOT : BEQ dd_boss    ; one frame: it flashes instead
    LDY slot_row,X : LDA row_spr,Y : ORA draw_id
.dd_boss
    STA draw_id
    JMP plot_image
.dd_done
    RTS

.check_player_hit
    LDA player_state : BNE cph_none
    LDA diver_state : CMP #DIVER_DIVE : BNE cph_none
    LDA lead_gone : BNE cph_wings
    LDA diver_y : LDX diver_x : JSR cph_near : BCC cph_crash
.cph_wings
    LDY #WINGS - 1
.cph_wing
    LDA wing_on,Y : BEQ cph_wnext
    LDA diver_x : CLC : ADC wing_ox,Y : TAX
    LDA diver_y : CLC : ADC wing_oy,Y
    JSR cph_near : BCC cph_crash
.cph_wnext
    DEY : BPL cph_wing
    RTS
.cph_crash
    LDA #DIVER_RETURN : STA diver_state
    ; fall through

.player_hit
    SFX SFX_DIE OR SFX_RUMBLE
    LDA #0 : STA power
    DEC lives
    LDA #PS_DYING : STA player_state
    LDA #DIE_TIME : STA player_t
.cph_none
    RTS
.cph_near                           ; A = top row, X = x: carry clear if it overlaps the ship. Y preserved
    CMP #PLAYER_Y - ALIEN_H + 1
    BCC cph_far
    TXA : SEC : SBC player_x : CLC : ADC #ALIEN_W - 1   ; 8-wide ship
    CMP #ALIEN_W + 7
    RTS
.cph_far
    SEC
    RTS

; --- Sprite plotter ---

; EOR: queued plots can be drawn in any order
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

.flush_plots                        ; in queue order: the deferred go top first, erase before draw
    LDX #0
.fp_plot
    CPX queue_n : BEQ fp_done
    STX order_idx                   ; free now: holds the index across the plot
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
    LDX order_idx : INX : BNE fp_plot
.fp_done
    LDA #0 : STA queue_n
    RTS

; Column-major so one X index walks every column; column addresses are patched in.
; Each image stores only the columns it uses; the row loop starts at its last one.
.draw_player
    LDA #SPR_PLAYER : LDX player_x : LDY player_row
.plot_at                            ; A = id, X = x, Y = y
    STA draw_id : STX draw_x : STY draw_y
.plot_image
    LDA defer : BNE queue_image
    LDA draw_id : CMP #SPR_BULLET_STEP : BCC pi_index
    CMP #SPR_BONUS : BCS pi_index
    JMP plot_narrow

; applying it again moves back, so a move left from x uses the delta at x - 1
.plot_delta
    LDA defer : BNE queue_delta
    LDA draw_id : CLC : ADC #(dlt_lo - img_lo) DIV 2
.pi_index
    TAY
    LDA draw_x : LSR A
    TYA : ROL A : TAX
    LDY draw_id : LDA spr_h,Y : STA draw_h
    CPX pl_last_id : BEQ pl_patched ; same table entry as last time: columns and pl_row already patched
.pl_patch
    STX pl_last_id
    CPX #dlt_lo - img_lo : LDA img_entry,X : BCC pl_entry  ; an image: its own table
    LDA #9 : CPX #dlt_lo - img_lo + 2 : BCC pl_entry        ; a delta: the player's has 5 columns,
    TXA : SBC #dlt_lo - img_lo + 2 * (SPR_FLAGSHIP + VERT_OFS) : CMP #12 : BCS pl_six
    LSR A : LDA #9 : BCC pl_entry                           ; a vertical step's whole image 5 at even x
.pl_six
    LDA #0                                                  ; and the other aliens' 6
.pl_entry
    CLC : ADC #LO(pl_col) : STA pl_row + 1                  ; the high byte never changes
    LDA img_lo,X : STA PL_COL0 + 1
    LDY img_hi,X : STY PL_COL0 + 2
FOR c, 1, SPR_BYTES - 1
    ADC draw_h : STA PL_COL0 - 9 * c + 1
    BCC P% + 4 : INY : CLC
    STY PL_COL0 - 9 * c + 2
NEXT
.pl_patched
    JSR screen_ptrs
    LDA draw_y : AND #7 : TAY
    LDX #0
.pl_row
    JMP pl_col                      ; patched: the image's last column
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
ASSERT HI(pl_col) = HI(PL_COL0) AND SPR_BYTES = 6 AND ALIEN_W = 10   ; pl_row's high byte; the delta entries

; one byte column, or two for a bullet step at odd x: no columns to patch.
; A = draw_id, tmp = draw_x AND 1. Leaves through pl_done, as plot does.
.plot_narrow
    TAY : LDA spr_h,Y : STA draw_h
    LDA draw_x : LSR A
    TYA : ROL A : TAX
    LDA img_lo,X : STA pn_byte + 1
    LDA img_hi,X : STA pn_byte + 2
    LDA draw_y : LSR A : LSR A : LSR A : TAY
    LDA draw_x : ROL A : ROL A : ROL A : AND #3 : STA tmp
    LDA draw_x : AND #&3E : ASL A : ASL A
    ADC crow_lo,Y : STA ptr0
    LDA crow_hi,Y : ADC tmp : STA ptr0 + 1
    LDY #0
    CPX #SPR_BULLET_STEP * 2 + 1 : BNE pn_one
    LDA ptr0 : ADC #8 - 1 : STA ptr1    ; carry set by CPX
    LDA ptr0 + 1 : ADC #0 : TAY
.pn_one                             ; ptr1 = the second column's cell, or high byte 0: none
    STY ptr1 + 1
    LDX #0
.pn_column
    LDA draw_y : AND #7 : TAY
.pn_byte
    LDA &FFFF,X : EOR (ptr0),Y : STA (ptr0),Y   ; patched: the image
    INX : CPX draw_h : BEQ pn_next
    INY : CPY #8 : BNE pn_byte
    LDA ptr0 : ADC #LO(640) - 1 : STA ptr0      ; carry set: down a character row
    LDA ptr0 + 1 : ADC #HI(640) : STA ptr0 + 1
    LDY #0 : BEQ pn_byte
.pn_next
    LDA ptr1 + 1 : BEQ pl_done
    STA ptr0 + 1 : LDA ptr1 : STA ptr0
    LDA #0 : STA ptr1 + 1
    ASL draw_h                      ; the second column's rows follow the first's
    BNE pn_column
ASSERT SPR_ABULLET = SPR_BULLET_STEP + 1 AND SPR_ABULLET_STEP = SPR_ABULLET + 1 AND SPR_BONUS = SPR_ABULLET + 2

; out: ptr0.. = cells of byte columns from draw_x DIV 2 on draw_y's row, Y = 0
.screen_ptrs
    LDA draw_y : LSR A : LSR A : LSR A : TAY
    LDA draw_x : ROL A : ROL A : ROL A : AND #3 : STA tmp     ; draw_x DIV 64: the byte column * 8, high
    LDA draw_x : AND #&3E : ASL A : ASL A                     ; and low; carry clear (x < 160)
    ADC crow_lo,Y : STA ptr0
    LDA crow_hi,Y : ADC tmp
    BCC sp_cols                     ; always: carry clear

; ptr0.. down one character row; out: Y = 0
.next_cell
    LDA ptr0 : ADC #LO(640) - 1 : STA ptr0  ; carry set by CPY #8
    LDA ptr0 + 1 : ADC #HI(640)     ; the high byte never carries: screen < &8000
.sp_cols                            ; A = ptr0's high byte, C clear: the other columns follow ptr0
    STA ptr0 + 1 : TAY              ; Y: X is pl_row's row counter
    LDA ptr0
FOR c, 1, SPR_BYTES - 1
    ADC #8 : STA ptr0 + 2 * c
    BCC P% + 4 : INY : CLC
    STY ptr0 + 2 * c + 1
NEXT
    LDY #0
    RTS

.cbh_boss_home
    LDA #BOSS_POINTS : JSR add_score
    JMP cbh_scored
.score_form
    LDY loop_i : JSR slot_points
    JMP add_score
.score_dive                         ; Y = the slot; X is kept
    JSR slot_points
    ASL A
    PHA
    SED : CLC : ADC swoop_pts : STA swoop_pts : CLD
    PLA
    JMP add_score
.slot_points                        ; Y = the slot; X is kept
    LDA #BOSS_POINTS
    CPY #BOSS_SLOT : BEQ sp_ret
    LDA slot_row,Y : TAY : LDA row_points,Y
.sp_ret
    RTS
.row_points
    EQUB &04, &03, &02, &02

; the capsule falls on, still to be caught
.shoot_capsule
    JSR kill_bullet
    LDA capsule_pts : JSR add_score
    LDA capsule_pts : CMP #CAPSULE_MAX : BCS sc_top
    INC capsule_pts
.sc_top
    LDA #SND_SHOT : STA tune_x
    LDA #1 : STA tune_n
    RTS

; A = the wave (BCD); past the last level, dives come a frame sooner each wave, down to a rush
.set_level
    CMP #LEVELS + 1 : BCC sl_level
    LDA dive_delays + LEVELS - 1 : CMP #RUSH_DELAY + 1 : BCC sl_last
    DEC dive_delays + LEVELS - 1
.sl_last
    LDA #LEVELS : CLC
.sl_level
    SBC #0 : STA level              ; carry clear: - 1
    RTS

.af_range                           ; A = x, X = level: carry set if near the player
    SEC : SBC player_x : SEC : SBC #(6 - ALIEN_MID) AND &FF  ; middles: x + ALIEN_MID and x + 6
    CLC : ADC afire_ranges,X : STA tmp
    LDA afire_ranges,X : ASL A
    CMP tmp
    RTS
.af_queue                           ; A = shot's top row, X = alien's x
    PHA
    LDA diver_slot : CMP #BOSS_SLOT : BNE af_q
    JMP af_guard                    ; Y = the guard
.af_q
    TXA : LDX fire_n
    CLC : ADC #ALIEN_MID : STA fire_x,X
    PLA : STA fire_y,X
    INC fire_n
    RTS

; --- Keyboard and text ---

; Z wins if both directions are held
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
IF DEBUG
    LDX #KEY_P : JSR key_down       ; A = 0 down, &80 up
    TAX : EOR dbg_up : AND dbg_up   ; just pressed
    STX dbg_up
    BEQ rk_ret
    LDX power : INX : CPX #3 : BCC rk_power
    LDX #0
.rk_power
    STX power
    SFX SFX_POWER
.rk_ret
ENDIF
    RTS
IF DEBUG
.dbg_up
    EQUB 0
ENDIF

; X = matrix code, out: Z set if down. Direct VIA read: OSBYTE 129 took ~130us a key.
; IRQs off so the OS can't reprogram port A halfway through.
.key_down
    SEI
    LDA #&03 : STA SYS_ORB          ; latch bit 3 low: stop the keyboard auto-scan
    LDA #&7F : STA SYS_DDRA         ; bits 0-6 select the key, bit 7 reads it
    STX SYS_ORA_NH
    LDA SYS_ORA_NH
    LDX #&0B : STX SYS_ORB          ; auto-scan back on
    CLI
    AND #&80 : EOR #&80
    RTS

.print_hud
    LDA #0 : STA hud_dirty
    LDX #3
.ph_digit
    STX hud_k
    TXA : LSR A : EOR #1 : TAY
    LDA score_lo,Y
    BCS ph_low
    LSR A : LSR A : LSR A : LSR A
.ph_low
    AND #&0F
    CMP shown,X : BEQ ph_next
    STA shown,X
    JSR print_digit
.ph_next
    LDX hud_k : DEX : BPL ph_digit
    RTS

; A = glyph (0-9, then WAVE), X = text column
.print_digit
    LDY #0 : STY glyph_mode
    BEQ glyph_at
.col_glyph                          ; at column tmp2, row draw_y, then the next column
    LDX tmp2 : INC tmp2 : LDY draw_y    ; EORed: colours 0-7, so a star under it survives
    PHA                                 ; and a second call removes it
    LDA #&FF : STA glyph_mode : PLA
.glyph_at                           ; Y = top pixel row
    STY draw_y
    ASL A : ASL A : ASL A : STA glyph_i
    TXA : ASL A : ASL A : ASL A : STA draw_x
    JSR screen_ptrs                             ; Y = 0
.ga_row
    LDX glyph_i : LDA font1,X : PHA
    LSR A : LSR A : LSR A : LSR A : TAX
    LDA (ptr0),Y : AND glyph_mode : EOR nib_l,X : STA (ptr0),Y
    LDA (ptr1),Y : AND glyph_mode : EOR nib_r,X : STA (ptr1),Y
    PLA : AND #&0F : TAX
    LDA (ptr2),Y : AND glyph_mode : EOR nib_l,X : STA (ptr2),Y
    LDA (ptr3),Y : AND glyph_mode : EOR nib_r,X : STA (ptr3),Y
    INC glyph_i : INY : CPY #8 : BNE ga_row
    RTS
GLYPH_BITS = (GLYPH_COLOUR AND 1) + (GLYPH_COLOUR AND 2) * 2 + (GLYPH_COLOUR AND 4) * 4   ; a right-hand pixel
.nib_l
FOR n, 0, 15 : EQUB (n DIV 4) * GLYPH_BITS : NEXT
.nib_r
FOR n, 0, 15 : EQUB (n AND 3) * GLYPH_BITS : NEXT

; X/Y = address of a length-prefixed VDU byte string
.print_vdu
    STX ptr0 : STY ptr0 + 1
    LDY #0
    LDA (ptr0),Y : STA tmp
.pv_loop
    INY
    LDA (ptr0),Y : JSR OSWRCH
    CPY tmp : BNE pv_loop
    RTS

; --- Data ---

.hs_data
    EQUB &05, &00, 0, &04, &00, 0, &03, &00, 0, &02, &00, 0, &01, &00, 0
.hs_new
    EQUB HS_ENTRIES * 3
.txt_game_over
    EQUB 12, 31, 6, 15 : EQUS "GAME OVER"
.txt_mode7
    EQUB 12, 22, 7, 23, 1, 0, 0, 0, 0, 0, 0, 0, 0      ; MODE 7, cursor off

.crow_lo
FOR r, 0, 31 : EQUB LO(SCREEN + r * 640) : NEXT
.crow_hi
FOR r, 0, 31 : EQUB HI(SCREEN + r * 640) : NEXT

.slot_px                            ; TRUE is -1
FOR i, 0, FORM_COUNT - 1
    c = i MOD FORM_COLS : pull = VAL(MID$(FORM_PULL, i DIV FORM_COLS + 1, 1))
    EQUB c * COL_STEP - pull * (c < FORM_COLS DIV 2) + pull * (c > FORM_COLS DIV 2)
NEXT
.slot_row
FOR i, 0, FORM_COUNT - 1 : EQUB i DIV FORM_COLS : NEXT
    EQUB 0                          ; the boss: it moves with row 0
.star_of
FOR i, 0, NUM_STARS / 2 - 1 : EQUB 10 * (i MOD 3) + i DIV 3 : NEXT
.star_x0
FOR j, 0, NUM_STARS - 1 : i = 3 * (j MOD 10) + j DIV 10 : EQUB (i * 135 + i * i * 10 + 7) MOD 160 : NEXT    ; quadratic: no lines
.star_y0
FOR j, 0, NUM_STARS - 1 : i = 3 * (j MOD 10) + j DIV 10 : EQUB STAR_TOP + (i * 189 + i * i * 8) MOD (256 - STAR_TOP) : NEXT

.slot_start
FOR i, 0, FORM_COUNT - 1 : EQUB VAL(MID$(FORM_SHAPE, i + 1, 1)) * ALIVE_HOME : NEXT
    EQUB ALIVE_HOME
.slot_col                           ; one extra entry so the last row's walk ends on 0
FOR i, 0, FORM_COUNT : EQUB i MOD FORM_COLS : NEXT
    EQUB 1                          ; ends uf_col's odd pass on the last row

.afire_tops
    EQUB 96, 80, 64, 56, 48, 40, 36, 32
.afire_ranges
    EQUB 24, 32, 40, 44, 48, 52, 56, 60
.burst_mins                         ; this or one more: 3 at most
    EQUB 1, 2, 2, 2, 2, 2, 2, 2
.dive_delays
    EQUB 80, 55, 40, 30, 22, 16, 13, DIVE_LAST
ASSERT P% - dive_delays = LEVELS

.row_y0
FOR r, 0, FORM_ROWS - 1 : EQUB FORM_Y + r * ROW_STEP : NEXT
.breath                             ; [step * FORM_COLS + col]
FOR s, 0, BREATH_STEPS
    b = s - (s + 1) * VBREATH_MAX DIV (BREATH_STEPS + 1)
    FOR c, 0, FORM_COLS - 1
        EQUB ((1 + 2 * (2 * c < FORM_COLS - 1)) * INT(ABS(2 * c - FORM_COLS + 1) * b / (FORM_COLS - 1) + 0.5)) AND &FF
    NEXT
NEXT
.vbreath                            ; [step * FORM_COLS + row]
ASSERT FORM_ROWS < FORM_COLS
FOR s, 0, BREATH_STEPS
    v = (s + 1) * VBREATH_MAX DIV (BREATH_STEPS + 1)
    FOR r, 0, FORM_COLS - 1
        IF r < FORM_ROWS
            EQUB ((1 + 2 * (2 * r < FORM_ROWS - 1)) * INT(ABS(2 * r - FORM_ROWS + 1) * v / (FORM_ROWS - 1) + 0.5)) AND &FF
        ELIF r = FORM_ROWS          ; the boss, from row 0's y: a row up, and out further, 1px a step at most
            EQUB (INT((FORM_ROWS - 1) * v / (FORM_ROWS - 1) + 0.5) - INT((FORM_ROWS + 1) * s * VBREATH_MAX / ((FORM_ROWS - 1) * BREATH_STEPS) + 0.5) - ROW_STEP) AND &FF
        ELSE
            EQUB 0
        ENDIF
    NEXT
NEXT
.flash_ula                          ; last frame first: back to black
    EQUB &07, &06, &06, &06, &04, &04, &00, &00
.row_spr                            ; frame 1 is id + 1
    EQUB SPR_FLAGSHIP, SPR_ESCORT, SPR_DRONE, SPR_DRONE
.guard_order                        ; nearest first: left at even entries; not the middle column
FOR r, 0, FORM_ROWS - 1 : FOR c, 0, FORM_COLS DIV 2 - 1
    EQUB r * FORM_COLS + FORM_COLS DIV 2 - 1 - c, r * FORM_COLS + FORM_COLS DIV 2 + 1 + c
NEXT : NEXT
GUARD_N = P% - guard_order
.step_min
    EQUB -DIVE_XMAX AND &FF, -DIVER_SPEED AND &FF
; Peel-off half loop; dx is for a loop to the right
.loop_dx
FOR i, 0, LOOP_LEN - 1
    EQUB (INT(LOOP_R * (1 - COS(PI * (i + 1) / LOOP_LEN)) + 0.5) - INT(LOOP_R * (1 - COS(PI * i / LOOP_LEN)) + 0.5)) AND &FF
NEXT
.loop_dy                            ; twice as tall: a pixel is twice as wide as it is high, so it looks round
FOR i, 0, LOOP_LEN - 1
    EQUB (INT(2 * LOOP_R * SIN(PI * i / LOOP_LEN) + 0.5) - INT(2 * LOOP_R * SIN(PI * (i + 1) / LOOP_LEN) + 0.5)) AND &FF
NEXT

; --- Sprites ---

; Two MODE 2 pixels (colours 0-15): left in bits 7,5,3,1, right in bits 6,4,2,0
MACRO PIXELS2 kl, kr
    EQUB (kl AND 8)*16 + (kl AND 4)*8 + (kl AND 2)*4 + (kl AND 1)*2 + (kr AND 8)*8 + (kr AND 4)*4 + (kr AND 2)*2 + (kr AND 1)
ENDMACRO

; Art: w digits per row (colours 0-9), h rows, no blank left column

MACRO IMAGE art, w, h, s
FOR b, 0, (s + w + 1) DIV 2 - 1
FOR r, 0, h - 1
    q = "00" + MID$(art, r * w + 1, w) + "000000"
    PIXELS2 VAL(MID$(q, b*2 + 3 - s, 1)), VAL(MID$(q, b*2 + 4 - s, 1))
NEXT
NEXT
ENDMACRO

MACRO DELTA art1, art2, w, h, s
FOR b, 0, (s + w) DIV 2
FOR r, 0, h - 1
    q = "00" + MID$(art1, r * w + 1, w) + "000000"
    p = "00" + MID$(art2, r * w + 1, w) + "000000"
    PIXELS2 VAL(MID$(q, b*2 + 3 - s, 1)) EOR VAL(MID$(p, b*2 + 2 - s, 1)), VAL(MID$(q, b*2 + 4 - s, 1)) EOR VAL(MID$(p, b*2 + 3 - s, 1))
NEXT
NEXT
ENDMACRO

MACRO VDELTA art, w, h, s, d
FOR b, 0, (s + w + 1) DIV 2 - 1
FOR r, 0, h + d - 1
    IF r < h : q = "00" + MID$(art, r * w + 1, w) + "000000" : ELSE : q = STRING$(w + 8, "0") : ENDIF
    IF r >= d : p = "00" + MID$(art, (r - d) * w + 1, w) + "000000" : ELSE : p = STRING$(w + 8, "0") : ENDIF
    PIXELS2 VAL(MID$(q, b*2 + 3 - s, 1)) EOR VAL(MID$(p, b*2 + 3 - s, 1)), VAL(MID$(q, b*2 + 4 - s, 1)) EOR VAL(MID$(p, b*2 + 4 - s, 1))
NEXT
NEXT
ENDMACRO
MACRO VDELTAS art, w, h, d
FOR s, 0, 1 : VDELTA art, w, h, s, d : NEXT
ENDMACRO

MACRO IMAGES art, w, h
FOR s, 0, 1 : IMAGE art, w, h, s : NEXT
ENDMACRO
MACRO DELTAS art1, art2, w, h
FOR s, 0, 1 : DELTA art1, art2, w, h, s : NEXT
ENDMACRO

; entry offset: 9 bytes of plotter code skipped per unused column
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

; Logical colours: 1 red, 2 pulsing yellow, 3 the boss's flashing, 4 blue, 5 magenta, 6 cyan, 7 white
ART_PLAYER = "00077000" + "00077000" + "00777700" + "06755760" + "66777766" + "67777776" + "60077006" + "00500500"
ART_BULLET = "77" + "77" + "77" + "77"
ART_BULLET_STEP = "77777777" + STRING$(BULLET_SPEED - 4, "00") + "77777777"
ART_ABULLET = "1" + "7" + "7" + "7"
ART_BONUS   = "0222220" + "2244422" + "2242422" + "2244422" + "2242222" + "2242222" + "0222220" + "0000000"
ART_FLAGSHIP   = "0000110000" + "0006666000" + "7706006077" + "7776666777" + "0776006770" + "0006666000" + "0061661600" + "0060000600"
ART_FLAGSHIP_B = "7700110077" + "7776666777" + "0776006770" + "0006666000" + "0006006000" + "0006666000" + "0061661600" + "0060000600"
ART_ESCORT     = "0000110000" + "0001111000" + "5017117105" + "5111111115" + "5011111105" + "5001111005" + "5000110005" + "5500000055"
ART_ESCORT_B   = "0000110000" + "5001111005" + "5117117115" + "5111111115" + "0511111150" + "0011111100" + "0001111000" + "0000110000"
ART_EXPL      = "1002001" + "0207020" + "0027200" + "2777772" + "0027200" + "0207020" + "1002001" + "0000000"
ART_BOSS       = "4000330004" + "4003333004" + "4133113314" + "4131111314" + "4441111444" + "0440110440" + "0000110000" + "0000110000"
ART_DRONE      = "0400000040" + "0040000400" + "0055555500" + "0574554750" + "6555555556" + "6056556506" + "6060000606" + "0606006060"
ART_DRONE_B    = "0040000400" + "0040000400" + "6055555506" + "6574554756" + "0555555550" + "0056556500" + "0606006060" + "6006006006"

.gfx_player       : IMAGES ART_PLAYER, 8, 8
.gfx_player_d     : DELTAS ART_PLAYER, ART_PLAYER, 8, 8
.gfx_bullet       : IMAGES ART_BULLET, 2, 4
.gfx_bullet_step  : IMAGES ART_BULLET_STEP, 2, 4 + BULLET_SPEED
.gfx_abullet      : IMAGES ART_ABULLET, 1, 4
.gfx_abullet_step : VDELTAS ART_ABULLET, 1, 4, ABULLET_SPEED
.gfx_bonus_0      : IMAGE ART_BONUS, BONUS_W, ALIEN_H, 0  ; bonus_x is even: no shift 1
.gfx_expl         : IMAGE ART_EXPL, EXPL_W, ALIEN_H, 0
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
.gfx_boss         : IMAGES ART_BOSS, ALIEN_W, ALIEN_H

; ids: 0 player, 1 bullet, 2-7 aliens, 8 bullet step, 9 enemy bullet, 10 its step,
;      11 capsule, 12 boss, 13 explosion; deltas: 11-16 cross, 17-22 vertical
.spr_h
    EQUB 8, 4
    FOR i, 2, 7 : EQUB ALIEN_H : NEXT
    EQUB 4 + BULLET_SPEED, 4, 4 + ABULLET_SPEED
    FOR i, 11, 16 : EQUB ALIEN_H : NEXT
    FOR i, 17, 22 : EQUB ALIEN_H + 1 : NEXT
.img_lo
    IMG_LO gfx_player, 8, 8 : IMG_LO gfx_bullet, 2, 4
    IMG_LO gfx_flagship, ALIEN_W, ALIEN_H : IMG_LO gfx_flagship_b, ALIEN_W, ALIEN_H
    IMG_LO gfx_escort, ALIEN_W, ALIEN_H : IMG_LO gfx_escort_b, ALIEN_W, ALIEN_H
    IMG_LO gfx_drone, ALIEN_W, ALIEN_H : IMG_LO gfx_drone_b, ALIEN_W, ALIEN_H
    IMG_LO gfx_bullet_step, 2, 4 + BULLET_SPEED
    IMG_LO gfx_abullet, 1, 4 : IMG_LO gfx_abullet_step, 1, 4 + ABULLET_SPEED
    EQUB LO(gfx_bonus_0), LO(gfx_bonus_0)
    IMG_LO gfx_boss, ALIEN_W, ALIEN_H
    EQUB LO(gfx_expl), LO(gfx_expl)   ; either shift: it never moves
.dlt_lo
    DLT_LO gfx_player_d, 8, 8
.flank                              ; in the holes: ids 1 and 8-10 have no delta
    EQUB -FLANK AND &FF, FLANK
    DLT_LO gfx_flagship_d, ALIEN_W, ALIEN_H : DLT_LO gfx_flagship_b_d, ALIEN_W, ALIEN_H
    DLT_LO gfx_escort_d, ALIEN_W, ALIEN_H : DLT_LO gfx_escort_b_d, ALIEN_W, ALIEN_H
    DLT_LO gfx_drone_d, ALIEN_W, ALIEN_H : DLT_LO gfx_drone_b_d, ALIEN_W, ALIEN_H
    EQUB 0, 0, 0, 0, 0, 0             ; the hole for ids 8-10: spare
    DLT_LO gfx_flagship_ab, ALIEN_W, ALIEN_H : DLT_LO gfx_flagship_ba, ALIEN_W, ALIEN_H
    DLT_LO gfx_escort_ab, ALIEN_W, ALIEN_H : DLT_LO gfx_escort_ba, ALIEN_W, ALIEN_H
    DLT_LO gfx_drone_ab, ALIEN_W, ALIEN_H : DLT_LO gfx_drone_ba, ALIEN_W, ALIEN_H
    IMG_LO gfx_flagship_v, ALIEN_W, ALIEN_H + 1 : IMG_LO gfx_flagship_b_v, ALIEN_W, ALIEN_H + 1
    IMG_LO gfx_escort_v, ALIEN_W, ALIEN_H + 1 : IMG_LO gfx_escort_b_v, ALIEN_W, ALIEN_H + 1
    IMG_LO gfx_drone_v, ALIEN_W, ALIEN_H + 1 : IMG_LO gfx_drone_b_v, ALIEN_W, ALIEN_H + 1
.img_hi
    IMG_HI gfx_player, 8, 8 : IMG_HI gfx_bullet, 2, 4
    IMG_HI gfx_flagship, ALIEN_W, ALIEN_H : IMG_HI gfx_flagship_b, ALIEN_W, ALIEN_H
    IMG_HI gfx_escort, ALIEN_W, ALIEN_H : IMG_HI gfx_escort_b, ALIEN_W, ALIEN_H
    IMG_HI gfx_drone, ALIEN_W, ALIEN_H : IMG_HI gfx_drone_b, ALIEN_W, ALIEN_H
    IMG_HI gfx_bullet_step, 2, 4 + BULLET_SPEED
    IMG_HI gfx_abullet, 1, 4 : IMG_HI gfx_abullet_step, 1, 4 + ABULLET_SPEED
    EQUB HI(gfx_bonus_0), HI(gfx_bonus_0)
    IMG_HI gfx_boss, ALIEN_W, ALIEN_H
    EQUB HI(gfx_expl), HI(gfx_expl)
.dlt_hi
    DLT_HI gfx_player_d, 8, 8
.step_max
    EQUB DIVE_XMAX, DIVER_SPEED
    DLT_HI gfx_flagship_d, ALIEN_W, ALIEN_H : DLT_HI gfx_flagship_b_d, ALIEN_W, ALIEN_H
    DLT_HI gfx_escort_d, ALIEN_W, ALIEN_H : DLT_HI gfx_escort_b_d, ALIEN_W, ALIEN_H
    DLT_HI gfx_drone_d, ALIEN_W, ALIEN_H : DLT_HI gfx_drone_b_d, ALIEN_W, ALIEN_H
    EQUB 0, 0, 0, 0, 0, 0             ; the hole for ids 8-10: spare
    DLT_HI gfx_flagship_ab, ALIEN_W, ALIEN_H : DLT_HI gfx_flagship_ba, ALIEN_W, ALIEN_H
    DLT_HI gfx_escort_ab, ALIEN_W, ALIEN_H : DLT_HI gfx_escort_ba, ALIEN_W, ALIEN_H
    DLT_HI gfx_drone_ab, ALIEN_W, ALIEN_H : DLT_HI gfx_drone_ba, ALIEN_W, ALIEN_H
    IMG_HI gfx_flagship_v, ALIEN_W, ALIEN_H + 1 : IMG_HI gfx_flagship_b_v, ALIEN_W, ALIEN_H + 1
    IMG_HI gfx_escort_v, ALIEN_W, ALIEN_H + 1 : IMG_HI gfx_escort_b_v, ALIEN_W, ALIEN_H + 1
    IMG_HI gfx_drone_v, ALIEN_W, ALIEN_H + 1 : IMG_HI gfx_drone_b_v, ALIEN_W, ALIEN_H + 1
.img_entry
    IMG_ENTRY 8 : IMG_ENTRY 2
    IMG_ENTRY ALIEN_W : IMG_ENTRY ALIEN_W : IMG_ENTRY ALIEN_W : IMG_ENTRY ALIEN_W : IMG_ENTRY ALIEN_W : IMG_ENTRY ALIEN_W
    EQUB 0, 0, 0, 0, 0, 0             ; the hole: ids 8-10 (plot_narrow) never read img_entry; spare
    IMG_ENTRY BONUS_W
    IMG_ENTRY ALIEN_W
    IMG_ENTRY EXPL_W
.ula_setup                          ; logical * 16 + physical EOR 7
    EQUB STAR_COLOUR * 16 + (7 EOR 7)
    EQUB 9 * 16 + (1 EOR 7)         ; 9-15: a sprite colour over a star shows the sprite
    FOR c, 12, 15 : EQUB c * 16 + ((c - 8) EOR 7) : NEXT   ; 2 and 10: pulse_capsule
    EQUB BOSS_COLOUR * 16 + (BOSS_PHYS EOR 7), (BOSS_COLOUR + 8) * 16 + (BOSS_PHYS EOR 7)
.ula_setup_end
.vdu_setup
    EQUB vdu_setup_end - vdu_setup - 1
    EQUB 22, 2
    EQUB 23, 1, 0, 0, 0, 0, 0, 0, 0, 0   ; cursor off
.vdu_setup_end

.end
ASSERT end <= SCREEN              ; the loader below only runs at load time

; --- Bonus capsule ---
; fills the end of the run-time state page; the loader puts it there

ORG state_end
GUARD &0800
.hi_start

.update_bonus
    LDA bonus_on : BEQ bn_ret
    CMP #2 : BNE ubn_move
    DEC bonus_on
    RTS
.ubn_move                           ; bonus_on 1 and 3 by turns: 3 falls 2px, so 1.5px a frame
    EOR #2 : STA bonus_on
    LSR A : LSR A : PHP             ; C: this frame falls 2px
    LDA bonus_y : ADC #ALIEN_H : TAX   ; the new bottom row
    JSR beam_guard                  ; old and new positions together
    JSR bonus_draw
    PLP
    LDA bonus_y : ADC #1 : STA bonus_y
    CMP #BONUS_BOTTOM : BCS ubn_off
    LDX player_state : BNE bonus_draw
    CMP #PLAYER_Y - 6 : BCC bonus_draw
    CMP #PLAYER_Y + 8 : BCS bonus_draw
    LDA player_x : SBC bonus_x : CLC : ADC #8   ; C clear from the BCS: x - capsule x - 1 + 8
    CMP #BONUS_W + 7 : BCS bonus_draw
    LDA power : CMP #2 : BCS P% + 4
    INC power                       ; a level up: the double shot, then rapid fire
    SFX SFX_POWER
.ubn_off
    LDA #0 : STA bonus_on
.bn_ret
    RTS

; the beam is past the shot alien's rows, so past the capsule's: it starts above them
.bonus_drop                         ; X = the slot shot (or a wing)
    CPX #BOSS_SLOT : BNE bn_ret
    LDA bonus_on : BNE bn_ret
    LDA alive_count : BEQ bn_ret    ; the wave's last alien: the stage ends
    LDA #2 : STA bonus_on
    LDA bullet_x : SBC #(BONUS_W - 1) DIV 2 : AND #&FE : STA bonus_x   ; C set by the CPX; even: one image
    LDA hit_y : CMP #BONUS_LOW + BONUS_LIFT : BCC bn_high
    LDA #BONUS_LOW + BONUS_LIFT : BCS bn_lift   ; shot low: it pops up clear of the ship
.bn_high
    CMP #DIVER_TOP + BONUS_LIFT : BCS bn_lift
    LDA #DIVER_TOP + BONUS_LIFT + 1 ; carry clear: SBC takes 1 more
.bn_lift
    SBC #BONUS_LIFT : STA bonus_y
.bonus_draw
    LDA #SPR_BONUS : LDX bonus_x : LDY bonus_y
    JMP plot_at

; Each guard fires once, and only if its shot won't pass over the boss or the other
; guard (checked even once shot: their path flies on).
.af_guard                           ; shot's row pushed, X = guard's x, Y = guard
    LDA wing_shot,Y : BNE afg_no
    STX afb_x
    LDX level
    LDA diver_y : CMP afire_tops,X : BCC afg_no
    LDA afb_x : JSR af_range : BCC afg_no
    LDA wing_ox,Y : JSR afb_clear : BCC afg_no     ; the boss
    TYA : EOR #1 : TAX
    LDA wing_ox,Y : SBC wing_ox,X   ; C set by afb_clear
    JSR afb_clear : BCC afg_no      ; the other guard
    LDA #1 : STA wing_shot,Y
    LDX afb_x : JMP af_q
.afg_no
    PLA
    RTS

; --- Explosion ---

.expl_clear                        ; the wave is over: the explosion goes now
    LDA expl_t : BEQ ux_ret
    LDA #1 : STA expl_t
.update_expl                       ; after the sprites (defer 0): drawn, then erased EXPL_TIME on
    LDX expl_t : BEQ ux_ret
    DEX : STX expl_t : BEQ ux_plot
    CPX #EXPL_TIME : BNE ux_ret
.ux_plot
    LDA expl_y : CMP #DEFER_Y : ROL defer      ; low: queued, drawn ahead of the beam next frame
    ADC #ALIEN_H - 1 : TAX : JSR beam_guard     ; carry clear: defer was 0
    LDA #SPR_EXPL : LDX expl_x : LDY expl_y
    JSR plot_at
    LSR defer
.ux_ret
    RTS

INCLUDE "title.asm"
.hi_end

; --- OS workspace blocks ---
; Free once the loader has run (checked in jsbeeb through play, game over, initials
; and the title); the loader copies these blocks there.

ORG &0100                           ; the stack page: the stack never gets below &01D3
GUARD &01C3
.b1_start

.cbh_form
    LDA alive + BOSS_SLOT : CMP #ALIVE_HOME : BNE cbh_rows
    LDA boss_y : LDX boss_x : JSR cbh_near : BCS cbh_rows
    JSR kill_bullet
    LDA boss_y : STA hit_y : JSR beam_guard_alien
    JSR boss_draw
    LDX #BOSS_SLOT : LDA #ALIVE_GONE : STA alive,X
    JMP cbh_boss_home
.cbh_rows
    LDX #FORM_ROWS - 1
.cbh_row
    LDA bullet_y : CLC : ADC #3 : SEC : SBC row_y,X
    CMP #ALIEN_H + 3 : BCC cbh_rowok
    DEX : BPL cbh_row
    RTS
.cbh_rowok
    STX tmp2
    TXA : ASL A : ASL A : ASL A : SEC : SBC tmp2 : TAX       ; * 7
.cbh_col                            ; the rows space their columns differently: try each
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
    LDX loop_i : JSR slot_pos : LDA slot_y : JSR beam_guard_alien
    LDX loop_i
    JSR draw_slot_expl
    LDX loop_i : LDA #ALIVE_GONE : STA alive,X
    DEC alive_count
    SFX SFX_HIT
    JMP score_form

; A = top row
.beam_guard_alien
    CLC : ADC #ALIEN_H - 1 : TAX
    JMP beam_guard

.bonus_clear
    LDA bonus_on : BEQ bc_done
    LDA bonus_y : JSR beam_guard_alien
    JSR bonus_draw
    LDA #0 : STA bonus_on
.bc_done
    RTS


; MODE 7 shows only &7C00 up, so this is unseen; the OS's own clear after VDU 22 shows
; old memory for a few frames.
.clear_screen
    LDA #HI(SCREEN) : STA ptr0 + 1
    LDA #0 : STA ptr0 : TAY
.cs_page
    STA (ptr0),Y : INY : BNE cs_page
    INC ptr0 + 1 : BPL cs_page
    RTS

.add_score
    SED
    CLC : ADC score_lo : STA score_lo
    LDA score_hi : ADC #0 : STA score_hi
    CLD
    INC hud_dirty
    RTS

.b1_end

ORG &0380                           ; the cassette filing system's workspace
GUARD &03E0
.b2_start

; X = slot
.draw_slot
    JSR slot_pos
    LDY slot_row,X
    LDA row_spr,Y : ORA row_anim,Y
    LDX slot_x : LDY slot_y
    JMP plot_at

.afb_clear                          ; A = guard x - member x: carry clear if its shot passes over
    CLC : ADC #ALIEN_MID + 1        ; the 1-pixel shot, kept a pixel clear each side
    CMP #ALIEN_W + 2
    RTS

.txt_hud
    EQUB 6, 17, GLYPH_COLOUR, 31, 4, 0 : EQUS "0"

; A = top row, X = x: carry clear if the bullet overlaps
.cbh_near
    STA tmp
    LDA bullet_y : CLC : ADC #3 : SEC : SBC tmp
    CMP #ALIEN_H + 3 : BCS cn_ret
    STX tmp
    LDA bullet_x : ADC #1 : SEC : SBC tmp   ; C clear from the BCS
    CMP #ALIEN_W + 1
.cn_ret
    RTS

.b2_end

ORG &0880                           ; the printer buffer
GUARD &08C0
.b3_start

; X = wing + 2 * axis, preserved. Never outpaces the diver's top speed
.um_axis
    TXA : LSR A : TAY
    LDA wing_nox,X : CMP wing_tgt,X : BEQ ax_done
    BMI ax_inc
    LDA lead_d,Y : CMP step_min,Y : BEQ ax_moved
    DEC wing_nox,X
    JMP ax_moved
.ax_inc
    LDA lead_d,Y : CMP step_max,Y : BEQ ax_moved
    INC wing_nox,X
.ax_moved
    LDA wing_nox,X : CMP wing_tgt,X : BEQ ax_done   ; rows stepping by turns move the target every frame
    INC moved                       ; not in place yet
.ax_done
    RTS

.expl_start                        ; at the alien just erased (draw_x, draw_y): A only
    LDA expl_t : BNE xs_ret        ; one at a time
    LDA #EXPL_TIME + 1 : STA expl_t   ; update_expl draws it this frame
    LDA draw_x : CLC : ADC #(ALIEN_W - EXPL_W + 1) DIV 2 : STA expl_x
    LDA draw_y : STA expl_y
.xs_ret
    RTS

.b3_end

ORG &B6                             ; zero page: the filing system's
GUARD &D0
.b4_start

; A = how far the lowest wing is below the diver; X is lost
.group_depth
    LDA #0 : LDX #WINGS - 1
.gd_wing
    LDY wing_on,X : BEQ gd_next
    LDY wing_oy,X : BMI gd_next     ; above the diver: a line in a loop
    CMP wing_oy,X : BCS gd_next
    LDA wing_oy,X
.gd_next
    DEX : BPL gd_wing
    RTS

.b4_end

MACRO MOVE start, finish
    LDA #LO(start) : STA ptr1 : LDA #HI(start) : STA ptr1 + 1
    LDX #HI(finish - start) : LDA #LO(finish - start)
    JSR mv_block
ENDMACRO

; Loader: runs once from the load address, so its set-up takes no room in the game
LOADER = LOAD_ADDR + end - main_start
ORG LOADER
.loader
    LDA #119 : JSR OSBYTE           ; close !BOOT's EXEC file while the DFS workspace is intact
    LDA #LO(loader_end) : STA ptr0 : LDA #HI(loader_end) : STA ptr0 + 1
    MOVE lo_start, lo_end           ; exactly: the ROM workspace table follows at &0DF0
    MOVE hi_start, hi_end
    MOVE b1_start, b1_end
    MOVE b2_start, b2_end
    MOVE b3_start, b3_end
    MOVE b4_start, b4_end
    LDY #0
    LDA #LO(LOAD_ADDR) : STA ptr0 : LDA #HI(LOAD_ADDR) : STA ptr0 + 1
    LDA #LO(main_start) : STA ptr1 : LDA #HI(main_start) : STA ptr1 + 1
    LDX #HI(end - main_start + 255)
.mv_copy                            ; ascending: the destination is always below the source
    LDA (ptr0),Y : STA (ptr1),Y
    INY : BNE mv_copy
    INC ptr0 + 1 : INC ptr1 + 1
    DEX : BNE mv_copy

.build_font
    LDA #0 : STA loop_i
.bf_char
    LDX loop_i : LDA glyph_chars,X : STA font_buf
    LDA #10 : LDX #LO(font_buf) : LDY #HI(font_buf) : JSR OSWORD
    LDA loop_i : ASL A : ASL A : ASL A : TAX
    LDY #0
.bf_row
    LDA font_buf + 1,Y : STA font1,X
    INX : INY : CPY #8 : BNE bf_row
    INC loop_i : LDA loop_i : CMP #GLYPHS : BNE bf_char
    LDA KEYV : STA keyv_os : LDA KEYV + 1 : STA keyv_os + 1
    LDA #&FF : STA pl_last_id       ; no image patched into plot yet
    LDA #0
FOR i, 1, 7, 2                      ; every amplitude is an envelope: OSWORD 7's high bytes 0
    STA sound_blk + i
NEXT
    STA expl_t                     ; no explosion showing
    LDA #&07 : STA bg_colour        ; black (the ULA stores colours inverted)
FOR e, 0, 3                         ; envelopes 1-4: the OS keeps them at &08C0
    LDX #LO(envelopes + 14 * e) : LDY #HI(envelopes + 14 * e) : LDA #8 : JSR OSWORD
NEXT
    LDA #229 : LDX #1 : LDY #0 : JSR OSBYTE    ; ESCAPE is an ordinary key
    LDA #16 : LDX #0 : JSR OSBYTE   ; no ADC channels: its end-of-conversion IRQ (~135us every ~10ms) stops
    LDA USR_ACR : AND #&1F : STA USR_ACR    ; timer 2 counts down once per microsecond, timer 1 one-shot
    LDA #&20 : STA USR_IER                  ; and never interrupts
    SEI
    LDA #LO(ship_split) : STA IRQ2V : LDA #HI(ship_split) : STA IRQ2V + 1
    CLI
    LDA #&C0 : STA USR_IER                  ; timer 1 does
    JMP title
.mv_block                           ; ptr0 -> ptr1: X pages, then A bytes
    STA tmp
    LDY #0
    TXA : BEQ mb_part
.mb_page
    LDA (ptr0),Y : STA (ptr1),Y
    INY : BNE mb_page
    INC ptr0 + 1 : INC ptr1 + 1
    DEX : BNE mb_page
.mb_part
    CPY tmp : BEQ mb_done
    LDA (ptr0),Y : STA (ptr1),Y
    INY : BNE mb_part
.mb_done                            ; ptr0 = the next block
    TYA : CLC : ADC ptr0 : STA ptr0
    BCC mb_ret
    INC ptr0 + 1
.mb_ret
    RTS
.glyph_chars
    EQUS "0123456789WAVE+"
; number, step (cs; +128: no repeat), pitch change per step and steps x3,
; then amplitude: attack, decay, sustain, release rates, attack and decay levels
.envelopes
    EQUB 1, 129, -8, -3, 0, 8, 27, 0, 126, -12, 0, -12, 126, 0       ; fire: a falling zap
    EQUB 2, 1, 0, 0, 0, 0, 0, 0, 126, -3, -1, -6, 126, 80
    EQUB 3, 130, -2, 0, 0, 60, 0, 0, 60, -1, 0, -4, 60, 59           ; dive: a falling whistle
    EQUB 4, &83, 3, -9, 8, 5, 4, 10, 126, -3, 0, -10, 126, 100      ; hit: Arcadians' enemy explosion
.loader_end
; The file image after the loader: the &0900 block, then these, in MOVE's order
IMG_HI = loader_end + lo_end - lo_start
IMG_B1 = IMG_HI + hi_end - hi_start
IMG_B2 = IMG_B1 + b1_end - b1_start
IMG_B3 = IMG_B2 + b2_end - b2_start
IMG_B4 = IMG_B3 + b3_end - b3_start
IMG_END = IMG_B4 + b4_end - b4_start
ASSERT main_start + HI(end - main_start + 255) * 256 <= loader  ; the copy never reaches the loader
ASSERT IMG_END <= &7C00                                         ; the file loads below MODE 7's screen
ASSERT end + IMG_END - loader <= loader                         ; the file image below doesn't overlap it
ASSERT SPR_BONUS * 2 + 1 < dlt_lo - img_lo AND SPR_BONUS = CROSS_OFS + 2   ; spr_h: ALIEN_H, as the capsule
ASSERT img_hi - dlt_lo = 46 AND dlt_hi - img_hi = 28 AND img_entry - dlt_hi = 46 AND dlt_lo - img_lo = 28   ; the hole tables kept every index in place

COPYBLOCK loader, loader_end, end
COPYBLOCK lo_start, lo_end, end + loader_end - loader
COPYBLOCK hi_start, hi_end, end + IMG_HI - loader
COPYBLOCK b1_start, b1_end, end + IMG_B1 - loader
COPYBLOCK b2_start, b2_end, end + IMG_B2 - loader
COPYBLOCK b3_start, b3_end, end + IMG_B3 - loader
COPYBLOCK b4_start, b4_end, end + IMG_B4 - loader
SAVE "GALAXA", main_start, end + IMG_END - loader, loader, LOAD_ADDR
PUTTEXT "!BOOT", "!BOOT", &FFFF
