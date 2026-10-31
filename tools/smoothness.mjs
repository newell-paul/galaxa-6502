// Headless smoothness test for Galaxa.
//
// Boots galaxa.ssd in jsbeeb with its beam-accurate video chip, plays a scripted input
// sequence and inspects every displayed frame:
//   - torn or flickering sprites: lit pixels that are not part of a whole sprite
//   - plots that raced the beam: the beam swept the sprite's rows while it was drawn
//   - step size and cadence of the player, each formation alien, the diver, its wingman
//     and the bullets
//   - that the aliens flap, the formation breathes and the diver loops
//   - that aliens from every row fire bursts, only while swooping near the player, and
//     their bullets move steadily
//   - that each wave dives more often and fires more, and the last few aliens rush
//   - that the stars show where RAM says, scroll and twinkle, and never mark a sprite
//   - the bonus capsule: it drops after enough swooping aliens are shot, falls 1px per
//     frame, and catching it turns the single shot into the double shot until a ship is lost
//   - the WAVE banner, and the rows dropping in from the top 1px per frame
//   - dropped frames: the main loop missing a vsync
//   - that SHIFT+BREAK boots to the title screen, and a hit ship flashes the screen
// Exits non-zero if anything is not smooth.
//
// Usage: node tools/smoothness.mjs [frames] [--png dir] [--dump]
//   JSBEEB_DIR defaults to ~/.local/share/jsbeeb
import fs from "node:fs";
import path from "node:path";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const J = process.env.JSBEEB_DIR ?? path.join(process.env.HOME, ".local/share/jsbeeb");
const FRAMES = Number(process.argv[2] ?? 3000);
const pngIdx = process.argv.indexOf("--png");
const PNG_DIR = pngIdx > 0 ? path.resolve(process.argv[pngIdx + 1]) : null;
const DUMP = process.argv.includes("--dump");

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
// A constant: a number, or a sum or product of other constants (DIV rounds down)
const num = (name) => {
  const expr = src.match(new RegExp(`^${name}\\s*=\\s*([^;\\n]+)`, "m"))[1];
  const js = expr.replace(/(\w+) DIV (\d+)/g, "Math.floor($1 / $2)").replace(/\b[A-Z][A-Z0-9_]*\b/g, num);
  if (!/^(?:[\d\s+\-*/()]|Math\.floor)*$/.test(js)) throw new Error(`${name}: not plain arithmetic: ${expr}`);
  return Function(`return ${js}`)();
};
const PLAYER_Y = num("PLAYER_Y");
const SPARE_Y = num("SPARE_Y");
const PLAYER_START = num("PLAYER_START");
const ALIEN_W = num("ALIEN_W");
const ALIEN_H = num("ALIEN_H");
const ALIEN_MID = num("ALIEN_MID");
const FORM_ROWS = num("FORM_ROWS");
const FORM_COLS = num("FORM_COLS");
const LEVELS = num("LEVELS");
const RUSH_COUNT = num("RUSH_COUNT");
const RUSH_DELAY = num("RUSH_DELAY");
const FORM_Y = num("FORM_Y");
const COL_STEP = num("COL_STEP");
const ROW_STEP = num("ROW_STEP");
const SPR_BULLET = num("SPR_BULLET");
const BULLETS = num("BULLETS");
const NUM_STARS = num("NUM_STARS");
const ABULLETS = num("ABULLETS");
const ABULLET_SPEED = num("ABULLET_SPEED");
const BURST_GAP = num("BURST_GAP");
const DIVER_SPEED = num("DIVER_SPEED");
const BREATH_MAX = num("BREATH_MAX");
const BANNER_Y = num("BANNER_Y");
const BANNER_COL = num("BANNER_COL");
const BANNER_TIME = num("BANNER_TIME");
const DROP_Y = num("DROP_Y");
const BONUS_KILLS = num("BONUS_KILLS");
const VBREATH_MAX = num("VBREATH_MAX");
// Logical colour -> the physical colours it can show; the pulsing one cycles.
const PULSE_COLOUR = num("PULSE_COLOUR");
const pulse = src.match(/^\.pulse_colours[^\n]*\n\s*EQUB ([\d, ]+)/m)[1].split(",").map(Number);
const shows = (logical, phys) => (logical === PULSE_COLOUR ? pulse.includes(phys) : logical === phys);

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
const prompt = [...Array(13)].map((_, i) => String.fromCharCode(m.readbyte(0x7c00 + 23 * 40 + 14 + i))).join("");
const bootedToTitle = idle && prompt === "PRESS ANY KEY";
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
  const rowX = [], rowY = [], rowBofs = [], alive = [], bullets = [];
  for (let r = 0; r < FORM_ROWS; r++)
    rowX.push(rb(labels.row_x + r)), rowY.push(rb(labels.row_y + r)), rowBofs.push(rb(labels.row_bofs + r));
  for (let i = 0; i < FORM_ROWS * FORM_COLS; i++) alive.push(rb(labels.alive + i));
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
    diver_slot: rb(zp.diver_slot), wing_on: rb(zp.wing_on), wing_x: rb(zp.wing_x), wing_slot: rb(zp.wing_slot),
    lead_gone: rb(zp.lead_gone), intro: rb(labels.intro), level: rb(labels.level),
    alive_count: rb(zp.alive_count),
    rowX, rowY, rowBofs, alive, lives: rb(labels.lives), stars,
    ships_shown: rb(labels.ships_shown), player_state: rb(labels.player_state), player_row: rb(labels.player_row),
    power: rb(zp.power), bonus_on: rb(zp.bonus_on), dive_kills: rb(zp.dive_kills), bonus_x: rb(zp.bonus_x), bonus_y: rb(zp.bonus_y),
  };
}

