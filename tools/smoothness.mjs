// Headless smoothness test for Galaxa.
//
// Boots galaxa.ssd in jsbeeb with its beam-accurate video chip, plays a scripted input
// sequence and inspects every displayed frame:
//   - torn or flickering sprites: lit pixels that are not part of a whole sprite
//   - plots that raced the beam: the beam swept the sprite's rows while it was drawn
//   - step size and cadence of the player, each formation alien, the diver, its wingman
//     and the bullets
//   - the boss: it flashes its own colours, dives with two guards as smoothly as any
//     diver, drops the capsule when shot and stays gone until the next wave; it never
//     fires, and each guard fires at most once a dive, never over the boss or the other
//   - the warp between waves: the stars race, then scroll at their usual speeds again
//   - that the aliens flap, the formation moves as one and breathes and the diver loops
//   - that aliens from every row fire bursts, only while swooping near the player, and
//     their bullets move steadily
//   - that each wave dives more often and fires more, and the last few aliens rush
//   - that the stars show where RAM says, scroll and twinkle, and never mark a sprite
//   - the stage bonus: reaching stage N > 1 scores N x 500, ticked in under its banner
//   - the bonus capsule: only the boss drops it, no lower than BONUS_LOW, it falls 1.5px per frame, and catching it
//     gives the double shot, then rapid fire, until a ship is lost, across stages
//     (tools/capsule.mjs: each case, and the 100 points every hit scores)
//   - the WAVE banner, and the rows dropping in from the top 1px per frame
//   - dropped frames: the main loop missing a vsync
//   - that SHIFT+BREAK boots to the title screen, and a hit ship flashes the screen
// Exits non-zero if anything is not smooth.
//
// Usage: node tools/smoothness.mjs [frames] [--wave n] [--png dir] [--dump]
//   --wave n starts the game at wave n: the late waves' pace and frame times
//   JSBEEB_DIR defaults to ~/.local/share/jsbeeb
import fs from "node:fs";
import path from "node:path";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const J = process.env.JSBEEB_DIR ?? path.join(process.env.HOME, ".local/share/jsbeeb");
const FRAMES = Number(process.argv[2] ?? 3000);
const pngIdx = process.argv.indexOf("--png");
const PNG_DIR = pngIdx > 0 ? path.resolve(process.argv[pngIdx + 1]) : null;
const DUMP = process.argv.includes("--dump");
const waveIdx = process.argv.indexOf("--wave");
const START_WAVE = waveIdx > 0 ? Number(process.argv[waveIdx + 1]) : 1;

// ------------------------------------------------------------------ symbols and art
const src = fs.readFileSync(path.join(ROOT, "galaxa.asm"), "utf8");
const zp = {};
for (const m of src.matchAll(/^(\w+)\s*=\s*&([0-9A-F]+)/gm)) zp[m[1]] = parseInt(m[2], 16);
const labels = {};
for (const m of fs.readFileSync(path.join(ROOT, "galaxa.sym"), "utf8").matchAll(/'(\w+)':(\d+)L/g))
  labels[m[1]] = Number(m[2]);
const art = {};
for (const m of src.matchAll(/^ART_(\w+)\s*=\s*(.+)$/gm))
  art[m[1].toLowerCase()] = [...m[2].matchAll(/"([0-9]+)"/g)].map((x) => [...x[1]].map(Number));
