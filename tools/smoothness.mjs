// Headless smoothness test for Swarm.
//
// Boots swarm.ssd in jsbeeb with its beam-accurate video chip, plays a scripted input
// sequence and inspects every displayed frame:
//   - torn or flickering sprites: lit pixels that are not part of a whole sprite
//   - plots that raced the beam: the beam swept the sprite's rows while it was drawn
//   - step size and cadence of the player, each formation alien, the diver and the bullets
//   - that the aliens flap, the formation breathes and the diver loops
//   - that aliens from every row fire bursts, only while swooping near the player, and
//     their bullets move steadily
//   - that each wave dives more often and fires more, and the last few aliens rush
//   - that the stars show where RAM says, scroll and twinkle, and never mark a sprite
//   - the WAVE banner, and the rows dropping in from the top 1px per frame
//   - dropped frames: the main loop missing a vsync
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
const src = fs.readFileSync(path.join(ROOT, "swarm.asm"), "utf8");
const zp = {};
for (const m of src.matchAll(/^(\w+)\s*=\s*&([0-9A-F]+)/gm)) zp[m[1]] = parseInt(m[2], 16);
const labels = {};
for (const m of fs.readFileSync(path.join(ROOT, "swarm.sym"), "utf8").matchAll(/'(\w+)':(\d+)L/g))
  labels[m[1]] = Number(m[2]);
const art = {};
for (const m of src.matchAll(/^ART_(\w+)\s*=\s*(.+)$/gm))
  art[m[1].toLowerCase()] = [...m[2].matchAll(/"([0-9]+)"/g)].map((x) => [...x[1]].map(Number));
const num = (name) => Number(src.match(new RegExp(`^${name}\\s*=\\s*(\\d+)`, "m"))[1]);
const PLAYER_Y = num("PLAYER_Y");
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
const BREATH_MAX = num("BREATH_MAX");
const BANNER_Y = num("BANNER_Y");
const BANNER_COL = num("BANNER_COL");
const BANNER_TIME = num("BANNER_TIME");
const DROP_Y = num("DROP_Y");
const VBREATH_MAX = num("VBREATH_MAX");
// Logical colour -> the physical colours it can show; the pulsing one cycles.
const PULSE_COLOUR = num("PULSE_COLOUR");
const pulse = src.match(/^\.pulse_colours[^\n]*\n\s*EQUB ([\d, ]+)/m)[1].split(",").map(Number);
const shows = (logical, phys) => (logical === PULSE_COLOUR ? pulse.includes(phys) : logical === phys);

// ------------------------------------------------------------------ emulator
const DISC = path.join(ROOT, "swarm.ssd");
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
await m.type("*RUN SWARM");
console.log = print;

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
    diver_slot: rb(zp.diver_slot), intro: rb(labels.intro), level: rb(labels.level),
    alive_count: rb(zp.alive_count),
    rowX, rowY, rowBofs, alive, lives: rb(labels.lives), stars,
  };
}