// ------------------------------------------------------------------ scripted input
const KEYS = { Z: utils.keyCodes.Z, X: utils.keyCodes.X, FIRE: utils.keyCodes.ENTER };
// Aims: under a falling capsule, else a low diver, else the nearest alien of the lowest
// row still holding one; fires whenever it can.
function keysFor(i) {
  const held = new Set();
  const rb = (a) => m.readbyte(a);
  let target = null;
  if (rb(zp.bonus_on)) target = rb(zp.bonus_x);
  else if (rb(zp.diver_state) === 1 && rb(zp.diver_y) > 96) target = rb(zp.diver_x) + ALIEN_MID - 3;
  else
    for (let r = FORM_ROWS - 1; r >= 0 && target == null; r--)
      for (let c = 0; c < FORM_COLS; c++) {
        if (rb(labels.alive + r * FORM_COLS + c) !== 1) continue;
        const x = rb(labels.row_x + r) + c * COL_STEP + breath[rb(labels.row_bofs + r) + c] + ALIEN_MID - 3;
        if (target == null || Math.abs(x - rb(zp.player_x)) < Math.abs(target - rb(zp.player_x))) target = x;
      }
  const d = target == null ? 0 : target - rb(zp.player_x);
  if (d) held.add(d > 0 ? "X" : "Z");
  if (i % 4 < 2) held.add("FIRE");
  return held;
}
let inputFrame = 0;
let down = new Set();
onFrame = () => {
  if (!capturing) return;
  // soak test: keep the scripted player alive so every frame is gameplay
  if (m.readbyte(labels.lives) < 2) m.writebyte(labels.lives, 3);
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
  else if (addr === labels.af_shot) burstSteps.push({ frame: captured.length, level: m.readbyte(labels.level) });
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
const signedTable = (base) => [...Array((BREATH_MAX + 1) * FORM_COLS)].map((_, k) => (m.readbyte(base + k) << 24) >> 24);
const breath = signedTable(labels.breath);
const vbreath = signedTable(labels.vbreath);
const levelTable = (name) => [...Array(LEVELS)].map((_, k) => m.readbyte(labels[name] + k));
const diveDelays = levelTable("dive_delays"), burstMins = levelTable("burst_mins");
const afireTops = levelTable("afire_tops"), afireRanges = levelTable("afire_ranges");
capturing = true;
while (captured.length < FRAMES) await m.runFor(20000);

// ------------------------------------------------------------------ analysis
const templates = ["player", "bullet", "abullet", "bonus", "flagship", "flagship_b", "escort", "escort_b", "drone", "drone_b"].map((name) => ({
  name,
  rows: art[name],
  w: art[name][0].length,
}));
const isAlien = (s) => /^(flagship|escort|drone)/.test(s.name);
// Where formation slot i sits: its row's sway plus its column's breathing offset.
const slotX = (ram, i) => {
  const r = Math.floor(i / FORM_COLS), c = i % FORM_COLS;
  return ram.rowX[r] + c * COL_STEP + breath[ram.rowBofs[r] + c];
};
const slotY = (ram, i) => ram.rowY[Math.floor(i / FORM_COLS)];
// A sprite's blank pixels may show a star: white, where RAM puts a shown star.
let starAt = new Uint8Array(160 * 256);
const pixelOk = (logical, g, k) => shows(logical, g[k]) || (logical === 0 && g[k] === 7 && starAt[k]);
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
function overlapZones(ram) {
  const boxes = [{ x: ram.player_x, y: ram.player_row, h: 8 }];
  for (let k = 0; k < ram.ships_shown; k++) boxes.push({ x: 10 * k, y: SPARE_Y, h: 8 });
  for (const b of [...ram.bullets, ...ram.abullets]) if (b.on) boxes.push({ x: b.x, y: b.y, h: 4 });
  if (ram.diver_state) boxes.push({ x: ram.diver_x, y: ram.diver_y, h: ALIEN_H });
  if (ram.diver_state && ram.wing_on) boxes.push({ x: ram.wing_x, y: ram.diver_y, h: ALIEN_H });
  if (ram.bonus_on) boxes.push({ x: ram.bonus_x, y: ram.bonus_y, h: ALIEN_H });
  ram.alive.forEach((a, i) => {
    const r = Math.floor(i / FORM_COLS);
    if (a === 1) boxes.push({ x: slotX(ram, i), y: slotY(ram, i), h: ALIEN_H });
  });
  const zones = [];
  for (let a = 0; a < boxes.length; a++)
    for (let b = a + 1; b < boxes.length; b++) {
      const A = boxes[a], B = boxes[b];
      if (Math.abs(A.x - B.x) < ALIEN_W + 2 && A.y < B.y + B.h + 2 && B.y < A.y + A.h + 2)
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
  player: [], slots: [...Array(FORM_ROWS * FORM_COLS)].map(() => []), diver: [], wing: [],
  bullets: [...Array(BULLETS)].map(() => []), abullets: [...Array(ABULLETS)].map(() => []), bonus: [],
};
// per drop, the game's count of swooping aliens shot before the one that dropped it;
// miscounts: frames its count moved other than by the swooping aliens shot then
const bonusEv = { drops: [], miscounts: 0, catches: 0, doubleShots: 0, secondWithoutPower: 0, lostWithoutHit: 0 };
const spawns = [];
const idles = [];
let idleStart = null, rushStart = null, idlePaused = false;
const farBursts = [];
const shooterRows = new Set();
let strayShots = 0;
let dropped = 0;
const droppedAt = [];
let bannerFrames = 0;
const drops = [...Array(FORM_ROWS * FORM_COLS)].map(() => []);
let waves = 0;
let starsMissing = 0, starsMoved = 0, starsHidden = 0;
const frameNames = new Set();
let flashFrames = 0;
const blank = new Uint8Array(160 * 256);
for (let i = 0; i < captured.length; i++) {
  let { grid, ram } = captured[i];
  // a hit ship flashes the background: no sprite can be told from it then
  const flash = grid.subarray(128 * 160, 129 * 160).filter(Boolean).length > 120;
  if (flash) { flashFrames++; grid = blank; }
  const prev = captured[i - 1]?.ram;
  if (prev && ((ram.frame - prev.frame) & 0xff) !== 1) dropped++, droppedAt.push({ frame: i, intro: ram.intro, diver: ram.diver_state, wing: ram.wing_on, player: ram.player_state });
  // a new wave redraws the formation at its start position: not a step
  const newWave = prev && ram.alive.filter(Boolean).length > prev.alive.filter(Boolean).length;
  if (newWave) waves++;
  // the dive timer runs while no diver flies: from the end of the intro or of the last dive
  if (prev && ((prev.intro && !ram.intro) || (prev.diver_state && !ram.diver_state))) idleStart = rushStart = null;
  if (!ram.intro && !ram.diver_state) {
    idleStart ??= i;
    if (ram.alive_count <= RUSH_COUNT) rushStart ??= i;
    // the timer stops while the ship is out of play
    if (ram.player_state) idlePaused = true;
  }
  if (prev && !prev.diver_state && ram.diver_state === 1 && idleStart != null) {
    if (!idlePaused) idles.push({ level: ram.level, gap: i - idleStart, rush: rushStart == null ? null : i - rushStart });
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
    if (!lit && prev && !flash) starsMissing++; // the first frame has no last position to allow for
  });

  const covered = new Uint8Array(160 * 256);
  for (const s of sprites)
    for (let r = 0; r < s.h; r++) for (let c = 0; c < s.w; c++) covered[(s.y + r) * 160 + s.x + c] = 1;
  // objects drawn behind the beam appear a frame later, so allow last frame's overlaps too
  const zones = [...overlapZones(ram), ...(prev ? overlapZones(prev) : [])];
  let garbage = 0, where = null;
  for (let y = 8; y < 256; y++)
    for (let x = 0; x < 160; x++) {
      const k = y * 160 + x;
      if (!grid[k] || covered[k] || (grid[k] === 7 && starAt[k])) continue;
      if (zones.some((z) => x >= z.x0 && x < z.x1 && y >= z.y0 && y < z.y1)) continue;
      if ([ram, prev].some((q) => q?.intro === 1) && y >= BANNER_Y && y < BANNER_Y + 8) continue;
      garbage++;
      where ??= { x, y };
    }
  if (garbage) defects.push({ frame: i, garbage, where });
  if (ram.intro === 1) {
    let lit = 0;
    for (let y = BANNER_Y; y < BANNER_Y + 8; y++)
      for (let x = BANNER_COL * 8; x < BANNER_COL * 8 + 48; x++) if (grid[y * 160 + x] === 7 && !starAt[y * 160 + x]) lit++;
    if (lit > 40) bannerFrames++;
  }

  tracks.player.push(sprites.find((s) => s.name === "player" && s.y === PLAYER_Y)?.x ?? null);

  if (prev) {
    const seen = (q) => sprites.some((s) => s.name === "player" && s.x === q.player_x && s.y === q.player_row);
    // an enemy bullet, the diver or its wingman over the ship: EOR mixes them
    const nearShot = (q) => q.abullets.some((b) => b.on && Math.abs(b.x - q.player_x - 4) < 6 && Math.abs(b.y - q.player_row) < 10) ||
      (q.bonus_on && Math.abs(q.bonus_y - q.player_row) < ALIEN_H + 2 && Math.abs(q.bonus_x - q.player_x) < 9) ||
      (q.diver_state && Math.abs(q.diver_y - q.player_row) < ALIEN_H + 2 &&
        [!q.lead_gone && q.diver_x, q.wing_on && q.wing_x].some((x) => x !== false && x < q.player_x + 8 && x + ALIEN_W > q.player_x));
    if (!prev.player_state && ram.player_state === 1) death.hits++;
    if (prev.player_state === 1 && ram.player_state === 1 && !nearShot(ram) && !nearShot(prev))
      seen(ram) ? death.blinkShown++ : death.blinkHidden++;
    if (prev.player_state === 1 && ram.player_state === 2) death.slides++;
    if (ram.player_state === 2 && !seen(ram) && !nearShot(ram) && !nearShot(prev))
      death.slideMissing++, slideMissingAt.push({ frame: i, x: ram.player_x, y: ram.player_row, dx: ram.diver_x, dy: ram.diver_y, ds: ram.diver_state, w: ram.wing_on && ram.wing_x });
    if (prev.player_state === 2 && !ram.player_state) death.arrivals.push([ram.player_x, ram.player_row]);
    if (prev.player_state && ram.lives < prev.lives) death.hitOutOfPlay++;
    if (prev.player_state && ram.bullets.some((b, k) => b.on && !prev.bullets[k].on)) death.shotOutOfPlay++;

    // the wave's last alien refills the formation before the next snapshot: its kill is unseen
    const kills = newWave ? null : ram.alive.filter((a, k) => a === 0 && prev.alive[k] === 2).length;
    if (!prev.bonus_on && ram.bonus_on) bonusEv.drops.push(prev.dive_kills);
    else if (kills != null && ram.dive_kills !== prev.dive_kills + (prev.power || prev.bonus_on ? 0 : kills)) bonusEv.miscounts++;
    if (!prev.power && ram.power) bonusEv.catches++;
    if (prev.power && !ram.power && ram.player_state !== 1) bonusEv.lostWithoutHit++;
    if (ram.bullets[1].on && !prev.bullets[1].on) prev.power ? bonusEv.doubleShots++ : bonusEv.secondWithoutPower++;
  }
  const bonus = ram.bonus_on === 1 && prev?.bonus_on === 1
    ? sprites.find((s) => s.name === "bonus" && s.x === ram.bonus_x && Math.abs(s.y - ram.bonus_y) <= 1)
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
    [ram, prev].some((q) => q?.diver_state && Math.abs(s.y - q.diver_y) <= 3 &&
      (Math.abs(s.x - q.diver_x) <= 2 || (q.wing_on && Math.abs(s.x - q.wing_x) <= 2)));
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

  const diver = ram.diver_state && !ram.lead_gone && !prev?.lead_gone
    ? sprites.find((s) => isAlien(s) && Math.abs(s.x - ram.diver_x) <= 2 && Math.abs(s.y - ram.diver_y) <= 3)
    : null;
  tracks.diver.push(diver ? { x: diver.x, y: diver.y } : null);
  const wing = ram.diver_state && ram.wing_on && prev?.wing_on
    ? sprites.find((s) => isAlien(s) && Math.abs(s.x - ram.wing_x) <= 2 && Math.abs(s.y - ram.diver_y) <= 3)
    : null;
  tracks.wing.push(wing ? { x: wing.x, y: wing.y } : null);
  for (const a of sprites) if (isAlien(a)) frameNames.add(a.name);
  ram.bullets.forEach((b, k) => {
    const near = (s) => s.name === "bullet" && Math.abs(s.x - b.x) <= 1 && Math.abs(s.y - b.y) <= 8;
    const bullet = b.on ? sprites.find(near) : null;
    tracks.bullets[k].push(bullet ? bullet.y : null);
  });
  ram.abullets.forEach((b, k) => {
    if (b.on && !prev?.abullets[k].on) {
      // a pair fires together: one burst step
      if (spawns.at(-1) !== i) spawns.push(i);
      // aimed from the diver or its wingman as they were when the frame began
      const from = prev?.diver_state === 1 ? prev : null;
      const lead = from && !from.lead_gone && Math.abs(b.x - (from.diver_x + ALIEN_MID)) <= 2;
      const wingShot = from && from.wing_on && Math.abs(b.x - (from.wing_x + ALIEN_MID)) <= 2;
      if (lead) shooterRows.add(Math.floor(from.diver_slot / FORM_COLS));
      else if (wingShot) shooterRows.add(Math.floor(from.wing_slot / FORM_COLS));
      else strayShots++;
      // a burst opens only once the diver is low and over the player (after the player's move)
      const opens = spawns.length < 2 || i - spawns[spawns.length - 2] !== BURST_GAP;
      const dx = from && from.diver_x + ALIEN_MID - (ram.player_x + 6);
      if (from && opens && (from.diver_y < afireTops[from.level] || Math.abs(dx) > afireRanges[from.level]))
        farBursts.push({ frame: i, diver_y: from.diver_y, dx });
    }
    const near = (s) => s.name === "abullet" && s.x === b.x && Math.abs(s.y - b.y) <= ABULLET_SPEED;
    // a diver's burst can put two shots a few pixels apart in one column, where their
    // EORed images merge: no step is measured for either then
    const crowded = [ram, prev].some((q) => q?.abullets.some((o, j) => j !== k && o.on && o.x === b.x && Math.abs(o.y - b.y) < 8));
    const shot = b.on && prev?.abullets[k].on && !crowded ? sprites.find(near) : null;
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

const merge = (hists) => {
  const out = {};
  for (const h of hists) for (const [k, n] of Object.entries(h)) out[k] = (out[k] ?? 0) + n;
  return out;
};

function span(a, b, axis) {
  const d = a.map((p, k) => (p && b[k] ? b[k][axis] - p[axis] : null)).filter((v) => v != null);
  return d.length ? [Math.min(...d), Math.max(...d)] : [];
}

const report = {
  frames: captured.length,
  dropped_frames: dropped,
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
  formation_widths: [...Array(FORM_ROWS)].map((_, r) => span(tracks.slots[r * FORM_COLS], tracks.slots[(r + 1) * FORM_COLS - 1], "x")),
  // each row's lowest to highest y: the outer rows travel furthest
  formation_row_travel: [...Array(FORM_ROWS)].map((_, r) => {
    const ys = tracks.slots.slice(r * FORM_COLS, (r + 1) * FORM_COLS).flat().filter(Boolean).map((p) => p.y);
    return ys.length ? Math.max(...ys) - Math.min(...ys) : 0;
  }),
  diver_x_steps: steps(tracks.diver.map((d) => d?.x ?? null)),
  diver_y_steps: steps(tracks.diver.map((d) => d?.y ?? null)),
  wing_x_steps: steps(tracks.wing.map((d) => d?.x ?? null)),
  wing_y_steps: steps(tracks.wing.map((d) => d?.y ?? null)),
  wing_frames: tracks.wing.filter(Boolean).length,
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
  stars: { missing: starsMissing, moves: starsMoved, twinkled_out: starsHidden },
  flash_frames: flashFrames,
  bonus: { ...bonusEv, steps: steps(tracks.bonus) },
};

const only = (hist, ok) => Object.keys(hist).every((k) => ok(Number(k)));
const checks = {
  "SHIFT+BREAK boots to the title": bootedToTitle,
  "no dropped frames": report.dropped_frames === 0,
  "no torn or flickering sprites": report.torn_frames === 0,
  "no plot raced the beam": report.beam_races === 0,
  "player moves 1px per frame": only(report.player_steps, (d) => Math.abs(d) <= 1),
  "formation aliens move at most 1px per step": [report.formation_x_steps, report.formation_y_steps].every((h) => only(h, (d) => Math.abs(d) <= 1)),
  "formation aliens move only on their row's frame": only(report.formation_gaps, (g) => g % 4 === 0),
  "formation breathes in and out fully": report.formation_widths.some((w) => w[1] - w[0] === 2 * BREATH_MAX),
  "formation breathes up and down fully": (() => {
    // row r moves out vbreath[BREATH_MAX * FORM_COLS + r]: the outer rows most
    const t = report.formation_row_travel;
    return t.every((d, r) => d === 0 || d === Math.abs(vbreath[BREATH_MAX * FORM_COLS + r])) && Math.max(...t) === VBREATH_MAX;
  })(),
  "diver moves at most 2px sideways per frame": only(report.diver_x_steps, (d) => Math.abs(d) <= 2),
  [`diver moves at most ${DIVER_SPEED}px up or down per frame (or wraps)`]: only(report.diver_y_steps, (d) => Math.abs(d) <= DIVER_SPEED || d < -100),
  "divers dock back in the formation": report.stranded_frames === 0 && report.docked > 0,
  "a wingman dives with the diver, as smoothly": report.wing_frames > 0 &&
    only(report.wing_x_steps, (d) => Math.abs(d) <= 2) && only(report.wing_y_steps, (d) => Math.abs(d) <= DIVER_SPEED || d < -100),
  "diver loops: it climbs before diving": Object.keys(report.diver_y_steps).some((k) => k < 0 && k > -100),
  "aliens flap: both frames shown": report.alien_frames_seen.length === 6,
  "bullets move 4px per frame": report.bullet_steps.every((h) => only(h, (d) => d === -4)),
  [`${BULLETS} bullets in flight at once`]: report.max_bullets_in_flight === BULLETS,
  [`enemy bullets move ${ABULLET_SPEED}px per frame`]: Object.keys(report.abullet_steps).length > 0 && only(report.abullet_steps, (d) => d === ABULLET_SPEED),
  // shorter bursts were cut off near the player or by the diver's end
  "bursts grow with the wave, never past the wave's size": Object.keys(report.bursts).length > 1 &&
    Object.entries(report.bursts).every(([l, h]) => only(h, (n) => n <= burstMins[l] + 1) && Object.keys(h).some((n) => n >= burstMins[l])),
  "each wave dives at its own pace": Object.keys(report.dive_gaps).length > 1 &&
    // a launch waits a frame while the chosen alien's row steps
    idles.filter((d) => d.rush == null).every((d) => d.gap >= diveDelays[d.level] - 1 && d.gap <= diveDelays[d.level] + 3),
  "the last few aliens rush": idles.some((d) => d.rush != null) &&
    idles.filter((d) => d.rush != null).every((d) => d.rush <= RUSH_DELAY + 2),
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
  [`a capsule drops after ${BONUS_KILLS} swooping aliens are shot`]: bonusEv.drops.length > 0 && bonusEv.miscounts === 0 &&
    // more: the count was reached on a wave's last alien, which drops none
    bonusEv.drops.every((k) => k >= BONUS_KILLS - 1),
  "the capsule falls 1px per frame": report.bonus.steps[1] > 0 && only(report.bonus.steps, (d) => d === 1),
  "single shot until the capsule is caught, double until a ship is lost": bonusEv.catches > 0 && bonusEv.doubleShots > 0 &&
    bonusEv.secondWithoutPower === 0 && bonusEv.lostWithoutHit === 0,
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