// A constant: a number, or a sum or product of other constants (DIV and INT round down)
const num = (name) => {
  const expr = src.match(new RegExp(`^${name}\\s*=\\s*([^;\\n]+)`, "m"))[1];
  const js = expr.replace(/(\w+) DIV (\d+)/g, "Math.floor($1 / $2)").replace(/\bINT\(/g, "Math.floor(").replace(/\b[A-Z][A-Z0-9_]*\b/g, num);
  if (!/^(?:[\d\s+\-*/().]|Math\.floor)*$/.test(js)) throw new Error(`${name}: not plain arithmetic: ${expr}`);
  return Function(`return ${js}`)();
};
const PLAYER_Y = num("PLAYER_Y");
const SPARE_Y = num("SPARE_Y");
const PLAYER_START = num("PLAYER_START");
const ALIEN_W = num("ALIEN_W");
const ALIEN_H = num("ALIEN_H");
const DIVER_TOP = num("DIVER_TOP"), REENTER_Y = num("REENTER_Y");
const BONUS_LOW = num("BONUS_LOW");
const ALIEN_MID = num("ALIEN_MID");
const FORM_ROWS = num("FORM_ROWS");
const FORM_COLS = num("FORM_COLS");
const LEVELS = num("LEVELS");
const RUSH_COUNT = num("RUSH_COUNT");
const RUSH_DELAY = num("RUSH_DELAY");
const FORM_Y = num("FORM_Y");
const ROW_STEP = num("ROW_STEP");
const SPR_BULLET = num("SPR_BULLET");
const BULLETS = num("BULLETS");
const NUM_STARS = num("NUM_STARS");
const ABULLETS = num("ABULLETS");
const ABULLET_SPEED = num("ABULLET_SPEED");
const BULLET_SPEED = num("BULLET_SPEED");
const BURST_GAP = num("BURST_GAP");
const BURST_PAUSE = num("BURST_PAUSE");
const DIVER_SPEED = num("DIVER_SPEED");
const FLAP_PERIOD = num("FLAP_PERIOD");
const BREATH_MAX = num("BREATH_MAX");
const VBREATH_MAX = num("VBREATH_MAX");
const BREATH_STEPS = BREATH_MAX + VBREATH_MAX;
const SHIP_MIN_X = num("SHIP_MIN_X");
const SHIP_MAX_X = num("SHIP_MAX_X");
const BANNER_Y = num("BANNER_Y");
const BANNER_COL = num("BANNER_COL");
const BANNER_TIME = num("BANNER_TIME");
const GLYPH_COLOUR = num("GLYPH_COLOUR");
const DROP_Y = num("DROP_Y");
const WINGS = num("WINGS");
const BOSS_SLOT = num("BOSS_SLOT");
const BOSS_DX = num("BOSS_DX");
const FLANK = num("FLANK");
const INTRO_WARP = num("INTRO_WARP");
const WARP_VMAX = num("WARP_VMAX");
const STAR_TOP = num("STAR_TOP");
// Logical colour -> the physical colours it can show; the pulsing one cycles.
const PULSE_COLOUR = num("FLAG_COLOUR");
const pulse = [num("FLAG_PHYS"), num("FLAG_PHYS") ^ num("FLAG_FLASH")];
const BOSS_COLOUR = num("BOSS_COLOUR");
const bossColours = [num("BOSS_PHYS")];
// The ship's wings: cyan, then from SPLIT_Y (timer 1, perhaps late) the power level's colour.
const WING_COLOUR = num("WING_COLOUR"), SPLIT_Y = num("SPLIT_Y");
const wingColours = [6, 3, 1];
const shows = (logical, phys, y) =>
  logical === PULSE_COLOUR ? pulse.includes(phys) : logical === BOSS_COLOUR ? bossColours.includes(phys) :
  logical === WING_COLOUR && y >= SPLIT_Y ? wingColours.includes(phys) : logical === phys;

// ------------------------------------------------------------------ emulator
const DISC = path.join(ROOT, "galaxa.ssd");
process.chdir(J); // jsbeeb loads its ROMs relative to its own directory
const { TestMachine } = await import(path.join(J, "tests/test-machine.js"));
const { Video } = await import(path.join(J, "src/video.js"));
const utils = await import(path.join(J, "src/utils.js"));
const print = console.log;
console.log = () => {}; // jsbeeb is chatty while booting

const OX = 200, OY = 64; // framebuffer position of MODE 2 pixel (0, 0): 4 wide, 2 high
const fb = new Uint32Array(1024 * 625);
const captured = [];
let capturing = false;
let onFrame = () => {};
const video = new Video(false, fb, () => {
  if (capturing) captured.push({ grid: decode(fb), ram: snapshot() });
  onFrame();
});
const m = new TestMachine("B-DFS1.2", { video });
await m.initialise();
await m.loadDisc(path.relative(J, DISC));
await m.runUntilInput();
// SHIFT+BREAK, as a player boots it: !BOOT runs the game from a still-open EXEC file
m.processor.sysvia.keyDown(utils.keyCodes.SHIFT);
m.processor.reset(false);
await m.runFor(2e6 * 0.5);
m.processor.sysvia.keyUp(utils.keyCodes.SHIFT);
const idle = await untilInput(10);
const prompt = [...Array(13)].map((_, i) => String.fromCharCode(m.readbyte(0x7c00 + 22 * 40 + 14 + i))).join("");
const bootedToTitle = idle && prompt === "PRESS ANY KEY";
// the first new_wave adds 1 to the BCD wave
let startWaveSet = START_WAVE === 1;
m.processor.debugInstruction.add((addr) => {
  if (addr === labels.new_wave && !startWaveSet) m.writebyte(labels.wave, parseInt(String(START_WAVE - 1), 16)), (startWaveSet = true);
  return false;
});
if (idle) await m.type(" ");
console.log = print;

// Like m.runUntilInput, but says whether the OS asked for a key instead of throwing.
async function untilInput(secs) {
  let hit = false;
  const hook = m.processor.debugInstruction.add((addr) => (addr === 0xe581 ? (hit = true) : false));
  await m.runFor(secs * 2e6);
  hook.remove();
  return hit;
}

// The displayed frame as physical colours 0-7, one byte per MODE 2 pixel.
function decode(f) {
  const g = new Uint8Array(160 * 256);
  for (let y = 0; y < 256; y++)
    for (let x = 0; x < 160; x++) {
      const v = f[(OY + 2 * y) * 1024 + OX + 4 * x + 2] & 0xffffff;
      g[y * 160 + x] = (v & 0xff ? 1 : 0) | (v & 0xff00 ? 2 : 0) | (v & 0xff0000 ? 4 : 0);
    }
  return g;
}

function snapshot() {
  const rb = (a) => m.readbyte(a);
  const rowX = [], rowY = [], rowAnim = [], rowBofs = [], alive = [], bullets = [];
  for (let r = 0; r < FORM_ROWS; r++)
    rowX.push(rb(labels.row_x + r)), rowY.push(rb(labels.row_y + r)), rowAnim.push(rb(labels.row_anim + r)), rowBofs.push(rb(labels.row_bofs + r));
  for (let i = 0; i <= BOSS_SLOT; i++) alive.push(rb(labels.alive + i));
  // the diver's wings: wing k at the diver's position plus its offsets
  const sb = (a) => (rb(a) << 24) >> 24;
  const wings = [...Array(WINGS)].map((_, k) => ({
    on: rb(zp.wing_on + k), slot: rb(zp.wing_slot + k), ox: sb(zp.wing_ox + k), oy: sb(zp.wing_oy + k), joining: sb(zp.wing_tgt + k),
  }));
  for (let b = 0; b < BULLETS; b++)
    bullets.push({ on: rb(labels.bullets_on + b), x: rb(labels.bullets_x + b), y: rb(labels.bullets_y + b) });
  const abullets = [];
  for (let b = 0; b < ABULLETS; b++)
    abullets.push({ on: rb(labels.abullets_on + b), x: rb(labels.abullets_x + b), y: rb(labels.abullets_y + b) });
  const stars = [];
  for (let s = 0; s < NUM_STARS; s++)
    stars.push({ x: rb(labels.star_x + s), y: rb(labels.star_y + s), vis: rb(labels.star_vis + s) });
  return {
    frame: rb(zp.frame), player_x: rb(zp.player_x),
    bullets, abullets,
    diver_state: rb(zp.diver_state), diver_x: rb(zp.diver_x), diver_y: rb(zp.diver_y),
    diver_t: rb(labels.diver_t), diver_lap: rb(labels.diver_lap),
    diver_slot: rb(zp.diver_slot), wings, boss_x: rb(zp.boss_x), boss_y: rb(zp.boss_y),
    lead_gone: rb(zp.lead_gone), intro: rb(labels.intro), level: rb(labels.level),
    dive_delay: rb(labels.dive_delays + rb(labels.level)), // the last level's shrinks each wave past it
    alive_count: rb(zp.alive_count), diver_vx: rb(labels.diver_vx),
    rowX, rowY, rowAnim, rowBofs, alive, lives: rb(labels.lives), stars,
    ships_shown: rb(labels.ships_shown), player_state: rb(labels.player_state), player_row: rb(labels.player_row),
    score: bcd(rb(labels.score_hi)) * 1000 + bcd(rb(labels.score_lo)) * 10, wave: bcd(rb(labels.wave)),
    power: rb(zp.power), bonus_on: rb(zp.bonus_on), bonus_x: rb(zp.bonus_x), bonus_y: rb(zp.bonus_y),
    expl_t: rb(zp.expl_t), expl_x: rb(zp.expl_x), expl_y: rb(labels.expl_y),
  };
}
// The diver's wings in flight, at their screen positions.
const wingsOf = (q) => (q?.diver_state ? q.wings.map((w, k) => ({ ...w, k, x: q.diver_x + w.ox, y: q.diver_y + w.oy })).filter((w) => w.on) : []);

// ------------------------------------------------------------------ scripted input
const KEYS = { Z: utils.keyCodes.Z, X: utils.keyCodes.X, FIRE: utils.keyCodes.ENTER };
// Aims: under a falling capsule (stepping aside from a guard coming down at it), else a
// low diver, else the nearest alien of the lowest row still holding one, else the boss
// at home; fires whenever it can.
function keysFor(i) {
  const held = new Set();
  const rb = (a) => m.readbyte(a);
  const sb = (a) => (rb(a) << 24) >> 24;
  let target = null;
  if (rb(zp.bonus_on)) {
    target = rb(zp.bonus_x);
    for (let k = 0; k < WINGS && rb(zp.diver_state); k++) {
      const wx = rb(zp.diver_x) + sb(zp.wing_ox + k), wy = rb(zp.diver_y) + sb(zp.wing_oy + k);
      if (rb(zp.wing_on + k) && wy > PLAYER_Y - 80 && wy < PLAYER_Y + 8 && Math.abs(wx - target) < 14)
        target = Math.min(Math.max(wx + (target >= wx ? 14 : -14), SHIP_MIN_X), SHIP_MAX_X);
    }
  }
  else if (rb(zp.diver_state) === 1 && rb(zp.diver_y) > 96) target = rb(zp.diver_x) + ALIEN_MID - 3;
  else
    for (let r = FORM_ROWS - 1; r >= 0 && target == null; r--)
      for (let c = 0; c < FORM_COLS; c++) {
        if (rb(labels.alive + r * FORM_COLS + c) !== 1) continue;
        const x = rb(labels.row_x + r) + slotPx[r * FORM_COLS + c] + breath[rb(labels.row_bofs + r) + c] + ALIEN_MID - 3;
        if (target == null || Math.abs(x - rb(zp.player_x)) < Math.abs(target - rb(zp.player_x))) target = x;
      }
  if (target == null && rb(labels.alive + BOSS_SLOT) === 1) target = rb(zp.boss_x) + ALIEN_MID - 3;
  const d = target == null ? 0 : target - rb(zp.player_x);
  if (d) held.add(d > 0 ? "X" : "Z");
  if (i % 4 < 2) held.add("FIRE");
  return held;
}
let inputFrame = 0;
let rapidPoke = null;
let down = new Set();
onFrame = () => {
  if (!capturing) return;
  // soak test: keep the scripted player alive so every frame is gameplay
  if (m.readbyte(labels.lives) < 2) m.writebyte(labels.lives, 3);
  // and once, well into the run and in play, upgrade a caught double shot to rapid fire so its
  // third shot is exercised; the next snapshot is the first that can show it
  if (rapidPoke == null && inputFrame > 2000 && m.readbyte(zp.power) === 1 && !m.readbyte(labels.player_state) && !m.readbyte(labels.intro))
    m.writebyte(zp.power, 2), (rapidPoke = captured.length);
  const want = keysFor(inputFrame++);
  for (const k of down) if (!want.has(k)) m.processor.sysvia.keyUp(KEYS[k]);
  for (const k of want) if (!down.has(k)) m.processor.sysvia.keyDown(KEYS[k]);
  down = want;
};

// ------------------------------------------------------------------ CPU-side probes
// Busy time per frame: User VIA timer 2 restarts at vsync and counts microseconds.
// Races: the beam line at the start and end of every plot; if the beam swept the
// sprite's rows meanwhile, the screen showed it half drawn.
const busy = [];
const races = [];
const burstSteps = [];
let plotEntry = null;
const elapsedUs = () => 0xffff - (m.readbyte(0xfe68) | (m.readbyte(0xfe69) << 8));
function beamLine() {
  const line = video.vertCounter * 8 + video.scanlineCounter;
  return line >= 256 ? line - 312 : line; // top border and vblank count as above the screen
}
m.processor.debugInstruction.add((addr) => {
  if (!capturing) return false;
  if (addr === labels.main_loop) busy.push(elapsedUs());
  else if (addr === labels.af_shot) burstSteps.push({ frame: captured.length, level: m.readbyte(labels.level), rush: m.readbyte(zp.alive_count) <= RUSH_COUNT });
  else if (addr === labels.plot_image || addr === labels.plot_delta)
    plotEntry = { line: beamLine(), y: m.readbyte(zp.draw_y), id: m.readbyte(zp.draw_id) };
  else if (addr === labels.pl_done && plotEntry) {
    const exit = beamLine();
    const h = m.readbyte(labels.spr_h + plotEntry.id);
    if (plotEntry.line <= plotEntry.y + h - 1 && exit >= plotEntry.y)
      races.push({ frame: captured.length, ...plotEntry, exit });
    plotEntry = null;
  }
  return false;
});

await m.runFor(1e6);
while (m.readbyte(labels.intro) !== 1) await m.runFor(20000); // from the first WAVE banner
const signedTable = (base) => [...Array((BREATH_STEPS + 1) * FORM_COLS)].map((_, k) => (m.readbyte(base + k) << 24) >> 24);
const breath = signedTable(labels.breath);
const vbreath = signedTable(labels.vbreath);
const slotPx = [...Array(FORM_ROWS * FORM_COLS)].map((_, k) => m.readbyte(labels.slot_px + k));
// each row's outer columns at the start of a wave
const rowEnds = [...Array(FORM_ROWS)].map((_, r) => {
  const cols = [...Array(FORM_COLS).keys()].filter((c) => m.readbyte(labels.slot_start + r * FORM_COLS + c));
  return [cols[0], cols.at(-1)];
});
const levelTable = (name) => [...Array(LEVELS)].map((_, k) => m.readbyte(labels[name] + k));
const burstMins = levelTable("burst_mins");
const afireTops = levelTable("afire_tops"), afireRanges = levelTable("afire_ranges");
// Start on the same game frame whatever the load time: the scripted input then meets the same game,
// so busy_us compares builds of different sizes like for like (a 2-frame shift plays a different game).
const CAPTURE_FRAME = 40; // still under the first banner, whichever build is loading
if (m.readbyte(zp.frame) > CAPTURE_FRAME) print(`capture starts late: frame ${m.readbyte(zp.frame)}`);
while (m.readbyte(zp.frame) !== CAPTURE_FRAME) await m.runFor(500);
capturing = true;
while (captured.length < FRAMES) await m.runFor(20000);

// ------------------------------------------------------------------ analysis
const templates = ["player", "bullet", "abullet", "bonus", "expl", "flagship", "flagship_b", "escort", "escort_b", "drone", "drone_b", "boss"].map((name) => ({
  name,
  rows: art[name],
  w: art[name][0].length,
}));
const isAlien = (s) => /^(flagship|escort|drone|boss)/.test(s.name);
// Where formation slot i sits: its row's sway, its place in the row and its column's breathing offset. The
// boss: the middle of row 0, where breathing moves nothing, a row step up and further as it breathes.
const slotX = (ram, i) => {
  if (i === BOSS_SLOT) return ram.rowX[0] + BOSS_DX;
  const r = Math.floor(i / FORM_COLS), c = i % FORM_COLS;
  return ram.rowX[r] + slotPx[i] + breath[ram.rowBofs[r] + c];
};
const slotY = (ram, i) => (i === BOSS_SLOT ? ram.rowY[0] + vbreath[ram.rowBofs[0] + FORM_ROWS] : ram.rowY[Math.floor(i / FORM_COLS)]);
// A sprite's blank pixels may show a star: white, where RAM puts a shown star.
let starAt = new Uint8Array(160 * 256);
const pixelOk = (logical, g, k) => shows(logical, g[k], Math.floor(k / 160)) || (logical === 0 && g[k] === 7 && starAt[k]);
function matchAt(g, t, x, y) {
  for (let r = 0; r < t.rows.length; r++)
    for (let c = 0; c < t.w; c++) if (!pixelOk(t.rows[r][c], g, (y + r) * 160 + x + c)) return false;
  return true;
}
// Every exact copy of a sprite on screen (the 8-pixel-wide box must match, blanks too).
function findSprites(g) {
  const found = [];
  for (const t of templates)
    for (let y = 8; y <= 256 - t.rows.length; y++)
      for (let x = 0; x <= 160 - t.w; x++) {
        const k = Math.min(4, t.w - 1); // quick reject on one pixel of the top row
        if (!pixelOk(t.rows[0][k], g, y * 160 + x + k)) continue;
        if (matchAt(g, t, x, y)) found.push({ name: t.name, x, y, w: t.w, h: t.rows.length });
      }
  return found;
}

// Boxes where two objects overlap: EOR mixes them, so the pixels there match nothing.
// Objects drawn behind the beam appear a frame later, so either frame's position counts,
// though never an object against its own other position.
function overlapZones(...rams) {
  const boxes = [];
  for (const ram of rams) {
    boxes.push({ id: "player", x: ram.player_x, y: ram.player_row, h: 8 });
    for (let k = 0; k < ram.ships_shown; k++) boxes.push({ id: `spare${k}`, x: 10 * k, y: SPARE_Y, h: 8 });
    ram.bullets.forEach((b, k) => b.on && boxes.push({ id: `b${k}`, x: b.x, y: b.y, h: 4 }));
    ram.abullets.forEach((b, k) => b.on && boxes.push({ id: `ab${k}`, x: b.x, y: b.y, h: 4 }));
    if (ram.diver_state) boxes.push({ id: "diver", x: ram.diver_x, y: ram.diver_y, h: ALIEN_H });
    wingsOf(ram).forEach((w) => boxes.push({ id: `w${w.k}`, x: w.x, y: w.y, h: ALIEN_H }));
    if (ram.bonus_on) boxes.push({ id: "bonus", x: ram.bonus_x, y: ram.bonus_y, h: ALIEN_H });
    if (ram.expl_t) boxes.push({ id: "expl", x: ram.expl_x & 0xfe, y: ram.expl_y, h: ALIEN_H }); // odd x: drawn a pixel left
    ram.alive.forEach((a, i) => {
      if (a === 1) boxes.push({ id: `s${i}`, x: slotX(ram, i), y: slotY(ram, i), h: ALIEN_H });
    });
  }
  // a diver wrapping round is drawn at REENTER_Y, a position neither frame holds
  const [ram, prev] = rams;
  if (prev && ram.diver_state && prev.diver_y > ram.diver_y + 100) {
    const dy = REENTER_Y - ram.diver_y;
    boxes.push({ id: "diver", x: ram.diver_x, y: REENTER_Y, h: ALIEN_H });
    wingsOf(ram).forEach((w) => boxes.push({ id: `w${w.k}`, x: w.x, y: w.y + dy, h: ALIEN_H }));
  }
  const zones = [];
  for (let a = 0; a < boxes.length; a++)
    for (let b = a + 1; b < boxes.length; b++) {
      const A = boxes[a], B = boxes[b];
      if (A.id !== B.id && Math.abs(A.x - B.x) < ALIEN_W + 2 && A.y < B.y + B.h + 2 && B.y < A.y + A.h + 2)
        zones.push({
          x0: Math.min(A.x, B.x) - 2, x1: Math.max(A.x, B.x) + ALIEN_W + 2,
          y0: Math.min(A.y, B.y) - 2, y1: Math.max(A.y + A.h, B.y + B.h) + 2,
        });
    }
  return zones;
}

const defects = [];
let sparesRight = 0;
// the death sequence: hits, blink frames shown and hidden, slides and where they end
const death = { hits: 0, blinkShown: 0, blinkHidden: 0, slides: 0, slideMissing: 0, arrivals: [], hitOutOfPlay: 0, shotOutOfPlay: 0 };
const sparesWrong = [];
const slideMissingAt = [];
const tracks = {
  player: [], slots: [...Array(BOSS_SLOT + 1)].map(() => []), diver: [], wings: [...Array(WINGS)].map(() => []), boss: [], bossDown: [], guards: [...Array(WINGS)].map(() => []),
  bullets: [...Array(BULLETS)].map(() => []), abullets: [...Array(ABULLETS)].map(() => []), bonus: [],
};
// per drop, the game's count of swooping aliens shot before the one that dropped it;
// miscounts: frames its count moved other than by the swooping aliens shot then
function bcd(b) { return (b >> 4) * 10 + (b & 15); }
const stageBonus = { paid: [], wrong: [] };
let introScore = null;
const turnSteps = { calm: {}, rush: {} };
const bonusEv = { otherDrops: 0, catches: 0, doubleShots: 0, secondWithoutPower: 0, lostWithoutHit: 0, stageResets: 0, keptIntoStage: 0 };
const rapidEv = { poked: 0, capsuleGrants: 0, wrongGrants: 0, stepDowns: 0, keptIntoStage: 0, thirdShots: 0, thirdWithoutRapid: [] };
const spawns = [];
const idles = [];
let idleStart = null, rushStart = null, idlePaused = false;
const farBursts = [];
const shooterRows = new Set();
let strayShots = 0;
const LAP_ROW = num("LAP_ROW"), LOOP_LEN = num("LOOP_LEN"), LOOP_R = num("LOOP_R"), DIVER_DIVE = num("DIVER_DIVE"), DIVER_RETURN = num("DIVER_RETURN");
const TRAIL = num("TRAIL"), LAP_Y = num("LAP_Y"), DIVER_BOTTOM = num("DIVER_BOTTOM");
const introShots = { fired: 0, hits: 0, whileDropping: 0 };
const lineEv = { lines: 0, samples: 0, off: [], openAtWrap: [], lostInAir: [], fullRows: 0, short: [] };
const lapEv = { lower: 0, upper: 0, finished: 0, wrongKind: [], bad: [] };
let lapRun = null;
let dropped = 0;
const droppedAt = [];
let bannerFrames = 0;
const drops = [...Array(BOSS_SLOT + 1)].map(() => []);
// the boss: its flashing colours seen, its dives with both guards, its kills and drops
const bossEv = { colours: new Set(), pulseSeen: new Set(), dives: 0, guardedFrames: 0, kills: 0, drops: 0, killsUndropped: 0, backAfterKill: 0, dropYs: [],
  shots: 0, guardShots: {}, overShots: [] };
// enemy bullets fired in a boss dive: the guard that fired each (or -1), checked against
// the boss and the other guard while they fly (a shot leaves its own guard over a few frames)
const guardShotLive = [];
let bossDead = false;
// star steps per frame: in the warp, and in the frames after it
const warpSteps = {}, starSteps = {};
let warpFrames = 0;
let waves = 0;
let starsMissing = 0, starsMoved = 0, starsHidden = 0;
const starsMissingAt = [];
const frameNames = new Set();
let flashFrames = 0;
const blank = new Uint8Array(160 * 256);
for (let i = 0; i < captured.length; i++) {
  let { grid, ram } = captured[i];
  // a hit ship flashes the background: no sprite can be told from it then
  const flash = grid.subarray(128 * 160, 129 * 160).filter(Boolean).length > 120;
  if (flash) { flashFrames++; grid = blank; }
  const prev = captured[i - 1]?.ram;
  if (prev && ((ram.frame - prev.frame) & 0xff) !== 1) dropped++, droppedAt.push({ frame: i, intro: ram.intro, diver: ram.diver_state, player: ram.player_state });
  // a new wave redraws the formation at its start position: not a step
  const newWave = prev && ram.alive.filter(Boolean).length > prev.alive.filter(Boolean).length;
  if (newWave) waves++;
  // a lower row's dive opens with one full, round loop, back where it left; the rest keep the half loop
  if (prev) {
    const diving = ram.diver_state === DIVER_DIVE, wasDiving = prev.diver_state === DIVER_DIVE;
    if (diving && !wasDiving) {
      const slot = ram.diver_slot, row = slot === BOSS_SLOT ? 0 : Math.floor(slot / FORM_COLS);
      lapRun = { row, frame: i, x0: slot === BOSS_SLOT ? null : slotX(prev, slot), y0: prev.rowY[row], minY: 255, maxY: 0, done: false };
      if (row >= LAP_ROW) lapEv.lower++; else lapEv.upper++;
      if ((ram.diver_lap > 0) !== (row >= LAP_ROW)) lapEv.wrongKind.push([i, row, ram.diver_lap]);
    }
    // once back in view at the top, none of it is above the screen
    if (prev.diver_state === DIVER_RETURN && ram.diver_state === DIVER_RETURN && ram.diver_y < 128 && wingsOf(ram).some((w) => w.oy < 0)) lineEv.openAtWrap.push([i, ram.wings]);
    // a line leaves one at a time, each only at the bottom
    wingsOf(prev).forEach((w) => {
      if (!ram.wings[w.k].on && ram.alive[w.slot] === 2 && w.y + DIVER_SPEED < DIVER_BOTTOM) lineEv.lostInAir.push([i, w.k, w.y]);
    });
    if (!diving) lapRun = null;
    // its neighbours fly the lead's own path, TRAIL frames per place behind, all the way down
    if (lapRun && lapRun.row >= LAP_ROW) {
      const age = i - lapRun.frame;
      if (ram.wings[0].on && ram.wings[1].on) lapRun.line = true;
      for (const w of wingsOf(ram)) {
        const back = (w.k + 1) * TRAIL;
        if (age < back || w.joining || prev.wings[w.k].joining) continue;
        const was = captured[i - back].ram;
        lineEv.samples++;
        if (w.x !== was.diver_x || w.y !== was.diver_y) lineEv.off.push([i, w.k, w.x, w.y, was.diver_x, was.diver_y]);
      }
    }
    if (lapRun && lapRun.row >= LAP_ROW && !lapRun.done) {
      if (ram.diver_lap < 3) lapRun.minY = Math.min(lapRun.minY, ram.diver_y), lapRun.maxY = Math.max(lapRun.maxY, ram.diver_y);
      if (ram.diver_lap === 1 && ram.diver_t === LOOP_LEN) {
        if (lapRun.line) lineEv.lines++;
        lapRun.done = true;
        lapEv.finished++;
        const round = lapRun.minY === LAP_Y - 4 * LOOP_R && lapRun.maxY === LAP_Y + 4 * LOOP_R;
        const pushedByWing = ram.wings.some((w) => w.on);
        const back = ram.diver_y === LAP_Y && (pushedByWing || ram.diver_x === lapRun.x0);
        if (!round || !back) lapEv.bad.push({ frame: lapRun.frame, row: lapRun.row, y0: lapRun.y0, x0: lapRun.x0, minY: lapRun.minY, maxY: lapRun.maxY, x: ram.diver_x, y: ram.diver_y });
      }
    }
  }
  if (prev && !prev.diver_state && ram.diver_state === 1 && ram.diver_slot < BOSS_SLOT && Math.floor(ram.diver_slot / FORM_COLS) >= LAP_ROW) {
    const first = Math.floor(ram.diver_slot / FORM_COLS) * FORM_COLS;
    let home = 0;
    for (let k = first; k < first + FORM_COLS; k++) if (prev.alive[k] === 1 && ram.alive[k]) home++;
    if (home >= 3) {
      lineEv.fullRows++;
      if (!(ram.wings[0].on && ram.wings[1].on)) lineEv.short.push([i, ram.diver_slot, home]);
    }
  }
  if (prev?.intro && ram.intro) {
    if (ram.bullets.some((b, k) => b.on && !prev.bullets[k].on)) {
      introShots.fired++;
      if (prev.intro === 2) introShots.whileDropping++;
    }
    if (ram.alive_count < prev.alive_count) introShots.hits++;
  }
  // the dive timer runs while no diver flies: from the end of the intro or of the last dive
  if (prev && ((prev.intro && !ram.intro) || (prev.diver_state && !ram.diver_state))) idleStart = rushStart = null;
  if (!ram.intro && !ram.diver_state) {
    idleStart ??= i;
    if (ram.alive_count <= RUSH_COUNT) rushStart ??= i;
    // the timer stops while the ship is out of play
    if (ram.player_state) idlePaused = true;
  }
  if (prev && !prev.diver_state && ram.diver_state === 1 && idleStart != null) {
    if (!idlePaused) idles.push({ level: ram.level, delay: ram.dive_delay, gap: i - idleStart, rush: rushStart == null ? null : i - rushStart });
    idleStart = rushStart = null;
  }
  if (idleStart == null) idlePaused = false;
  // the snapshot is taken at vsync, either side of the stars' move: allow both positions
  starAt = new Uint8Array(160 * 256);
  for (const q of [ram, prev]) for (const s of q?.stars ?? []) if (s.vis) starAt[s.y * 160 + s.x] = 1;
  const sprites = findSprites(grid);
  // two stars on one pixel EOR each other out as they pass: a blink, not a fault
  const shared = (q, k) => [ram, prev].some((o) => o?.stars.some((t, j) => j !== k && t.vis && t.x === q.x && t.y === q.y));
  ram.stars.forEach((s, k) => {
    const p = prev?.stars[k];
    if (p && p.y !== s.y) starsMoved++;
    if (!s.vis) { starsHidden++; return; }
    const lit = [s, p].some((q) => q?.vis && (grid[q.y * 160 + q.x] !== 0 || shared(q, k)));
    // re-entry's redraws come first: a star back at the top can move just behind the beam, a frame late
    if (!lit && prev && !flash && !(ram.diver_state && prev.diver_y > ram.diver_y + 100)) starsMissing++, starsMissingAt.push({ frame: i, intro: ram.intro, x: s.x, y: s.y }); // the first frame has no last position to allow for
  });

  const covered = new Uint8Array(160 * 256);
  for (const s of sprites)
    for (let r = 0; r < s.h; r++) for (let c = 0; c < s.w; c++) covered[(s.y + r) * 160 + s.x + c] = 1;
  const zones = prev ? overlapZones(ram, prev) : overlapZones(ram);
  let garbage = 0, where = null;
  for (let y = 8; y < 256; y++)
    for (let x = 0; x < 160; x++) {
      const k = y * 160 + x;
      if (!grid[k] || covered[k] || (grid[k] === 7 && starAt[k])) continue;
      if (zones.some((z) => x >= z.x0 && x < z.x1 && y >= z.y0 && y < z.y1)) continue;
      // the banner, and a bullet part way across its edge, which EOR leaves matching nothing
      if ([ram, prev].some((q) => q?.intro === 1) && y >= BANNER_Y - 4 && y < BANNER_Y + 12) continue;
      garbage++;
      where ??= { x, y };
    }
  if (garbage) defects.push({ frame: i, garbage, where });
  if (ram.intro === 1) {
    let lit = 0;
    for (let y = BANNER_Y; y < BANNER_Y + 8; y++)
      for (let x = BANNER_COL * 8; x < BANNER_COL * 8 + 48; x++) if (grid[y * 160 + x] === GLYPH_COLOUR && !starAt[y * 160 + x]) lit++;
    if (lit > 40) bannerFrames++;
  }

  tracks.player.push(sprites.find((s) => s.name === "player" && s.y === PLAYER_Y)?.x ?? null);

  if (prev) {
    const seen = (q) => sprites.some((s) => s.name === "player" && s.x === q.player_x && s.y === q.player_row);
    // an enemy bullet, the diver or its wingman over the ship: EOR mixes them
    const nearShot = (q) => q.abullets.some((b) => b.on && Math.abs(b.x - q.player_x - 4) < 6 && Math.abs(b.y - q.player_row) < 10) ||
      (q.bonus_on && Math.abs(q.bonus_y - q.player_row) < ALIEN_H + 2 && Math.abs(q.bonus_x - q.player_x) < 9) ||
      [...(q.diver_state && !q.lead_gone ? [{ x: q.diver_x, y: q.diver_y }] : []), ...wingsOf(q)]
        .some((a) => Math.abs(a.y - q.player_row) < ALIEN_H + 2 && a.x < q.player_x + 8 && a.x + ALIEN_W > q.player_x);
    if (!prev.player_state && ram.player_state === 1) death.hits++;
    if (prev.player_state === 1 && ram.player_state === 1 && !nearShot(ram) && !nearShot(prev))
      seen(ram) ? death.blinkShown++ : death.blinkHidden++;
    if (prev.player_state === 1 && ram.player_state === 2) death.slides++;
    if (ram.player_state === 2 && !seen(ram) && !nearShot(ram) && !nearShot(prev))
      death.slideMissing++, slideMissingAt.push({ frame: i, x: ram.player_x, y: ram.player_row, dx: ram.diver_x, dy: ram.diver_y, ds: ram.diver_state });
    if (prev.player_state === 2 && !ram.player_state) death.arrivals.push([ram.player_x, ram.player_row]);
    if (prev.player_state && ram.lives < prev.lives) death.hitOutOfPlay++;
    if (prev.player_state && ram.bullets.some((b, k) => b.on && !prev.bullets[k].on)) death.shotOutOfPlay++;

    // the wave's last alien refills the formation before the next snapshot: its kill is unseen
    // the boss counts for none: shot, it drops its own capsule
    const bossShot = !newWave && prev.alive[BOSS_SLOT] && !ram.alive[BOSS_SLOT];
    // steering: the dive's speed toward the player changes 1 a frame, 2 in the rush (0: a new dive or the edge)
    if (prev.diver_state === 1 && ram.diver_state === 1 && ram.diver_vx) {
      const d = Math.abs(((ram.diver_vx - prev.diver_vx + 128) & 255) - 128), h = turnSteps[ram.alive_count <= RUSH_COUNT ? "rush" : "calm"];
      h[d] = (h[d] ?? 0) + 1;
    }
    if (!prev.bonus_on && ram.bonus_on && !bossShot) bonusEv.otherDrops++;
    if (!prev.intro && ram.intro) introScore = ram.score;
    if (prev.intro && !ram.intro && introScore != null) {
      const got = ram.score - introScore, want = ram.wave > 1 ? ram.wave * 500 : 0;
      (got === want ? stageBonus.paid : stageBonus.wrong).push([ram.wave, got]);
    }
    if (!prev.power && ram.power) bonusEv.catches++;
    if (prev.power && !ram.power && ram.player_state !== 1) ram.intro ? bonusEv.stageResets++ : bonusEv.lostWithoutHit++;
    if (prev.intro && !ram.intro && ram.power) bonusEv.keptIntoStage++;
    // fired this frame: the power it fired with is now's (it may have just been granted),
    // unless the ship was hit this frame, after the shot
    const firedPower = ram.player_state === 1 && prev.player_state !== 1 ? prev.power : ram.power;
    if (ram.bullets[1].on && !prev.bullets[1].on) firedPower ? bonusEv.doubleShots++ : bonusEv.secondWithoutPower++;
    if (ram.bullets[2].on && !prev.bullets[2].on) firedPower >= 2 ? rapidEv.thirdShots++ : rapidEv.thirdWithoutRapid.push([i, prev.power, ram.power]);
    // rapid fire: a capsule caught with the double shot, kept until a ship is lost
    if (prev.power < 2 && ram.power === 2) {
      if (rapidPoke != null && i >= rapidPoke && prev.power === 1 && !rapidEv.poked) rapidEv.poked++;
      else if (prev.bonus_on && !ram.bonus_on && prev.power === 1) rapidEv.capsuleGrants++;
      else rapidEv.wrongGrants++;
    }
    if (prev.power === 2 && ram.power === 1) rapidEv.stepDowns++;
    if (prev.intro && !ram.intro && ram.power === 2) rapidEv.keptIntoStage++;
  }
  // falling: bonus_on 1 and 3 by turns (2 is its first frame)
  const bonus = ram.bonus_on & 1 && prev?.bonus_on & 1
    ? sprites.find((s) => s.name === "bonus" && s.x === ram.bonus_x && s.y <= ram.bonus_y && s.y >= prev.bonus_y)
    : null;
  tracks.bonus.push(bonus ? bonus.y : null);

  // spare ships in the bottom left corner
  let spares = 0;
  while (matchAt(grid, templates[0], 10 * spares, SPARE_Y)) spares++;
  if (prev) {
    // a falling enemy bullet EORs over them
    const crossed = [prev, ram].some((q) => q.abullets.some((b) => b.on && b.y > SPARE_Y - 4 && b.x < 10 * q.ships_shown));
    const settled = !crossed && [prev, ram].every((q) => q.ships_shown === q.lives - 1 && q.lives === ram.lives);
    if (settled && !flash) (spares === ram.lives - 1 ? sparesRight++ : sparesWrong.push({ frame: i, spares, lives: ram.lives }));
  }

  const isDiver = (s) =>
    [ram, prev].some((q) => [...(q?.diver_state ? [{ x: q.diver_x, y: q.diver_y }] : []), ...wingsOf(q)]
      .some((a) => Math.abs(s.y - a.y) <= 3 && Math.abs(s.x - a.x) <= 2));
  // each alien in the formation: the sprite within a pixel of where RAM puts it
  tracks.slots.forEach((t, i) => {
    const near = (s) =>
      isAlien(s) && !isDiver(s) &&
      [ram, prev].some((q) => q && Math.abs(s.x - slotX(q, i)) <= 1 && Math.abs(s.y - slotY(q, i)) <= 1);
    const s = ram.alive[i] === 1 && !newWave ? sprites.find(near) : null;
    const intro = ram.intro || prev?.intro;
    t.push(s && !intro ? { x: s.x, y: s.y } : null);
    if (ram.intro === 2 && ram.alive[i] && ram.rowY[Math.floor(i / FORM_COLS)]) drops[i].push(s ? s.y : null);
  });

  // a line re-enters over its slot: a jump sideways, off screen
  const reentered = ram.diver_lap && prev && prev.diver_y > ram.diver_y + 100;
  const diver = ram.diver_state && !ram.lead_gone && !prev?.lead_gone && !reentered
    ? sprites.find((s) => isAlien(s) && Math.abs(s.x - ram.diver_x) <= 2 && Math.abs(s.y - ram.diver_y) <= 3)
    : null;
  tracks.diver.push(diver ? { x: diver.x, y: diver.y } : null);
  const wingSeen = wingsOf(ram).map((w) => (prev?.wings[w.k].on && !reentered
    ? sprites.find((s) => isAlien(s) && s.name !== "boss" && Math.abs(s.x - w.x) <= 2 && Math.abs(s.y - w.y) <= 3)
    : null));
  tracks.wings.forEach((t, k) => {
    const w = wingsOf(ram).findIndex((o) => o.k === k);
    t.push(w >= 0 && wingSeen[w] ? { x: wingSeen[w].x, y: wingSeen[w].y } : null);
  });
  // the boss diving: the lead is the boss sprite, flanked by both guards
  const bossDiving = ram.diver_state && ram.diver_slot === BOSS_SLOT;
  if (bossDiving && !prev?.diver_state) bossEv.dives++;
  tracks.boss.push(bossDiving && diver?.name === "boss" ? { x: diver.x, y: diver.y } : null);
  tracks.bossDown.push(bossDiving && ram.diver_state === 1 ? tracks.boss.at(-1) : null);
  // it and its guards on the way down; going home they slow to their slots' pace. A guard
  // closing in on the boss as fast as the boss drifts its way holds still, yet still moves
  tracks.guards.forEach((t, k) => {
    const at = bossDiving && ram.diver_state === 1 ? tracks.wings[k].at(-1) : null;
    t.push(at && { ...at, off: `${ram.wings[k].ox},${ram.wings[k].oy}` });
  });
  if (bossDiving && diver?.name === "boss" && wingSeen.length === WINGS && wingSeen.every(Boolean)) bossEv.guardedFrames++;
  // its flashing parts, logical BOSS_COLOUR: the physical colours they show
  for (const s of sprites.filter((s) => s.name === "boss"))
    art.boss.forEach((row, r) => row.forEach((l, c) => l === BOSS_COLOUR && bossEv.colours.add(grid[(s.y + r) * 160 + s.x + c])));
  for (const s of sprites.filter((s) => s.name.startsWith("flagship")))
    art.flagship.forEach((row, r) => row.forEach((l, c) => l === PULSE_COLOUR && bossEv.pulseSeen.add(grid[(s.y + r) * 160 + s.x + c])));
  // shot: gone (0) from home or a dive; it drops the capsule unless one falls; it stays
  // gone until the wave refills
  if (prev && !newWave && prev.alive[BOSS_SLOT] && !ram.alive[BOSS_SLOT]) {
    bossEv.kills++, bossDead = true;
    if (!prev.bonus_on && ram.bonus_on) bossEv.drops++, bossEv.dropYs.push(ram.bonus_y);
    else if (!prev.bonus_on) bossEv.killsUndropped++;
  }
  if (newWave) bossDead = false;
  else if (bossDead && ram.alive[BOSS_SLOT]) bossEv.backAfterKill++;
  // the stars' steps this frame, wrapping from the bottom to STAR_TOP
  if (prev) {
    const into = ram.intro === INTRO_WARP ? warpSteps : prev.intro === INTRO_WARP || ram.intro ? starSteps : null;
    if (ram.intro === INTRO_WARP) warpFrames++;
    if (into) ram.stars.forEach((s, k) => {
      const p = prev.stars[k], d = s.y >= p.y ? s.y - p.y : 256 - p.y + s.y - STAR_TOP;
      into[d] = (into[d] ?? 0) + 1;
    });
  }
  for (const a of sprites) if (isAlien(a)) frameNames.add(a.name);
  ram.bullets.forEach((b, k) => {
    const near = (s) => s.name === "bullet" && Math.abs(s.x - b.x) <= 1 && Math.abs(s.y - b.y) <= 8;
    // through the falling capsule, EOR mixes them: no step is measured
    const inCapsule = [ram, prev].some((q) => q?.bonus_on && Math.abs(q.bonus_x + 4 - b.x) < 8 && Math.abs(q.bonus_y - b.y) < ALIEN_H + 8);
    // and through an enemy bullet
    const crossing = [ram, prev].some((q) => q?.abullets.some((a) => a.on && Math.abs(a.x - b.x) <= 2 && Math.abs(a.y - b.y) < 8 + BULLET_SPEED));
    // and through the banner and the aliens dropping in
    const inIntro = ram.intro || prev?.intro;
    const bullet = b.on && !inCapsule && !crossing && !inIntro ? sprites.find(near) : null;
    tracks.bullets[k].push(bullet ? bullet.y : null);
  });
  ram.abullets.forEach((b, k) => {
    if (b.on && !prev?.abullets[k].on) {
      // a pair fires together: one burst step
      if (spawns.at(-1) !== i) spawns.push(i);
      // aimed from the diver or its wingman as they were when the frame began
      const from = prev?.diver_state === 1 ? prev : null;
      const lead = from && !from.lead_gone && Math.abs(b.x - (from.diver_x + ALIEN_MID)) <= 2;
      const wingShot = from && wingsOf(from).find((w) => Math.abs(b.x - (w.x + ALIEN_MID)) <= 2);
      if (lead) shooterRows.add(Math.floor(from.diver_slot / FORM_COLS));
      else if (wingShot) shooterRows.add(Math.floor(wingShot.slot / FORM_COLS));
      else strayShots++;
      const bossDive = from?.diver_slot === BOSS_SLOT;
      if (bossDive && lead) bossEv.shots++;
      if (bossDive && wingShot) bossEv.guardShots[`${bossEv.dives}:${wingShot.k}`] = (bossEv.guardShots[`${bossEv.dives}:${wingShot.k}`] ?? 0) + 1;
      guardShotLive[k] = bossDive ? wingShot?.k ?? -1 : null;
      // a burst opens only once the diver is low and over the player (after the player's
      // move); a guard's single shot is aimed from its own x
      const opens = bossDive || spawns.length < 2 || i - spawns[spawns.length - 2] !== BURST_GAP;
      const dx = from && (bossDive && wingShot ? wingShot.x : from.diver_x) + ALIEN_MID - (ram.player_x + 6);
      if (from && opens && (from.diver_y < afireTops[from.level] || Math.abs(dx) > afireRanges[from.level]))
        farBursts.push({ frame: i, diver_y: from.diver_y, dx });
    }
    if (!b.on) guardShotLive[k] = null;
    if (guardShotLive[k] != null) {
      const members = [...(ram.diver_state && !ram.lead_gone ? [{ x: ram.diver_x, y: ram.diver_y }] : []),
        ...wingsOf(ram).filter((w) => w.k !== guardShotLive[k])];
      if (members.some((a) => b.x >= a.x && b.x < a.x + ALIEN_W && b.y + 4 > a.y && b.y < a.y + ALIEN_H)) bossEv.overShots.push(i);
    }
    const near = (s) => s.name === "abullet" && s.x === b.x && Math.abs(s.y - b.y) <= ABULLET_SPEED;
    // a diver's burst can put two shots a few pixels apart in one column, where their
    // EORed images merge: no step is measured for either then
    const crowded = [ram, prev].some((q) => q?.abullets.some((o, j) => j !== k && o.on && o.x === b.x && Math.abs(o.y - b.y) < 8));
    // and likewise through a ship already hit, which it passes through
    const overShip = [ram, prev].some((q) => q && Math.abs(b.x - q.player_x - 4) < 8 && Math.abs(b.y - PLAYER_Y) < 12);
    const shot = b.on && prev?.abullets[k].on && !crowded && !overShip ? sprites.find(near) : null;
    tracks.abullets[k].push(shot ? shot.y : null);
  });
}

function steps(series) {
  const hist = {};
  for (let i = 1; i < series.length; i++) {
    if (series[i] == null || series[i - 1] == null) continue;
    const d = series[i] - series[i - 1];
    hist[d] = (hist[d] ?? 0) + 1;
  }
  return hist;
}
// Frames between moves, restarting whenever the row is not visible.
function cadence(series) {
  const gaps = {};
  let last = null;
  for (let i = 1; i < series.length; i++) {
    if (series[i] == null) last = null;
    if (series[i] == null || series[i - 1] == null || series[i] === series[i - 1]) continue;
    if (last != null) gaps[i - last] = (gaps[i - last] ?? 0) + 1;
    last = i;
  }
  return gaps;
}

// Moves after a gap over 2 frames, unless a 1px glide every 3 frames. A change of offset
// from the leader counts as a move: the guard held still on screen while closing in.
function slowGaps(track) {
  const bad = [];
  let last = null;
  for (let i = 1; i < track.length; i++) {
    const p = track[i], q = track[i - 1];
    if (p == null) last = null;
    if (p == null || q == null) continue;
    if (p.x === q.x && p.y === q.y) {
      if (p.off !== q.off) last = i;
      continue;
    }
    const g = last == null ? 0 : i - last;
    if (g > 3 || (g === 3 && Math.max(Math.abs(p.x - q.x), Math.abs(p.y - q.y)) > 1)) bad.push(i);
    last = i;
  }
  return bad;
}

const merge = (hists) => {
  const out = {};
  for (const h of hists) for (const [k, n] of Object.entries(h)) out[k] = (out[k] ?? 0) + n;
  return out;
};

function span(a, b, axis) {
  const d = a.map((p, k) => (p && b[k] ? b[k][axis] - p[axis] : null)).filter((v) => v != null);
  return d.length ? [Math.min(...d), Math.max(...d)] : [];
}

// The formation's sway, from RAM: how often each row steps, whether the rows stay together, when they flap.
function sway() {
  const stepGaps = {}, beats = new Set(), last = Array(FORM_ROWS).fill(null);
  let spread = 0;
  for (let i = 1; i < captured.length; i++) {
    const { ram } = captured[i], prev = captured[i - 1].ram;
    if (ram.intro || prev.intro) { last.fill(null); continue; }
    spread = Math.max(spread, Math.max(...ram.rowX) - Math.min(...ram.rowX));
    for (let r = 0; r < FORM_ROWS; r++) {
      if (ram.rowX[r] !== prev.rowX[r]) {
        if (last[r] != null) stepGaps[i - last[r]] = (stepGaps[i - last[r]] ?? 0) + 1;
        last[r] = i;
      }
      if (ram.rowAnim[r] !== prev.rowAnim[r]) beats.add(ram.frame & (FLAP_PERIOD - 2));
    }
  }
  return { sway_step_gaps: stepGaps, row_spread_max: spread, flap_phases: beats.size };
}

const report = {
  frames: captured.length,
  dropped_frames: dropped,
  laps: { ...lapEv, bad: lapEv.bad.slice(0, 5), wrongKind: lapEv.wrongKind.slice(0, 5) },
  intro_shots: introShots,
  lines: { ...lineEv, off: lineEv.off.slice(0, 5), offCount: lineEv.off.length, openAtWrap: lineEv.openAtWrap.slice(0, 5), lostInAir: lineEv.lostInAir.slice(0, 5) },
  dropped_at: droppedAt.slice(0, 5),
  new_waves: waves,
  torn_frames: defects.length,
  beam_races: races.length,
  busy_us: { median: [...busy].sort((a, b) => a - b)[busy.length >> 1], max: busy.reduce((a, b) => Math.max(a, b), 0) },
  player_steps: steps(tracks.player),
  formation_x_steps: merge(tracks.slots.map((t) => steps(t.map((p) => p?.x ?? null)))),
  formation_y_steps: merge(tracks.slots.map((t) => steps(t.map((p) => p?.y ?? null)))),
  formation_diagonal_steps: tracks.slots.reduce((n, t) => n + t.filter((p, k) => p && t[k - 1] && p.x !== t[k - 1].x && p.y !== t[k - 1].y).length, 0),
  formation_gaps: merge(tracks.slots.map((t) => cadence(t.map((p) => (p ? `${p.x},${p.y}` : null))))),
  // outer alien to outer alien, both on screen: bottom row across, top row to bottom row
  // each row's outer slots: divers and kills hide them, so any full row will do
  formation_widths: rowEnds.map(([a, b], r) => span(tracks.slots[r * FORM_COLS + a], tracks.slots[r * FORM_COLS + b], "x")),
  // each row's lowest to highest y: the outer rows travel furthest
  formation_row_travel: [...Array(FORM_ROWS)].map((_, r) => {
    const ys = tracks.slots.slice(r * FORM_COLS, (r + 1) * FORM_COLS).flat().filter(Boolean).map((p) => p.y);
    return ys.length ? Math.max(...ys) - Math.min(...ys) : 0;
  }),
  ...sway(),
  ship_x_range: (() => {
    const xs = captured.filter((c) => !c.ram.player_state).map((c) => c.ram.player_x);
    return [Math.min(...xs), Math.max(...xs)];
  })(),
  diver_x_steps: steps(tracks.diver.map((d) => d?.x ?? null)),
  diver_y_steps: steps(tracks.diver.map((d) => d?.y ?? null)),
  wing_x_steps: merge(tracks.wings.map((t) => steps(t.map((d) => d?.x ?? null)))),
  wing_y_steps: merge(tracks.wings.map((t) => steps(t.map((d) => d?.y ?? null)))),
  wing_frames: tracks.wings.map((t) => t.filter(Boolean).length),
  boss: {
    ...bossEv, colours: [...bossEv.colours].sort(), pulseSeen: [...bossEv.pulseSeen].sort(),
    x_steps: steps(tracks.boss.map((d) => d?.x ?? null)), y_steps: steps(tracks.boss.map((d) => d?.y ?? null)),
    gaps: cadence(tracks.bossDown.map((d) => (d ? `${d.x},${d.y}` : null))),
    guard_gaps: merge(tracks.guards.map((t) => cadence(t.map((d) => (d ? `${d.x},${d.y}` : null))))),
    guard_slow_at: tracks.guards.flatMap(slowGaps).slice(0, 5),
  },
  warp: { frames: warpFrames, steps: warpSteps, after: starSteps },
  alien_frames_seen: [...frameNames].sort(),
  bullet_steps: tracks.bullets.map(steps),
  // an alien marked diving with no diver flying never got home
  stranded_frames: captured.filter((c) => !c.ram.diver_state && c.ram.alive.includes(2)).length,
  docked: captured.filter((c, i) => i && captured[i - 1].ram.diver_state === 2 && !c.ram.diver_state).length,
  abullet_steps: merge(tracks.abullets.map(steps)),
  // steps BURST_GAP frames apart belong to one burst; counted in the game, as a pair's
  // shots can find every enemy bullet in flight
  // per level: { size: count }
  bursts: burstSteps.reduce((acc, { frame, level }, k) => {
    if (k && frame - burstSteps[k - 1].frame === BURST_GAP) acc[acc.length - 1].n++;
    else acc.push({ level, n: 1 });
    return acc;
  }, []).reduce((h, b) => ((h[b.level] ??= {}), (h[b.level][b.n] = (h[b.level][b.n] ?? 0) + 1), h), {}),
  // a burst BURST_PAUSE frames after the last: the rush's next burst
  rebursts: burstSteps.filter((b, k) => k && b.frame - burstSteps[k - 1].frame === BURST_PAUSE).map((b) => b.rush),
  turn_steps: turnSteps,
  // frames from the dive timer starting to the launch; rush: from the count reaching RUSH_COUNT
  dive_gaps: idles.reduce((h, d) => ((h[d.level] ??= {}), (h[d.level][d.rush == null ? d.gap : `rush ${d.rush}`] = (h[d.level][d.rush == null ? d.gap : `rush ${d.rush}`] ?? 0) + 1), h), {}),
  shooter_rows: [...shooterRows].sort(),
  stray_shots: strayShots,
  far_bursts: farBursts,
  death,
  slide_missing_at: slideMissingAt.slice(0, 5),
  spares_right: sparesRight,
  spares_wrong: sparesWrong.slice(0, 5),
  banner_frames: bannerFrames,
  drop_steps: merge(drops.map(steps)),
  drop_first_y: [...new Set(drops.filter((d) => d.length).map((d) => d.find((y) => y != null)))],
  drop_unseen: drops.map((d, i) => (d.length && d.every((y) => y == null) ? i : null)).filter((i) => i != null),
  max_bullets_in_flight: Math.max(...captured.map((c) => c.ram.bullets.filter((b) => b.on).length)),
  max_abullets_in_flight: Math.max(...captured.map((c) => c.ram.abullets.filter((b) => b.on).length)),
  stars: { missing: starsMissing, moves: starsMoved, twinkled_out: starsHidden, missing_at: starsMissingAt.slice(0, 5) },
  flash_frames: flashFrames,
  stage_bonus: stageBonus,
  bonus: { ...bonusEv, steps: steps(tracks.bonus) },
  rapid: rapidEv,
};

const only = (hist, ok) => Object.keys(hist).every((k) => ok(Number(k)));
const checks = {
  "SHIFT+BREAK boots to the title": bootedToTitle,
  "no dropped frames": report.dropped_frames === 0,
  "no torn or flickering sprites": report.torn_frames === 0,
  "no plot raced the beam": report.beam_races === 0,
  "player moves 1.5px per frame: 1px, then 2px": only(report.player_steps, (d) => Math.abs(d) <= 2) && (report.player_steps[2] > 0 || report.player_steps[-2] > 0),
  "formation aliens move at most 1px per step": [report.formation_x_steps, report.formation_y_steps].every((h) => only(h, (d) => Math.abs(d) <= 1)),
  "formation aliens move only on their row's frame": only(report.formation_gaps, (g) => g % 2 === 0),
  "every row sways 1px every 2 frames, or 4 past a breathing step": Object.keys(report.sway_step_gaps).join() === "2,4",
  "formation breathes in and out fully": report.formation_widths.some((w, r) => {
    const [a, b] = rowEnds[r], full = breath[BREATH_STEPS * FORM_COLS + b] - breath[BREATH_STEPS * FORM_COLS + a];
    return w[1] - w[0] === full;
  }),
  "formation breathes up and down fully": (() => {
    // row r moves out vbreath[BREATH_STEPS * FORM_COLS + r]: the outer rows most
    const t = report.formation_row_travel;
    return t.every((d, r) => d === 0 || d === Math.abs(vbreath[BREATH_STEPS * FORM_COLS + r])) && Math.max(...t) === VBREATH_MAX;
  })(),
  "a formation alien never moves across and up or down at once": report.formation_diagonal_steps === 0,
  "the rows move as one": report.row_spread_max <= 1,
  "the rows flap together": report.flap_phases === 1,
  "the ship stays out from under the outer columns": report.ship_x_range[0] >= SHIP_MIN_X && report.ship_x_range[1] <= SHIP_MAX_X,
  "diver moves at most 2px sideways per frame": only(report.diver_x_steps, (d) => Math.abs(d) <= 2),
  [`diver moves at most ${DIVER_SPEED}px up or down per frame (or wraps)`]: only(report.diver_y_steps, (d) => Math.abs(d) <= DIVER_SPEED || d < -100),
  "divers dock back in the formation": report.stranded_frames === 0 && report.docked > 0,
  "a wingman dives with the diver, as smoothly": report.wing_frames[0] > 0 &&
    only(report.wing_x_steps, (d) => Math.abs(d) <= 2) && only(report.wing_y_steps, (d) => Math.abs(d) <= DIVER_SPEED || d < -100),
  "diver loops: it climbs before diving": Object.keys(report.diver_y_steps).some((k) => k < 0 && k > -100),
  "only the lower rows' dives open with a full loop": lapEv.lower > 0 && lapEv.upper > 0 && lapEv.wrongKind.length === 0,
  "a full loop is round and comes back where it left": lapEv.finished > 0 && lapEv.bad.length === 0,
  "a lower row's neighbours follow the lead round its loop, in line": lineEv.samples > 0 && lineEv.off.length === 0,
  "a lower row with 3 or more home always dives as a line of 3": lineEv.fullRows > 0 && lineEv.short.length === 0,
  "the ship can fire through a stage's intro until the aliens drop in, and hits nothing until they have landed": introShots.fired > 0 && introShots.whileDropping === 0 && introShots.hits === 0,
  "a line's loop clears the formation": LAP_Y - 4 * LOOP_R >= FORM_Y + (FORM_ROWS - 1) * ROW_STEP + ALIEN_H,
  "a line leaves at the bottom one by one and comes back in view": lineEv.lostInAir.length === 0 && lineEv.openAtWrap.length === 0,
  "aliens flap: both frames shown": report.alien_frames_seen.filter((n) => n !== "boss").length === 6,
  [`bullets move ${BULLET_SPEED}px per frame`]: report.bullet_steps.every((h) => only(h, (d) => d === -BULLET_SPEED)),
  [`at most ${BULLETS} bullets in flight at once`]: report.max_bullets_in_flight <= BULLETS,
  "at most 3 enemy bullets at once": ABULLETS === 3 && report.max_abullets_in_flight === 3,
  [`enemy bullets move ${ABULLET_SPEED}px per frame`]: Object.keys(report.abullet_steps).length > 0 && only(report.abullet_steps, (d) => d === ABULLET_SPEED),
  // shorter bursts were cut off near the player or by the diver's end
  "bursts grow with the wave, never past the wave's size": Object.keys(report.bursts).length > 1 &&
    Object.entries(report.bursts).every(([l, h]) => only(h, (n) => n <= burstMins[l] + 1) &&
      // a wave the run only just reached may not have shown its full burst
      (Object.values(h).reduce((a, b) => a + b, 0) < 3 || Object.keys(h).some((n) => n >= burstMins[l]))),
  "each wave dives at its own pace": Object.keys(report.dive_gaps).length > 1 &&
    // a launch waits a frame while the chosen alien's row steps
    idles.filter((d) => d.rush == null).every((d) => d.gap >= d.delay - 1 && d.gap <= d.delay + 3),
  "the last few aliens rush": idles.some((d) => d.rush != null) &&
    idles.filter((d) => d.rush != null).every((d) => d.rush <= RUSH_DELAY + 2),
  "in the rush, swooping aliens fire again after a pause": report.rebursts.length > 0 && report.rebursts.every(Boolean),
  "in the rush, swooping aliens turn twice as hard": only(report.turn_steps.calm, (d) => d <= 1) &&
    only(report.turn_steps.rush, (d) => d <= 2) && report.turn_steps.rush[2] > 0,
  "WAVE banner shows": report.banner_frames >= BANNER_TIME,
  "rows drop in from the top 1px per frame": only(report.drop_steps, (d) => d === 1) && report.drop_steps[1] > 0 &&
    report.drop_first_y.length === 1 && report.drop_first_y[0] === DROP_Y && report.drop_unseen.length === 0,
  "only swooping aliens fire": report.stray_shots === 0,
  "swooping aliens fire only near the player": report.far_bursts.length === 0,
  "aliens from more than one row fire": report.shooter_rows.length > 1,
  "spare ships show lives - 1": sparesRight > 0 && sparesWrong.length === 0,
  "a hit ship flashes the screen": flashFrames > 0 && flashFrames <= death.hits * num("FLASH_TIME"),
  "a hit ship blinks out": death.hits > 0 && death.blinkShown > 0 && death.blinkHidden > 0,
  [`the next ship slides in to x ${PLAYER_START}`]: death.slides > 0 && death.slideMissing === 0 &&
    death.arrivals.length > 0 && death.arrivals.every(([x, y]) => x === PLAYER_START && y === PLAYER_Y),
  "a ship out of play can't be hit or fire": death.hitOutOfPlay === 0 && death.shotOutOfPlay === 0,
  "stars show where RAM says": starsMissing === 0,
  "stars scroll and twinkle": starsMoved > 0 && starsHidden > 0,
  "only the boss drops a capsule": bonusEv.otherDrops === 0,
  "reaching stage N > 1 scores N x 500 under its banner": stageBonus.paid.some(([w]) => w >= 2) && stageBonus.wrong.length === 0,
  "the capsule falls 1.5px per frame": report.bonus.steps[1] > 0 && report.bonus.steps[2] > 0 &&
    only(report.bonus.steps, (d) => d === 1 || d === 2) &&
    Math.abs(report.bonus.steps[1] - report.bonus.steps[2]) <= Math.max(4, (report.bonus.steps[1] + report.bonus.steps[2]) / 10),
  "single shot until the capsule is caught, double until a ship is lost, across stages": (bonusEv.catches === 0 || bonusEv.doubleShots > 0) &&
    bonusEv.secondWithoutPower === 0 && bonusEv.lostWithoutHit === 0 && bonusEv.stageResets === 0,
  "a third shot only with rapid fire, given only for a capsule caught with the double shot, kept across stages":
    (rapidPoke == null || rapidEv.thirdShots > 0) && rapidEv.thirdWithoutRapid.length === 0 && rapidEv.wrongGrants === 0 && rapidEv.stepDowns === 0,
  "the boss shows its own colours, never the flagships'": report.boss.colours.length === new Set(bossColours).size &&
    report.boss.colours.every((c) => bossColours.includes(c)) && !report.boss.colours.some((c) => report.boss.pulseSeen.includes(c)),
  "the boss dives with two guards, as smoothly": report.boss.dives > 0 && report.boss.guardedFrames > 0 && report.wing_frames[1] > 0 &&
    only(report.boss.x_steps, (d) => Math.abs(d) <= 2) && only(report.boss.y_steps, (d) => Math.abs(d) <= DIVER_SPEED || d < -100) &&
    only(report.boss.gaps, (g) => g <= 2) && report.boss.guard_slow_at.length === 0,
  "a shot boss drops the capsule and stays gone for the wave": report.boss.kills > 0 && report.boss.drops > 0 &&
    report.boss.dropYs.every((y) => y >= DIVER_TOP && y <= BONUS_LOW) &&
    report.boss.killsUndropped === 0 && report.boss.backAfterKill === 0,
  "the boss never fires; each guard fires at most once a dive, never over the boss or the other guard":
    report.boss.dives > 0 && report.boss.shots === 0 && Object.keys(report.boss.guardShots).length > 0 &&
    Object.values(report.boss.guardShots).every((n) => n === 1) && report.boss.overShots.length === 0,
  "stars warp between waves, then scroll as before": report.warp.frames >= 90 &&
    Math.max(...Object.keys(report.warp.steps).map(Number)) >= 4 * 2 && Math.max(...Object.keys(report.warp.after).map(Number)) <= 2,
};

print(JSON.stringify(report, null, 1));
if (DUMP) print("defects", JSON.stringify(defects.slice(0, 8)), "races", JSON.stringify(races.slice(0, 8)));
for (const [name, ok] of Object.entries(checks)) print(`${ok ? "PASS" : "FAIL"}  ${name}`);

if (PNG_DIR && defects.length) {
  const sharp = (await import(path.join(J, "node_modules/sharp/lib/index.js"))).default;
  fs.mkdirSync(PNG_DIR, { recursive: true });
  const pal = [...Array(8)].map((_, c) => [c & 1 ? 255 : 0, c & 2 ? 255 : 0, c & 4 ? 255 : 0]);
  for (const d of defects.slice(0, 8)) {
    const g = captured[d.frame].grid;
    const px = Buffer.alloc(640 * 256 * 3);
    for (let y = 0; y < 256; y++)
      for (let x = 0; x < 640; x++) pal[g[y * 160 + (x >> 2)]].forEach((v, k) => (px[(y * 640 + x) * 3 + k] = v));
    await sharp(px, { raw: { width: 640, height: 256, channels: 3 } })
      .resize(640, 512, { kernel: "nearest" })
      .png()
      .toFile(path.join(PNG_DIR, `defect-${d.frame}.png`));
  }
  print(`wrote ${Math.min(8, defects.length)} PNGs to ${PNG_DIR}`);
}
process.exit(Object.values(checks).every(Boolean) ? 0 : 1);
