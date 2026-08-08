import json
import os
import re
from pathlib import Path
from typing import Any

def _env_path() -> Path:
    env = os.getenv("FREEBUFF2API_ENV_PATH")
    if env:
        return Path(env)
    # default: freebuff2api project root .env
    return Path(__file__).resolve().parent.parent.parent / ".env"

def _accounts_json_path() -> Path:
    env = os.getenv("FREEBUFF2API_DATA_DIR")
    if env:
        return Path(env) / "accounts.json"
    return Path(__file__).resolve().parent.parent.parent.parent / ".freebuff2api" / "accounts.json"

def load_env() -> dict[str, str]:
    env_file = _env_path()
    result: dict[str, str] = {}
    if not env_file.exists():
        return result
    with open(env_file, "r", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n\r")
            if line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            result[key.strip()] = value.strip()
    return result

def save_env(data: dict[str, str]) -> None:
    env_file = _env_path()
    env_file.parent.mkdir(parents=True, exist_ok=True)

    existing: dict[str, str] = {}
    comments: list[str] = []
    if env_file.exists():
        with open(env_file, "r", encoding="utf-8") as f:
            for line in f:
                line_raw = line.rstrip("\n\r")
                if line_raw.startswith("#") or "=" not in line_raw:
                    comments.append(line_raw)
                    continue
                key, value = line_raw.split("=", 1)
                existing[key.strip()] = value.strip()

    merged = {**existing, **data}
    # clean empty keys
    merged = {k: v for k, v in merged.items() if v is not None}

    lines: list[str] = []
    written_keys: set[str] = set()

    # write known keys in logical order
    order = [
        "FREEBUFF_TOKEN",
        "FREEBUFF_API_BASE_URL",
        "FREEBUFF_AD_PROVIDERS",
        "FREEBUFF_TIMEOUT",
        "FREEBUFF_PROXY_ENABLED",
        "FREEBUFF_PROXY_URL",
        "FREEBUFF_DEBUG",
        "FREEBUFF_LOG_LEVEL",
        "FREEBUFF_LOG_BODY_CHARS",
        "FREEBUFF_LOG_COLOR",
        "FREEBUFF_HOST",
        "FREEBUFF_PORT",
        "FREEBUFF_TIMEZONE",
        "FREEBUFF_LOCALE",
        "FREEBUFF_OS",
    ]
    for key in order:
        if key in merged:
            lines.append(f"{key}={merged[key]}")
            written_keys.add(key)

    # append any other keys not in order
    for key, value in sorted(merged.items()):
        if key not in written_keys:
            lines.append(f"{key}={value}")

    with open(env_file, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

def _load_accounts_meta() -> dict[str, dict[str, Any]]:
    path = _accounts_json_path()
    if not path.exists():
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, list):
            return {a["token"]: a for a in data if a.get("token")}
        if isinstance(data, dict):
            return data
        return {}
    except Exception:
        return {}

def _save_accounts_meta(meta: dict[str, dict[str, Any]]) -> None:
    path = _accounts_json_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)

def parse_accounts(env_data: dict[str, str]) -> list[dict[str, Any]]:
    raw = env_data.get("FREEBUFF_TOKEN", "")
    if not raw:
        return []
    tokens = [t.strip() for t in raw.split(",") if t.strip()]
    meta = _load_accounts_meta()
    result = []
    for i, t in enumerate(tokens):
        m = meta.get(t, {})
        label = m.get("label", "")
        if not label:
            label = f"账号 {i+1}"
        result.append({"id": i, "token": t, "label": label, "active": m.get("active", True)})
    return result

def build_accounts_env(accounts: list[dict[str, Any]]) -> str:
    tokens = [a["token"] for a in accounts if a.get("token")]
    meta = {}
    for i, a in enumerate(accounts):
        if a.get("token"):
            label = a.get("label", "")
            if not label:
                label = f"账号 {i+1}"
            meta[a["token"]] = {
                "token": a["token"],
                "label": label,
                "active": a.get("active", True),
            }
    _save_accounts_meta(meta)
    return ",".join(tokens)
