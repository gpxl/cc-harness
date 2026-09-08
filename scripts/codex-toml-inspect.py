#!/usr/bin/env python3
"""Minimal semantic inspection for native Codex TOML (Python 3.11+)."""

import sys
import tomllib
from pathlib import Path


def load(path_text: str) -> dict:
    path = Path(path_text)
    try:
        with path.open("rb") as handle:
            data = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise ValueError(f"cannot parse {path}: {error}") from error
    if not isinstance(data, dict):
        raise ValueError(f"cannot inspect {path}: TOML root is not a table")
    return data


def role_name(path_text: str) -> None:
    value = load(path_text).get("name")
    if not isinstance(value, str) or not value:
        raise ValueError(f"cannot inspect {path_text}: missing nonempty string name")
    print(value)


def routing_defaults(path_text: str) -> None:
    agents = load(path_text).get("agents", {})
    if not isinstance(agents, dict):
        raise ValueError(f"cannot inspect {path_text}: agents is not a table")
    for key in ("default_subagent_model", "default_subagent_reasoning_effort"):
        if key in agents:
            print(key)


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[1] not in {"role-name", "routing-defaults"}:
        print("Usage: codex-toml-inspect.py {role-name|routing-defaults} <path>", file=sys.stderr)
        return 2
    try:
        if sys.argv[1] == "role-name":
            role_name(sys.argv[2])
        else:
            routing_defaults(sys.argv[2])
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
