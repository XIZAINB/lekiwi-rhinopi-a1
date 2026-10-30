"""极简 config/env 读取器（K=V，支持 # 注释、引号、$VAR 展开）。

不引入 python-dotenv：整个仓库只需要读一份 k=v 文件，多一个依赖不值得。
同名环境变量优先级最高，方便临时覆盖，例如：
    ROBOT_PORT=/dev/ttyACM1 python scripts/a1_host.py
"""

from __future__ import annotations

import os
from pathlib import Path


def repo_root() -> Path:
    """仓库根目录（本文件在 <repo>/scripts/ 下）。"""
    return Path(__file__).resolve().parent.parent


def load_env(path: Path | None = None) -> dict[str, str]:
    """读取 config/env；文件不存在时返回空字典并向 stderr 提示。"""
    env_path = Path(path) if path else repo_root() / "config" / "env"
    data: dict[str, str] = {}
    if not env_path.is_file():
        print(f"[!] 未找到 {env_path}，使用默认值。先执行: cp config/env.example config/env")
        return data

    for raw in env_path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        data[key] = value
    return data


_ENV: dict[str, str] | None = None


def cfg(key: str, default: str = "") -> str:
    """取配置：环境变量 > config/env > default。"""
    global _ENV
    if _ENV is None:
        _ENV = load_env()
    if key in os.environ and os.environ[key] != "":
        return os.environ[key]
    value = _ENV.get(key, default)
    return os.path.expanduser(os.path.expandvars(value)) if value else value


def cfg_int(key: str, default: int) -> int:
    raw = cfg(key, str(default))
    try:
        return int(raw)
    except ValueError:
        print(f"[!] {key}={raw!r} 不是整数，改用 {default}")
        return default


def cfg_optional(key: str) -> str | None:
    """空字符串视为未配置。"""
    value = cfg(key, "").strip()
    return value or None
