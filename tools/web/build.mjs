// Builds web/ for the browser page: tools/web/play.js bundled with jsbeeb, jsbeeb's
// licence beside it, and the home-screen icons drawn from the boss sprite.
// Run: node tools/web/build.mjs
//   JSBEEB_DIR defaults to ~/.local/share/jsbeeb
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../..");
const J = process.env.JSBEEB_DIR ?? path.join(process.env.HOME, ".local/share/jsbeeb");
const OUT = path.join(ROOT, "web");
const req = createRequire(path.join(J, "package.json"));
const { build } = await import(pathToFileURL(req.resolve("vite")).href);
const { firShaderPlugin } = await import(pathToFileURL(path.join(J, "tools/vite-plugin-fir-shader.js")).href);
const sharp = (await import(pathToFileURL(req.resolve("sharp")).href)).default;

await build({
  configFile: false,
  root: path.join(ROOT, "tools/web"),
  base: "./",
  publicDir: false,
  logLevel: "warn",
  plugins: [firShaderPlugin()],
  resolve: { alias: { jsbeeb: path.join(J, "src") } },
  build: {
    outDir: OUT,
    emptyOutDir: true,
    assetsInlineLimit: 0, // jsbeeb's audio worklets must stay files
    chunkSizeWarningLimit: 2000,
    rollupOptions: {
      input: path.join(ROOT, "tools/web/play.js"),
      output: { entryFileNames: "galaxa-web.js", chunkFileNames: "[name].js", assetFileNames: "[name][extname]" },
    },
  },
});

const commit = execFileSync("git", ["rev-parse", "HEAD"], { cwd: J }).toString().trim();
fs.copyFileSync(path.join(J, "COPYING"), path.join(OUT, "LICENSE-jsbeeb.txt"));
fs.writeFileSync(path.join(OUT, "README.txt"), [
  "galaxa-web.js and its worklets bundle jsbeeb (https://github.com/mattgodbolt/jsbeeb),",
  `commit ${commit}, licensed under the GPL version 3 or later: see LICENSE-jsbeeb.txt.`,
  "The rest of the bundle's source is tools/web/play.js in this repository.",
  "The BBC ROMs are not included: the page loads them from https://bbc.xania.org/.",
  "",
].join("\n"));

// the boss on black, MODE 2's wide pixels kept 2:1
const src = fs.readFileSync(path.join(ROOT, "galaxa.asm"), "utf8");
const art = src.match(/^ART_BOSS\s*=\s*(.+)$/m)[1].match(/"(\d+)"/g).map((s) => s.slice(1, -1));
const bossPhys = Number(src.match(/^BOSS_PHYS\s*=\s*(\d+)/m)[1]);
const rgb = (c) => [c & 1 ? 255 : 0, c & 2 ? 255 : 0, c & 4 ? 255 : 0];
for (const size of [180, 192, 512]) {
  const px = Math.floor((size * 0.7) / (art[0].length * 2)), w = art[0].length * 2 * px, h = art.length * px;
  const img = Buffer.alloc(size * size * 3);
  art.forEach((row, y) => [...row].forEach((ch, x) => {
    const c = Number(ch) === 3 ? bossPhys : Number(ch);
    if (!c) return;
    for (let dy = 0; dy < px; dy++) for (let dx = 0; dx < 2 * px; dx++) {
      const o = (((size - h) >> 1) + y * px + dy) * size + ((size - w) >> 1) + x * 2 * px + dx;
      img.set(rgb(c), o * 3);
    }
  }));
  await sharp(img, { raw: { width: size, height: size, channels: 3 } }).png().toFile(path.join(OUT, `icon-${size}.png`));
}
console.log(`web/: built with jsbeeb ${commit.slice(0, 7)}`);
