# quipu-memory

Thin Python SDK for the Quipu daemon.

```python
from quipu import Quipu

with Quipu.local(db_path="/tmp/quipu.lattice") as q:
    print(q.health()["status"])
```

`Quipu.local()` starts `quipu serve-stdio` today. Socket/HTTP daemon discovery
will replace this as the default transport once those daemon transports land.
