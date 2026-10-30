"""只读测差：等价于 `align_leader_to_follower.py --dry-run`。

保留这个入口只为排障时手感更直接：
    python scripts/measure_offset_once.py
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from align_leader_to_follower import main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(main(["--dry-run"]))
