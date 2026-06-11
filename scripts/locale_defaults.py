#!/usr/bin/env python3
"""Detect conversation locale and resolve installer defaults."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

VIETNAMESE_RE = re.compile(
    r"["
    r"\u00C0-\u00C3\u00C8-\u00CA\u00CC-\u00CD\u00D2-\u00D5\u00D9-\u00DA"
    r"\u00DD\u0102\u0103\u0110\u0111\u0128\u0129\u0168\u0169\u01A0\u01A1"
    r"\u01AF\u01B0\u1EA0-\u1EF9"
    r"]",
    re.UNICODE,
)
USER_QUERY_RE = re.compile(r"<user_query>\s*(.*?)\s*</user_query>", re.DOTALL | re.IGNORECASE)
SKIP_PREFIXES = (
    "<environment_context>",
    "<permissions",
    "<app-context>",
    "<collaboration_mode>",
    "<skills_instructions>",
    "<plugins_instructions>",
)

MAX_FILES = 40
MAX_BYTES = 512_000


def home_dir() -> Path:
    return Path.home()


def cursor_transcript_globs() -> list[Path]:
    root = home_dir() / ".cursor" / "projects"
    if not root.is_dir():
        return []
    return sorted(root.glob("*/agent-transcripts/**/*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)


def codex_transcript_globs() -> list[Path]:
    import os

    codex_home = home_dir() / ".codex"
    roots = [codex_home]
    env_home = os.environ.get("CODEX_HOME", "").strip()
    if env_home:
        env_path = Path(env_home)
        if env_path not in roots:
            roots.append(env_path)
    files: list[Path] = []
    for root in roots:
        sessions = root / "sessions"
        if sessions.is_dir():
            files.extend(sessions.glob("**/*.jsonl"))
    return sorted(files, key=lambda p: p.stat().st_mtime, reverse=True)


def normalize_user_text(text: str) -> str:
    match = USER_QUERY_RE.search(text)
    if match:
        return match.group(1).strip()
    return text.strip()


def should_skip_text(text: str) -> bool:
    stripped = text.strip()
    if not stripped:
        return True
    lowered = stripped.lower()
    return any(lowered.startswith(prefix.lower()) for prefix in SKIP_PREFIXES)


def contains_vietnamese(text: str) -> bool:
    return bool(VIETNAMESE_RE.search(text))


def extract_cursor_line(line: str) -> str:
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        return ""
    role = obj.get("role")
    if role not in ("user", "assistant"):
        return ""
    message = obj.get("message") or {}
    parts = message.get("content") or []
    chunks: list[str] = []
    for part in parts:
        if part.get("type") != "text":
            continue
        text = str(part.get("text") or "")
        if should_skip_text(text):
            continue
        chunks.append(normalize_user_text(text))
    return "\n".join(chunks)


def extract_codex_line(line: str) -> str:
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        return ""
    if obj.get("type") != "response_item":
        return ""
    payload = obj.get("payload") or {}
    if payload.get("type") != "message":
        return ""
    role = payload.get("role")
    if role not in ("user", "assistant"):
        return ""
    parts = payload.get("content") or []
    chunks: list[str] = []
    for part in parts:
        part_type = part.get("type")
        if part_type not in ("input_text", "output_text", "text"):
            continue
        text = str(part.get("text") or "")
        if should_skip_text(text):
            continue
        chunks.append(normalize_user_text(text))
    return "\n".join(chunks)


def scan_files(files: list[Path]) -> tuple[bool, int]:
    found_vietnamese = False
    sampled_bytes = 0
    for path in files[:MAX_FILES]:
        if sampled_bytes >= MAX_BYTES:
            break
        try:
            with path.open("r", encoding="utf-8", errors="ignore") as handle:
                for line in handle:
                    if sampled_bytes >= MAX_BYTES:
                        break
                    text = extract_cursor_line(line)
                    if not text:
                        text = extract_codex_line(line)
                    if not text:
                        continue
                    sampled_bytes += len(text.encode("utf-8", errors="ignore"))
                    if contains_vietnamese(text):
                        return True, sampled_bytes
        except OSError:
            continue
    return found_vietnamese, sampled_bytes


def detect_locale() -> str:
    files = cursor_transcript_globs() + codex_transcript_globs()
    if not files:
        return "en"
    found_vi, _ = scan_files(files)
    return "vi" if found_vi else "en"


def load_config(config_path: Path) -> dict[str, Any]:
    return json.loads(config_path.read_text(encoding="utf-8"))


def resolve_defaults(config_path: Path, locale: str | None = None) -> dict[str, Any]:
    config = load_config(config_path)
    chosen = locale or detect_locale()
    if chosen not in config.get("locales", {}):
        chosen = "en"
    locale_config = config["locales"][chosen]
    return {
        "locale": chosen,
        "keywords": list(locale_config.get("keywords") or []),
        "continue_message": str(locale_config.get("continue_message") or "Continue"),
        "tail_length": int(config.get("tail_length", 1000)),
        "max_continue_loops": int(config.get("max_continue_loops", 10)),
    }


def main() -> int:
    if len(sys.argv) < 2:
        print(detect_locale())
        return 0

    command = sys.argv[1]
    if command == "detect":
        print(detect_locale())
        return 0

    if command == "resolve":
        config_path = Path(sys.argv[3] if len(sys.argv) > 3 else "config.defaults.json")
        locale_arg = sys.argv[2] if len(sys.argv) > 2 else "auto"
        locale = detect_locale() if locale_arg == "auto" else locale_arg
        resolved = resolve_defaults(config_path, locale)
        output = json.dumps(resolved, ensure_ascii=False, indent=2) + "\n"
        sys.stdout.buffer.write(output.encode("utf-8"))
        return 0

    print(f"Unknown command: {command}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
