// Targeted test for the capsule: the boss drops a P at every power level. Caught, it gives
// the double shot, then rapid fire, kept across stages. Every hit stops the bullet, scores
// and chimes, and the P falls on. Also checks the other scores.
//
// Each scenario boots galaxa.ssd in jsbeeb, keeps the aliens home (no dives, so no enemy fire),
// sets the power level and, at the top of a main loop, plants the ship's bullet just under the
// boss, then under the capsule, so the game's own hit code shoots them. The ship steers under
// the capsule without firing. The planted bullets were never drawn, so their EOR plots leave
// marks: this checks logic and the wing colour, not sprites (tools/smoothness.mjs does those).
// One scenario clears the formation and holds fire instead, to fill the sky with rapid fire.
// Others launch a lower row's line of three, its members next door or spread along the row, and
// plant a bullet under its members in turn.
// Exits non-zero on any failure.
//
// Usage: node tools/capsule.mjs
//   JSBEEB_DIR defaults to ~/.local/share/jsbeeb
import fs from "node:fs";
import path from "node:path";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const J = process.env.JSBEEB_DIR ?? path.join(process.env.HOME, ".local/share/jsbeeb");

const src = fs.readFileSync(path.join(ROOT, "galaxa.asm"), "utf8");
const zp = {};
for (const m of src.matchAll(/^(\w+)\s*=\s*&([0-9A-F]+)/gm)) zp[m[1]] = parseInt(m[2], 16);
const labels = {};
for (const m of fs.readFileSync(path.join(ROOT, "galaxa.sym"), "utf8").matchAll(/'(\w+)':(\d+)L/g))
  labels[m[1]] = Number(m[2]);
const num = (name) => {
  const expr = src.match(new RegExp(`^${name}\\s*=\\s*([^;\\n]+)`, "m"))[1];
  const js = expr.replace(/\b[A-Z][A-Z0-9_]*\b/g, num);
  if (!/^[\d\s+\-*/()]*$/.test(js)) throw new Error(`${name}: not plain arithmetic: ${expr}`);
  return Function(`return ${js}`)();
};
const BOSS_SLOT = num("BOSS_SLOT"), BULLET_SPEED = num("BULLET_SPEED"), WING_COLOUR = num("WING_COLOUR");
const BULLETS = num("BULLETS");
const DIVE_STRIDE = num("DIVE_STRIDE"), FORM_COLS = num("FORM_COLS"), LAP_ROW = num("LAP_ROW"), LINE_SLOT = LAP_ROW * FORM_COLS + 3, BOTTOM_ROW = (LAP_ROW + 1) * FORM_COLS;
const FORM_SLOTS = num("FORM_SLOTS"), SFX_POWER = num("SFX_POWER"), PS_OVER = num("PS_OVER"), ALIVE_HOME = num("ALIVE_HOME");
const SND_SHOT = num("SND_SHOT");
const WING = [6, 3, 1]; // cyan, yellow, red

const DISC = path.join(ROOT, "galaxa.ssd");
process.chdir(J); // jsbeeb loads its ROMs relative to its own directory
const { TestMachine } = await import(path.join(J, "tests/test-machine.js"));
const { Video } = await import(path.join(J, "src/video.js"));
const utils = await import(path.join(J, "src/utils.js"));
const print = console.log;

async function boot() {
  console.log = () => {}; // jsbeeb is chatty while booting
  const video = new Video(false, new Uint32Array(1024 * 625), () => {});
  const m = new TestMachine("B-DFS1.2", { video });
  m.video = video;
  await m.initialise();
  await m.loadDisc(path.relative(J, DISC));
  await m.runUntilInput();
  m.processor.sysvia.keyDown(utils.keyCodes.SHIFT);
  m.processor.reset(false);
  await m.runFor(2e6 * 0.5);
  m.processor.sysvia.keyUp(utils.keyCodes.SHIFT);
  await m.runUntilInput();
  await m.type(" ");
  console.log = print;
  return m;
}

