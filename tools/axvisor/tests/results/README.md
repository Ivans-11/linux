# Test result storage

Each case run writes to `.work/logs/`:

- `<case>.log`: streamed QEMU/runner output;
- `<case>.status`: `pass`, `fail`, or `timeout`.

Staged payloads are placed under `.work/cases/<case>/`.

The benchmark's own output is kept in the case log and must remain separate
from outer host/QEMU timing. Only summarized, reviewed benchmark data should be
copied into version-controlled result documents.