// ------------------------------------------------------------------ scripted input
const KEYS = { Z: utils.keyCodes.Z, X: utils.keyCodes.X, FIRE: utils.keyCodes.ENTER };
function keysFor(i) {
  const held = new Set();
  const phase = i % 400;
  if (phase < 150) held.add("X");
  else if (phase < 300) held.add("Z");
  if (i % 25 < 2) held.add("FIRE");
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
let plotEntry = null;
const elapsedUs = () => 0xffff - (m.readbyte(0xfe68) | (m.readbyte(0xfe69) << 8));
function beamLine() {
  const line = video.vertCounter * 8 + video.scanlineCounter;
  return line >= 256 ? line - 312 : line; // top border and vblank count as above the screen
}
m.processor.debugInstruction.add((addr) => {
  if (!capturing) return false;
  if (addr === labels.main_loop) busy.push(elapsedUs());
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
const templates = ["player", "bullet", "abullet", "flagship", "flagship_b", "escort", "escort_b", "drone", "drone_b"].map((name) => ({
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
  const boxes = [{ x: ram.player_x, y: PLAYER_Y, h: 8 }];
  for (const b of [...ram.bullets, ...ram.abullets]) if (b.on) boxes.push({ x: b.x, y: b.y, h: 4 });
  if (ram.diver_state) boxes.push({ x: ram.diver_x, y: ram.diver_y, h: 8 });
  ram.alive.forEach((a, i) => {
    const r = Math.floor(i / FORM_COLS);
    if (a === 1) boxes.push({ x: slotX(ram, i), y: slotY(ram, i), h: 8 });
  });
  const zones = [];
  for (let a = 0; a < boxes.length; a++)
    for (let b = a + 1; b < boxes.length; b++) {
      const A = boxes[a], B = boxes[b];
      if (Math.abs(A.x - B.x) < 12 && A.y < B.y + B.h + 2 && B.y < A.y + A.h + 2)
        zones.push({
          x0: Math.min(A.x, B.x) - 2, x1: Math.max(A.x, B.x) + 12,
          y0: Math.min(A.y, B.y) - 2, y1: Math.max(A.y + A.h, B.y + B.h) + 2,
        });
    }
  return zones;
}

const defects = [];
const tracks = {
  player: [], slots: [...Array(FORM_ROWS * FORM_COLS)].map(() => []), diver: [],
  bullets: [...Array(BULLETS)].map(() => []), abullets: [...Array(ABULLETS)].map(() => []),
};
const spawns = [];
const spawnLevels = [];
const idles = [];
let idleStart = null, rushStart = null;
const farBursts = [];
const shooterRows = new Set();
let strayShots = 0;
let dropped = 0;
let bannerFrames = 0;
const drops = [...Array(FORM_ROWS * FORM_COLS)].map(() => []);
let waves = 0;
let starsMissing = 0, starsMoved = 0, starsHidden = 0;
const frameNames = new Set();
for (let i = 0; i < captured.length; i++) {
  const { grid, ram } = captured[i];
  const prev = captured[i - 1]?.ram;
  if (prev && ((ram.frame - prev.frame) & 0xff) !== 1) dropped++;
  // a new wave redraws the formation at its start position: not a step
  const newWave = prev && ram.alive.filter(Boolean).length > prev.alive.filter(Boolean).length;
  if (newWave) waves++;
  // the dive timer runs while no diver flies: from the end of the intro or of the last dive
  if (prev && ((prev.intro && !ram.intro) || (prev.diver_state && !ram.diver_state))) idleStart = rushStart = null;
  if (!ram.intro && !ram.diver_state) {
    idleStart ??= i;
    if (ram.alive_count <= RUSH_COUNT) rushStart ??= i;
  }
  if (prev && !prev.diver_state && ram.diver_state === 1 && idleStart != null) {
    idles.push({ level: ram.level, gap: i - idleStart, rush: rushStart == null ? null : i - rushStart });
    idleStart = rushStart = null;
  }
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
    if (!lit) starsMissing++;
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

  const isDiver = (s) =>
    [ram, prev].some((q) => q?.diver_state && Math.abs(s.x - q.diver_x) <= 2 && Math.abs(s.y - q.diver_y) <= 3);
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

  const diver = ram.diver_state
    ? sprites.find((s) => isAlien(s) && Math.abs(s.x - ram.diver_x) <= 2 && Math.abs(s.y - ram.diver_y) <= 3)
    : null;
  tracks.diver.push(diver ? { x: diver.x, y: diver.y } : null);
  for (const a of sprites) if (isAlien(a)) frameNames.add(a.name);
  ram.bullets.forEach((b, k) => {
    const near = (s) => s.name === "bullet" && Math.abs(s.x - b.x) <= 1 && Math.abs(s.y - b.y) <= 8;
    const bullet = b.on ? sprites.find(near) : null;
    tracks.bullets[k].push(bullet ? bullet.y : null);
  });
  ram.abullets.forEach((b, k) => {
    if (b.on && !prev?.abullets[k].on) {
      spawns.push(i);
      spawnLevels.push(ram.level);
      // aimed from the diver as it was when the frame began
      const from = prev?.diver_state === 1 && Math.abs(b.x - (prev.diver_x + 4)) <= 2 ? prev : null;
      if (from) shooterRows.add(Math.floor(from.diver_slot / FORM_COLS));
      else strayShots++;
      // a burst opens only once the diver is low and over the player (after the player's move)
      const opens = spawns.length < 2 || i - spawns[spawns.length - 2] !== BURST_GAP;
      const dx = from && from.diver_x + 4 - (ram.player_x + 6);
      if (from && opens && (from.diver_y < afireTops[from.level] || Math.abs(dx) > afireRanges[from.level]))
        farBursts.push({ frame: i, diver_y: from.diver_y, dx });
    }
    const near = (s) => s.name === "abullet" && s.x === b.x && Math.abs(s.y - b.y) <= ABULLET_SPEED;
    const shot = b.on && prev?.abullets[k].on ? sprites.find(near) : null;
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
  formation_widths: span(tracks.slots[(FORM_ROWS - 1) * FORM_COLS], tracks.slots[FORM_ROWS * FORM_COLS - 1], "x"),
  // each row's lowest to highest y: the outer rows travel furthest
  formation_row_travel: [...Array(FORM_ROWS)].map((_, r) => {
    const ys = tracks.slots.slice(r * FORM_COLS, (r + 1) * FORM_COLS).flat().filter(Boolean).map((p) => p.y);
    return ys.length ? Math.max(...ys) - Math.min(...ys) : 0;
  }),
  diver_x_steps: steps(tracks.diver.map((d) => d?.x ?? null)),
  diver_y_steps: steps(tracks.diver.map((d) => d?.y ?? null)),
  alien_frames_seen: [...frameNames].sort(),
  bullet_steps: tracks.bullets.map(steps),
  // an alien marked diving with no diver flying never got home
  stranded_frames: captured.filter((c) => !c.ram.diver_state && c.ram.alive.includes(2)).length,
  docked: captured.filter((c, i) => i && captured[i - 1].ram.diver_state === 2 && !c.ram.diver_state).length,
  abullet_steps: merge(tracks.abullets.map(steps)),
  // shots BURST_GAP frames apart belong to one burst
  // per level: { size: count }
  bursts: spawns.reduce((acc, f, k) => {
    if (k && f - spawns[k - 1] === BURST_GAP) acc[acc.length - 1].n++;
    else acc.push({ level: spawnLevels[k], n: 1 });
    return acc;
  }, []).reduce((h, b) => ((h[b.level] ??= {}), (h[b.level][b.n] = (h[b.level][b.n] ?? 0) + 1), h), {}),
  // frames from the dive timer starting to the launch; rush: from the count reaching RUSH_COUNT
  dive_gaps: idles.reduce((h, d) => ((h[d.level] ??= {}), (h[d.level][d.rush == null ? d.gap : `rush ${d.rush}`] = (h[d.level][d.rush == null ? d.gap : `rush ${d.rush}`] ?? 0) + 1), h), {}),
  shooter_rows: [...shooterRows].sort(),
  stray_shots: strayShots,
  far_bursts: farBursts,
  banner_frames: bannerFrames,
  drop_steps: merge(drops.map(steps)),
  drop_first_y: [...new Set(drops.filter((d) => d.length).map((d) => d.find((y) => y != null)))],
  drop_unseen: drops.map((d, i) => (d.length && d.every((y) => y == null) ? i : null)).filter((i) => i != null),
  max_bullets_in_flight: Math.max(...captured.map((c) => c.ram.bullets.filter((b) => b.on).length)),
  stars: { missing: starsMissing, moves: starsMoved, twinkled_out: starsHidden },
};

const only = (hist, ok) => Object.keys(hist).every((k) => ok(Number(k)));
const checks = {
  "no dropped frames": report.dropped_frames === 0,
  "no torn or flickering sprites": report.torn_frames === 0,
  "no plot raced the beam": report.beam_races === 0,
  "player moves 1px per frame": only(report.player_steps, (d) => Math.abs(d) <= 1),
  "formation aliens move at most 1px per step": [report.formation_x_steps, report.formation_y_steps].every((h) => only(h, (d) => Math.abs(d) <= 1)),
  "formation aliens move only on their row's frame": only(report.formation_gaps, (g) => g % 4 === 0),
  "formation breathes in and out fully": report.formation_widths[1] - report.formation_widths[0] === 2 * BREATH_MAX,
  "formation breathes up and down fully": (() => {
    // row r moves out vbreath[BREATH_MAX * FORM_COLS + r]: the outer rows most
    const t = report.formation_row_travel;
    return t.every((d, r) => d === 0 || d === Math.abs(vbreath[BREATH_MAX * FORM_COLS + r])) && Math.max(...t) === VBREATH_MAX;
  })(),
  "diver moves at most 2px sideways per frame": only(report.diver_x_steps, (d) => Math.abs(d) <= 2),
  "diver moves at most 2px up or down per frame (or wraps)": only(report.diver_y_steps, (d) => Math.abs(d) <= 2 || d < -100),
  "divers dock back in the formation": report.stranded_frames === 0 && report.docked > 0,
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
  "stars show where RAM says": starsMissing === 0,
  "stars scroll and twinkle": starsMoved > 0 && starsHidden > 0,
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