// power: the level when the boss is shot; shots: bullets planted under the capsule, one at a
// time; last: the boss is the wave's last alien; volley: just hold fire; line: shoot this many of a line;
// slot: the alien that leads it; spare: slots gone first; form: shoot this slot at home;
// carry: clear the stage after the first capsule, then shoot the next one; newGame: lose the game
// with the capsule's points at their top
async function scenario({ power, shots = 0, last = false, volley = false, line = 0, spread = false, slot = null, spare = [], form = null, carry = false, newGame = false }) {
  const m = await boot();
  const rb = (a) => m.readbyte(a), wb = (a, v) => m.writebyte(a, v);
  const keys = { Z: utils.keyCodes.Z, X: utils.keyCodes.X, FIRE: utils.keyCodes.ENTER };
  const out = { dropped: null, hits: [], power: null, wing: null, inFlight: 0, lineScore: null, lineSize: 0, jingle: false, formScore: null, capsule: null, timeout: false };
  let phase = "wait", wave = null, frames = 0, done = false, wing = null, look = 0, planted = 0, held = null, before = null, firing = 0, base = 0, shot = 0, carried = false, typed = false;
  const bcd = (b) => (b >> 4) * 10 + (b & 15);
  const score = () => (bcd(rb(labels.score_hi)) * 100 + bcd(rb(labels.score_lo))) * 10;
  const hold = (k) => {
    if (held === k) return;
    if (held) m.processor.sysvia.keyUp(keys[held]);
    if (k) m.processor.sysvia.keyDown(keys[k]);
    held = k;
  };
  const plant = (x, y) => (wb(labels.bullets_on, 1), wb(labels.bullets_x, x), wb(labels.bullets_y, y));
  const hook = m.processor.debugInstruction.add((addr) => {
    // the palette timer 1 left for the ship's rows last frame (the ULA stores colours inverted)
    if (addr === labels.split_start) wing = m.video.actualPal[WING_COLOUR] ^ 7;
    if (addr === labels.play_sfx && rb(zp.sfx) & SFX_POWER) out.jingle = true;
    if (addr !== labels.main_loop || done) return false;
    if (phase !== "over" && rb(labels.lives) < 2) wb(labels.lives, 3);
    if (!line) wb(zp.dive_timer, 100); // the aliens stay home
    if (++frames > 3000) return (out.timeout = done = true), false;
    if (phase === "over") {
      if (rb(labels.lives) === 3) return (out.capsule = rb(labels.capsule_pts)), (out.power = rb(zp.power)), (phase = "look"), false;
    } else if (phase === "wait") {
      if (!rb(labels.intro) && !rb(labels.player_state) && !rb(labels.bullets_on)) {
        if (newGame) {
          wb(labels.capsule_pts, 8), wb(labels.lives, 0), wb(labels.player_state, PS_OVER);
          return (phase = "over"), false;
        }
        for (const s of spare) wb(labels.alive + s, 0), wb(zp.alive_count, rb(zp.alive_count) - 1);
        if (form === BOSS_SLOT) {
          plant(rb(zp.boss_x) + 2, rb(zp.boss_y) + BULLET_SPEED);
          return (base = score()), (phase = "form"), false;
        }
        if (form !== null) {
          const row = rb(labels.slot_row + form), col = rb(labels.slot_col + form);
          const x = rb(labels.row_x + row) + rb(labels.slot_px + form) + ((rb(labels.breath + rb(labels.row_bofs + row) + col) << 24) >> 24);
          plant((x + 2) & 255, rb(labels.row_y + row) + BULLET_SPEED);
          return (base = score()), (phase = "form"), false;
        }
        if (last || volley) {
          for (let i = 0; i < BOSS_SLOT; i++) wb(labels.alive + i, 0);
          wb(zp.alive_count, 1);
        }
        if (spread) {
          for (const col of [1, 2, 4, 5]) wb(labels.alive + BOTTOM_ROW + col, 0);
          wb(zp.alive_count, rb(zp.alive_count) - 4);
        }
        wb(zp.power, power), (wave = rb(labels.wave));
        if (line) {
          wb(zp.diver_pick, ((slot ?? (spread ? BOTTOM_ROW : LINE_SLOT)) - DIVE_STRIDE + FORM_SLOTS) % FORM_SLOTS);
          wb(zp.dive_timer, 1);
          return (base = score()), (phase = "line"), false;
        }
        if (volley) return hold("FIRE"), (phase = "volley"), false;
        // one move up and its top row meets the boss's
        plant(rb(zp.boss_x) + 2, rb(zp.boss_y) + BULLET_SPEED);
        phase = "boss";
      }
    } else if (phase === "form") {
      if (!rb(labels.alive + form)) return (out.formScore = score() - base), (out.power = rb(zp.power)), (phase = "look"), false;
    } else if (phase === "stage") {
      if (rb(labels.wave) !== wave) phase = "wait";
    } else if (phase === "boss") {
      // the wave's last alien: the next wave's first main loop, its intro over
      if (last) return rb(labels.wave) !== wave && ((out.power = rb(zp.power)), (phase = "look")), false;
      if (rb(labels.alive + BOSS_SLOT)) return false;
      out.dropped = rb(zp.bonus_on) ? "P" : "nothing";
      phase = rb(zp.bonus_on) ? "fall" : "settle";
    } else if (phase === "fall") {
      const on = rb(zp.bonus_on), bx = rb(zp.bonus_x), by = rb(zp.bonus_y);
      if (!on && carry && !carried) {
        carried = true;
        hold(null);
        for (let i = 0; i < BOSS_SLOT; i++) wb(labels.alive + i, 0);
        wb(labels.alive + BOSS_SLOT, ALIVE_HOME), wb(zp.alive_count, 1);
        wave = rb(labels.wave);
        plant(rb(zp.boss_x) + 2, rb(zp.boss_y) + BULLET_SPEED);
        return (phase = "stage"), false;
      }
      if (!on) return hold(null), (out.power = rb(zp.power)), (phase = "look"), false;
      // a planted bullet gone: what the hit scored, sounded and left
      if (before && !rb(labels.bullets_on)) {
        const t = rb(zp.tune_x) - SND_SHOT;
        out.hits.push({ points: score() - before.score, sound: t === 0 || t === 4 ? "chime" : t });
        before = null;
      }
      if (planted < shots && on !== 2 && !before && by < 150 && !(carry && !carried && planted))
        (before = { score: score() }), plant(bx + 2, by + BULLET_SPEED), planted++;
      const d = bx - rb(zp.player_x);
      hold(d > 0 ? "X" : d < 0 ? "Z" : null);
    } else if (phase === "line") {
      if (rb(zp.diver_state) !== 1) return false;
      if (!shot) out.lineSize = 1 + rb(zp.wing_on) + rb(zp.wing_on + 1);
      if (rb(labels.bullets_on)) return false;
      if (shot === line) return (out.lineScore = score() - base), (out.power = rb(zp.power)), (phase = "look"), false;
      const sb = (a) => (rb(a) << 24) >> 24;
      const wing = shot - 1;
      plant((rb(zp.diver_x) + (shot ? sb(zp.wing_ox + wing) : 0) + 2) & 255, (rb(zp.diver_y) + (shot ? sb(zp.wing_oy + wing) : 0) + BULLET_SPEED) & 255);
      shot++;
    } else if (phase === "volley") {
      let n = 0;
      for (let b = 0; b < BULLETS; b++) n += rb(labels.bullets_on + b);
      out.inFlight = Math.max(out.inFlight, n);
      if (++firing === 40) hold(null), (out.power = rb(zp.power)), (phase = "look");
    } else if (phase === "settle") {
      if (frames > 60) out.power = rb(zp.power), (phase = "look");
    } else if (++look === 3) out.wing = wing, (done = true);
    return false;
  });
  while (!done) {
    await m.runFor(40000);
    if (phase === "over" && !typed) {
      typed = true;
      console.log = () => {};
      await m.runUntilInput();
      await m.type(" ");
      console.log = print;
    }
  }
  hook.remove();
  return out;
}

