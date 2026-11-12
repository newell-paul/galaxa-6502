// The browser page's emulator: jsbeeb's BBC Micro, booting galaxa.ssd, drawn as the bare
// screen. Keys reach the BBC as they are; the touch buttons press Z, X and Return.
// Built into web/ by tools/web/build.mjs. jsbeeb is GPL-3.0, so this bundle is too.
import { Cpu6502 } from "jsbeeb/6502.js";
import { findModel } from "jsbeeb/models.js";
import { Video } from "jsbeeb/video.js";
import { Canvas } from "jsbeeb/canvas.js";
import { Cmos } from "jsbeeb/cmos.js";
import * as fdc from "jsbeeb/fdc.js";
import * as utils from "jsbeeb/utils.js";
import { AudioHandler } from "jsbeeb/web/audio-handler.js";

const ROMS = "https://bbc.xania.org/"; // not ours to publish: jsbeeb's site serves them, CORS open
const DISC = "galaxa.ssd";
const KEYS = { left: 90, right: 88, fire: 13 }; // Z, X, Return
const SHIFT = 16;
const CLOCK = 2e6;
const MIN_HOLD = 60; // ms
// The MODE 2 screen in jsbeeb's 1024x625 frame: 160x256 pixels, 4x2 each
const CROP = { x: 200, y: 64, w: 640, h: 512 };

const screen = document.getElementById("screen");
screen.width = CROP.w;
screen.height = CROP.h;
const canvas = new Canvas(screen);
const video = new Video(false, canvas.fb32, () =>
  canvas.paint(CROP.x, CROP.y, CROP.x + CROP.w, CROP.y + CROP.h),
);

const quiet = { toggle() {}, html() {}, on() {}, fadeIn() {}, fadeOut() {} }; // jsbeeb's audio warning, not shown here
const audio = new AudioHandler(quiet, document.createElement("canvas"), 7000, 5, true);
const resumeAudio = () => audio.tryResume().catch(() => {});

utils.setBaseUrl(ROMS);
const cpu = new Cpu6502(findModel("B-DFS1.2"), { setCpu() {} }, video, audio.soundChip, audio.ddNoise, null,
  new Cmos(), {});

const held = new Map(); // a key held by more than one source stays down until all let go
function press(code) {
  held.set(code, (held.get(code) ?? 0) + 1);
  if (held.get(code) === 1) cpu.sysvia.keyDown(code, false);
}
function release(code) {
  const n = (held.get(code) ?? 0) - 1;
  if (n > 0) return void held.set(code, n);
  held.delete(code);
  cpu.sysvia.keyUp(code);
}

window.addEventListener("keydown", (e) => {
  if (e.metaKey || e.ctrlKey || e.altKey || e.key === "Escape" || e.key === "F11") return;
  e.preventDefault();
  resumeAudio();
  if (!e.repeat) press(e.keyCode);
});
window.addEventListener("keyup", (e) => {
  if (!held.has(e.keyCode)) return;
  e.preventDefault();
  release(e.keyCode);
});
window.addEventListener("blur", () => [...held.keys()].forEach((code) => {
  held.set(code, 1);
  release(code);
}));

for (const button of document.querySelectorAll("[data-key]")) {
  const code = KEYS[button.dataset.key];
  const down = new Set();
  let since = 0, letGo = 0;
  button.addEventListener("pointerdown", (e) => {
    e.preventDefault();
    resumeAudio();
    button.setPointerCapture(e.pointerId);
    if (!down.size) {
      if (letGo) clearTimeout(letGo), (letGo = 0);
      else press(code), (since = performance.now());
      button.classList.add("down");
    }
    down.add(e.pointerId);
  });
  // the game reads the keyboard once a frame: a quick tap stays down for 3 frames
  const up = (e) => {
    if (!down.delete(e.pointerId) || down.size) return;
    button.classList.remove("down");
    letGo = setTimeout(() => (letGo = 0, release(code)), Math.max(0, since + MIN_HOLD - performance.now()));
  };
  button.addEventListener("pointerup", up);
  button.addEventListener("pointercancel", up);
  button.addEventListener("contextmenu", (e) => e.preventDefault());
}
screen.addEventListener("pointerdown", resumeAudio);

// The score table outlives the page: the game keeps its 5 names and scores as one run of
// bytes, found here by the table the disc ships with, and patched into the disc before it boots.
const SCORES = "galaxa.scores";
const SEED = [...[..."LDASTAJMPRTSBRK"].map((c) => c.charCodeAt(0)), 5, 0, 0, 4, 0, 0, 3, 0, 0, 2, 0, 0, 1, 0, 0];
const find = (at, want, from, to) => {
  for (let i = from; i + want.length <= to; i++) if (want.every((b, k) => at(i + k) === b)) return i;
  return -1;
};
const valid = (t) => Array.isArray(t) && t.length === SEED.length && t.every((b, i) =>
  i < 15 ? b === 45 || (b >= 65 && b <= 90) : Number.isInteger(b) && (b & 15) < 10 && b >> 4 < 10);
function savedScores() {
  try {
    const t = JSON.parse(localStorage.getItem(SCORES));
    return valid(t) ? t : null;
  } catch {
    return null;
  }
}
function keepScores(table) {
  let ram = -1;
  setInterval(() => {
    if (ram < 0) return void (ram = find((a) => cpu.readmem(a), table, 0x400, 0x800)); // once the loader has run
    const now = SEED.map((_, i) => cpu.readmem(ram + i));
    if (!valid(now) || now.every((b, i) => b === table[i])) return;
    table = now;
    try {
      localStorage.setItem(SCORES, JSON.stringify(now));
    } catch {} // private browsing: the table lasts the visit
  }, 1000);
}

let last = 0;
function frame(now) {
  requestAnimationFrame(frame);
  audio.soundChip.catchUp();
  if (last) cpu.execute(Math.min(((now - last) * CLOCK) / 1000, CLOCK / 10) | 0);
  last = now;
}

async function boot() {
  await cpu.initialise();
  const data = new Uint8Array(await (await fetch(DISC)).arrayBuffer());
  const saved = savedScores(), at = find((i) => data[i], SEED, 0, data.length);
  if (saved && at >= 0) data.set(saved, at);
  if (at >= 0) keepScores(saved ?? SEED);
  cpu.fdc.loadDisc(0, fdc.discFor(cpu.fdc, DISC, data));
  cpu.sysvia.keyDown(SHIFT, true); // SHIFT held from power on: the disc boots
  setTimeout(() => cpu.sysvia.keyUp(SHIFT), 1000);
  requestAnimationFrame(frame);
  document.body.classList.add("running");
}

boot().catch((e) => {
  document.getElementById("status").textContent = `Couldn't start the emulator: ${e.message}`;
  throw e;
});
