#!/usr/bin/env python3
"""Safely mutate Claude project settings JSON for IDC plugin enablement.

The settings file is operator-owned. This helper changes only one key under
`enabledPlugins`, preserves every other JSON key, and writes through a same-directory temp
file + atomic replace so failed reads/writes never truncate the original file.
"""
from __future__ import annotations

import json
import os
import stat
import sys
import tempfile
from typing import Any


USAGE = """Usage: idc_settings_json.py <enable|disable> <settings.json> <plugin-name>

Examples:
  idc_settings_json.py enable .claude/settings.json idc@idc-workflow
  idc_settings_json.py disable .claude/settings.json idc@idc-workflow
"""


def die(message: str, code: int = 2) -> None:
    print(f"idc-settings-json: {message}", file=sys.stderr)
    raise SystemExit(code)


def load_settings(path: str, action: str) -> dict[str, Any] | None:
    if not os.path.exists(path):
        if action == "enable":
            return {}
        return None

    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except json.JSONDecodeError as exc:
        die(f"refusing to modify invalid JSON at {path}: {exc}")
    except OSError as exc:
        die(f"could not read {path}: {exc}")

    if not isinstance(data, dict):
        die(f"refusing to modify {path}: settings root must be a JSON object")
    return data


def mutate_enabled_plugin(data: dict[str, Any], action: str, plugin_name: str) -> bool:
    plugins = data.get("enabledPlugins")

    if plugins is None:
        if action == "disable":
            return False
        plugins = {}
        data["enabledPlugins"] = plugins

    if not isinstance(plugins, dict):
        die('refusing to replace non-object "enabledPlugins" value')

    if action == "enable":
        if plugins.get(plugin_name) is True:
            return False
        plugins[plugin_name] = True
        return True

    if plugin_name not in plugins:
        return False
    del plugins[plugin_name]
    return True


def atomic_write_json(path: str, data: dict[str, Any]) -> None:
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, exist_ok=True)

    tmp_path = ""
    fd = -1
    try:
        fd, tmp_path = tempfile.mkstemp(prefix=".settings-json-", suffix=".tmp", dir=parent)
        if os.path.exists(path):
            mode = stat.S_IMODE(os.stat(path).st_mode)
            os.chmod(tmp_path, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            fd = -1
            json.dump(data, f, indent=2, sort_keys=True)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, path)
        tmp_path = ""
    except OSError as exc:
        die(f"could not safely write {path}: {exc}", code=1)
    finally:
        if fd != -1:
            os.close(fd)
        if tmp_path and os.path.exists(tmp_path):
            try:
                os.unlink(tmp_path)
            except OSError:
                pass


def main(argv: list[str]) -> int:
    if len(argv) != 4 or argv[1] in {"-h", "--help"}:
        print(USAGE.rstrip())
        return 0 if len(argv) == 2 and argv[1] in {"-h", "--help"} else 2

    action, path, plugin_name = argv[1:]
    if action not in {"enable", "disable"}:
        die("action must be enable or disable")
    if not plugin_name or "@" not in plugin_name:
        die("plugin name must look like name@marketplace")

    data = load_settings(path, action)
    if data is None:
        print(f"idc-settings-json: skipped-missing {path}")
        return 0

    changed = mutate_enabled_plugin(data, action, plugin_name)
    if changed:
        atomic_write_json(path, data)
        print(f"idc-settings-json: {action}d {plugin_name} in {path}")
    else:
        print(f"idc-settings-json: skipped-already-{action}d {plugin_name} in {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
