# `branding/` (sailing-center)

User-provided files copied into the fuzzy-archer skin at first-run bootstrap.
This branch ships an MCSC-themed set: logo, nav, footer, about page, and a
live-gauges fragment that includes the AOS composite radar loop.

Reference them from `station.yaml`'s `branding:` block:

```yaml
branding:
  site_name: "MCSC"
  site_url:  "https://www.sailingcenter.org"
  images:
    - images/mcsc_2023_logo_629x104.png
  fragments:
    - nav.html.inc
    - foot.html.inc
    - livegauges.html.inc
    - about.html.tmpl
    - radar.html.inc
```

`fragments:` is one uniform list for every HTML/template partial, copied
verbatim to the skin root (`skins/Bootstrap/`) by basename. It covers both the
skin's own override points (`nav.html.inc`, `foot.html.inc`,
`livegauges.html.inc`, the generated `about.html.tmpl`) and extra partials that
another fragment `#include`s — here `radar.html.inc`, which
`livegauges.html.inc` pulls in with `#include "radar.html.inc"`. Each basename
must match exactly what the skin references; nothing is renamed.

Paths are relative to this directory. The optional `branding/` prefix
(e.g. `logo: branding/logo.png`) is also accepted — both work.

## What each file does

- **`nav.html.inc`** — top navbar. Brand text is "Weather at MCSC", linking
  to the dashboard root; logo at right links to sailingcenter.org. Nav items
  come from `dashboard.navigation` in `station.yaml`.
- **`foot.html.inc`** — page footer with "Powered by" + MCSC logo link.
- **`about.html.tmpl`** — full About page describing the data pipeline
  (OMG → Mosquitto → WeeWX → fuzzy-archer) and pointing at the source repo.
- **`livegauges.html.inc`** — gauge column. Identical structure to the v4.4
  default (so the JS-driven gauges still render from `[LiveGauges]`), with an
  `#include "radar.html.inc"` between the gauges and the station-info table.
- **`radar.html.inc`** — the AOS composite radar loop, broken out as its own
  partial. Copied to the skin root via `branding.fragments` (above) so the
  `#include` from `livegauges.html.inc` resolves.
- **`images/mcsc_2023_logo_629x104.png`** — site logo (used by nav + footer).

## About the radar widget

Same image source as the live MCSC site (UW-Madison AOS composite,
`tempest.aos.wisc.edu/radar/wi3comp{01..20}.gif`, cycled every 250 ms for a
~5-second loop). The original site uses AngularJS 1.5 to drive the cycle; we
replace it with vanilla JS — same visual behavior, no framework dependency.
Hardcoded for the Milwaukee region; another deployment can swap the image
URLs in this file.

The frames are mounted as 20 stacked `<img>` elements (one per frame) with
visibility cycled via `display:block`/`display:none` — once loaded, their
decoded pixels stay resident, so the animation itself fires zero network
requests. The full set is re-fetched every 6 minutes (cache-busted) to pick
up new radar scans — matches AOS's scan cadence observed in the gifs'
`Last-Modified` timestamps. The naive `img.src = ...` approach revalidates
each frame against the server on every cycle (AOS sends no `Cache-Control`
/ `Expires`, so browsers fall back to heuristic freshness of ~12 minutes);
at 4 fps that's ~80 conditional requests per second per open dashboard.

## Re-runs

`configure.py` is idempotent — it overwrites the same target paths in
`skins/Bootstrap/` on every run. Removing a key from `station.yaml` does NOT
restore the skin's original file; to revert, delete the file in
`./data/skins/Bootstrap/` and let a fresh `./data` re-seed it from
`/opt/station` in the image (or rebuild `./data` entirely).
