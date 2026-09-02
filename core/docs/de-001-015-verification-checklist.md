# DE-001..015 Mac evidence checklist

Run:

```sh
bash core/scripts/verify-de-mac.sh
```

The timestamped artifact directory contains `results.tsv`, `interactions.tsv`,
harness logs, and these QMP screenshots:

- `00-before-runner-interactions.png` — idle glass desktop baseline.
- `01-after-pointer-sweep.png` — pointer restore, wallpaper, and frame pacing.
- `02-after-menu-open.png`, `03-after-menu-action.png` — overlay/menu paint and restore.
- `04-after-app-launch.png` — dock/island, FILES card, icon and title chrome.
- `05-after-title-drag.png`, `06-after-corner-resize.png` — moved/resized card and clean vacated damage.
- `07-after-window-minimise.png` — implemented window control and restored background.
- `08-final-visible.png` — final state; the live QEMU door remains open.

Evidence to inspect:

- [ ] **DE-001** — `de-desk`, `de-session`, `de-chrome-cache`; screenshots 00/04 show wallpaper through glass corners with no black halo.
- [ ] **DE-002** — `de-session`, `de-chrome`; screenshots 00/04 show symmetric, softly antialiased rounded edges.
- [ ] **DE-003** — `de-pace`; screenshot 01 has no pointer trails, teal residue, or row warp.
- [ ] **DE-004** — `de-deskboot`, `de-desk`, `de-session`; screenshot 00 has one dock and no legacy Start strip.
- [ ] **DE-005** — `de-wm`, `de-pace`; screenshot 05 shows a clean title drag and fully restored old location.
- [ ] **DE-006** — `de-resize`, `de-chrome-cache`; screenshot 06 shows preserved chrome and a clean vacated resize region.
- [ ] **DE-007** — `de-desk`, `de-retain`; screenshots 00/04 show complete frosted dock tips without black bars or orphan arcs.
- [ ] **DE-008** — `de-desk`, `de-wall`; screenshots 00/04 show frosted island bodies and transparent rounded exteriors.
- [ ] **DE-009** — `de-panel`, `de-session`; screenshots 00/04 show aligned island borders/text and no black edge pixels.
- [ ] **DE-010** — `de-desk`, `de-osxui`; screenshot 04 shows readable, padded, softly antialiased dock glyphs.
- [ ] **DE-011** — `de-pace`, `de-wall`, `de-desk`; screenshots 00/01 show smooth ordered-dither wallpaper without bands.
- [ ] **DE-012** — `de-pace`, `de-chrome-cache`; interaction screenshots complete without visible whole-OS hitches.
- [ ] **DE-013** — sit-in `--abs`; screenshot 01 plus the visible door show one accurately mapped cursor.
- [ ] **DE-014** — `de-retain`, `de-chrome-cache`; screenshots 02/03 show the wall menu and a clean post-action restore.
- [ ] **DE-015** — `de-chrome`, `de-session`, `de-osxui`; screenshots 04/05 show pearl gradients, soft shadows, and circular controls.

`interactions.tsv` marks maximise as `SKIP`: the current display protocol
explicitly has no maximise command. It does not fabricate evidence for an
operation the compositor does not implement; minimise is exercised instead.
