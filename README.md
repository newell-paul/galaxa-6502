# Galaxa (BBC Micro)

An original fixed shooter for the BBC Micro Model B, written in 6502 assembly in 2026.
MODE 2, eight colours, 50 frames a second.

## Play in the browser

**https://newell-paul.github.io/galaxa-6502/**

Click the screen, then press any key to start.

| Key | Action |
|-----|--------|
| <kbd>Z</kbd> | Left |
| <kbd>X</kbd> | Right |
| <kbd>Return</kbd> | Fire |

## How it plays

- Aliens wait in formation and peel off to dive at you. The boss dives with two guards.
- Shoot the boss and it drops a **P** capsule. Catch it to power up: double shot, then
  rapid fire. Your ship's wings show the level (cyan, yellow, red). You keep it until you
  lose a ship.
- Every hit on a falling capsule scores 100, so with rapid fire it pays to shoot the boss
  high up and keep the capsule in the air.
- Three ships. Each new stage adds a bonus.

| Target | Points |
|--------|--------|
| Alien in formation | 10 |
| Diving alien | 50 |
| Capsule hit | 100 |
| Reaching stage N (from 2) | N × 500 |

## Build and run

Needs [BeebASM](https://github.com/stardot/beebasm) and Node.js.

```bash
make              # build galaxa.ssd
make run          # build, then open it in a local jsbeeb
make run-debug    # debug build: P cycles the power level
```

Or load `galaxa.ssd` in any BBC Micro emulator and press Shift+Break.

## Tests

`make test` runs the game headless in [jsbeeb](https://github.com/mattgodbolt/jsbeeb)
and checks it frame by frame: sprites where RAM says, no tearing, no dropped frames, and
the capsule rules. It expects a jsbeeb checkout at `~/.local/share/jsbeeb` (set
`JSBEEB_DIR` to use another).

## Files

| File | What it is |
|------|------------|
| `galaxa.asm` | The game |
| `tools/title.mjs` | Builds the MODE 7 title screen |
| `tools/smoothness.mjs` | Frame-by-frame smoothness test |
| `tools/capsule.mjs` | Capsule and power-up test |
| `!BOOT` | Disc boot file |
| `Makefile` | Build, run and test |

## Licence

© 2026 Paul Newell. Released under the MIT licence; see [`LICENSE`](./LICENSE).
