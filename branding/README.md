# `branding/`

User-provided files copied into the fuzzy-archer skin at first-run bootstrap.
Reference them from `station.yaml`'s `branding:` block:

```yaml
branding:
  site_name: "Your Org"           # informational; for your own HTML to reference
  site_url:  "https://example.org"
  logo:    logo.png                # -> skins/Bootstrap/images/logo.png
  images:                          # any number of extra image assets
    - deployment.jpg               #   -> skins/Bootstrap/images/<name>
    - team.png
  fragments:                       # HTML/template partials -> skins/Bootstrap/<name>
    - nav.html.inc                 #   override the skin's nav
    - foot.html.inc                #   override the skin's footer
    - livegauges.html.inc          #   override the gauge column
    - about.html.tmpl              #   override the generated About page
    - radar.html.inc               #   extra partial #include'd by another fragment
```

Two kinds of files, two keys:

- **`logo:` / `images:`** — binary assets, copied into the skin's `images/`
  subdirectory.
- **`fragments:`** — every HTML/template partial, copied to the skin root by
  name. This is **one uniform mechanism** for both *overriding* a skin file the
  skin already references (`nav.html.inc`, `foot.html.inc`,
  `livegauges.html.inc`, the generated `about.html.tmpl`) and *adding* a new
  partial that another fragment `#include`s (e.g. a radar widget lifted out of
  `livegauges.html.inc` into its own `radar.html.inc`, keeping the livegauges
  override close to the stock skin). Nothing is renamed — each file's basename
  must match exactly what the skin `#include`s or what `skin.conf` names as a
  generated page.

Paths are relative to this directory. The optional `branding/` prefix
(e.g. `logo: branding/logo.png`) is also accepted — both work.

**Re-runs of `configure.py` overwrite the same target paths.** Removing a key
from `station.yaml` does NOT restore the skin's original file (the upstream
copy in `./data/skins/Bootstrap/` was overwritten). To revert, delete the file
in `./data/skins/Bootstrap/` and let a fresh `./data` re-seed it from
`/opt/station` in the image (or rebuild `./data` entirely).
