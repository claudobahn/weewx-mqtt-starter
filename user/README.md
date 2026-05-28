# `user/`

Custom Python modules copied into WeeWX's user dir (`./data/bin/user/`) at
first-run bootstrap, then referenced from `station.yaml`'s `services:` block:

```yaml
services:
  prep:    [user.mast_obs.MASTObservations]   # needs user/mast_obs.py here
  data:    []
  restful: []
```

Each `.py` file in this directory is copied verbatim. Module names match the
file names — `user/mast_obs.py` provides `user.mast_obs` to WeeWX.

A typical module exposes a `weewx.engine.StdService` subclass (or registers
unit/obs mappings on import). Example:

```python
# user/mast_obs.py
import weewx.units
from weewx.engine import StdService

weewx.units.obs_group_dict['currentSpeed'] = 'group_speed'
weewx.units.USUnits['group_dbm'] = 'dBm'

class MASTObservations(StdService):
    def __init__(self, engine, config_dict):
        super().__init__(engine, config_dict)
```

**Note:** for simple obs/unit registration, `station.yaml`'s `observations:` /
`units.custom_groups:` block is the easier path — `configure.py` generates
`user/extra_obs.py` for you. Use `user/` only when you need real Python logic
(custom `StdService`, `weewx.xtypes`, etc.).

**One-way copy:** removing a file from `./user/` does NOT remove it from
`./data/bin/user/` (rm by hand or rebuild `./data` to clean up).
