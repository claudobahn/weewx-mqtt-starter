# `branding/`

User-provided files copied into the fuzzy-archer skin at first-run bootstrap.
Reference them from `station.yaml`'s `branding:` block:

```yaml
branding:
  site_name: "Your Org"           # informational; for your own HTML to reference
  site_url:  "https://example.org"
  logo:                logo.png                # -> skins/Bootstrap/images/logo.png
  about_page:          about.html.tmpl         # -> skins/Bootstrap/about.html.tmpl
  nav_fragment:        nav.html.inc            # -> skins/Bootstrap/nav.html.inc
  footer_fragment:     foot.html.inc           # -> skins/Bootstrap/foot.html.inc
  livegauges_fragment: livegauges.html.inc     # -> skins/Bootstrap/livegauges.html.inc
  images:                                       # any number of extras
    - deployment.jpg
    - team.png
```

Paths are relative to this directory. The optional `branding/` prefix
(e.g. `logo: branding/logo.png`) is also accepted — both work.

**Re-runs of `configure.py` overwrite the same target paths.** Removing a key
from `station.yaml` does NOT restore the skin's original file (the upstream
copy in `./data/skins/Bootstrap/` was overwritten). To revert, delete the file
in `./data/skins/Bootstrap/` and let a fresh `./data` re-seed it from
`/opt/station` in the image (or rebuild `./data` entirely).