const hits = (...points) => points.map((p) => ({ points: p, sound: "chime" }));
const cases = [
  { name: "single shot: a P; caught, the double shot", power: 0, want: { dropped: "P", hits: [], power: 1 } },
  { name: "single shot: hits score 50, 60, 70 and chime, nothing else", power: 0, shots: 3,
    want: { dropped: "P", hits: hits(50, 60, 70), power: 1 } },
  { name: "double shot: a P; caught, rapid fire", power: 1, want: { dropped: "P", hits: [], power: 2 } },
  { name: "rapid fire: a P; caught, still rapid fire", power: 2, want: { dropped: "P", hits: [], power: 2 } },
  { name: "rapid fire: the P shot five times scores 50, 60, 70, 80, 80", power: 2, shots: 5,
    want: { dropped: "P", hits: hits(50, 60, 70, 80, 80), power: 2 } },
  { name: "the capsule's points carry on into the next stage", power: 0, shots: 2, carry: true,
    want: { dropped: "P", hits: hits(50, 60), power: 1 } },
  { name: "a new game puts the capsule's points back to 50", power: 0, newGame: true, want: { capsule: 5, power: 0 } },
  { name: `rapid fire: ${BULLETS} bullets in flight at once`, power: 2, volley: true, want: { power: 2, inFlight: BULLETS } },
  { name: "row 1 scores 40 at home", power: 0, form: 2, want: { formScore: 40, jingle: false } },
  { name: "row 2 scores 30 at home", power: 0, form: 8, want: { formScore: 30, jingle: false } },
  { name: "row 3 scores 20 at home", power: 0, form: 15, want: { formScore: 20, jingle: false } },
  { name: "row 4 scores 20 at home", power: 0, form: 24, want: { formScore: 20, jingle: false } },
  { name: "the boss scores 100 at home", power: 0, form: BOSS_SLOT, want: { formScore: 100, jingle: false } },
  { name: "row 1 scores 80 diving", power: 0, line: 1, slot: 3, want: { lineScore: 80, jingle: false } },
  { name: "row 2 scores 60 diving", power: 0, line: 1, slot: 8, want: { lineScore: 60, jingle: false } },
  { name: "row 3 scores 40 diving", power: 0, line: 1, slot: 15, want: { lineScore: 40, jingle: false } },
  { name: "row 4 scores 40 diving", power: 0, line: 1, slot: 24, want: { lineScore: 40, jingle: false } },
  { name: "the boss scores 200 diving", power: 0, line: 1, slot: BOSS_SLOT, want: { lineScore: 200, lineSize: 3, jingle: false } },
  { name: "a line of three in row 3 totals 250, with the jingle", power: 0, line: 3,
    want: { lineScore: 250, lineSize: 3, jingle: true } },
  { name: "a line of three in row 4 totals 250, with the jingle", power: 0, line: 3, slot: 24,
    want: { lineScore: 250, lineSize: 3, jingle: true } },
  { name: "a line of three from aliens at columns 0, 3 and 6 of a row", power: 0, line: 3, spread: true,
    want: { lineScore: 250, lineSize: 3, jingle: true } },
  { name: "a line of three: two of it shot, no bonus", power: 0, line: 2, want: { lineScore: 80, jingle: false } },
  { name: "the boss and both guards total 500, with the jingle", power: 0, line: 3, slot: BOSS_SLOT,
    want: { lineScore: 500, lineSize: 3, jingle: true } },
  { name: "the boss and both guards from row 2 still total 500", power: 0, line: 3, slot: BOSS_SLOT, spare: [2, 4],
    want: { lineScore: 500, lineSize: 3, jingle: true } },
  { name: "the boss and one guard shot: no bonus", power: 0, line: 2, slot: BOSS_SLOT, want: { lineScore: 280, jingle: false } },
  { name: "rapid fire is kept at the wave's end", power: 2, last: true, want: { power: 2 } },
  { name: "double shot is kept at the wave's end", power: 1, last: true, want: { power: 1 } },
];
let failed = 0;
for (const c of cases) {
  const r = await scenario(c);
  const ok = !r.timeout && r.wing === WING[r.power] &&
    Object.entries(c.want).every(([k, v]) => JSON.stringify(r[k]) === JSON.stringify(v));
  if (!ok) failed++;
  print(`${ok ? "PASS" : "FAIL"}  ${c.name}${ok ? "" : `  ${JSON.stringify(r)}`}`);
}
process.exit(failed ? 1 : 0);
