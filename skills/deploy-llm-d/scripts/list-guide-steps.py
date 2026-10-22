#!/usr/bin/env python3
"""Summarize an llm-d guide.yaml for deployment planning.

llm-d guides (v1.0 and later) are a ``guide.yaml`` (machine-readable ``env``,
``prerequisites``, ``deploy``, ``verify``, ``benchmark`` and ``cleanup``
sections) plus a ``README.md`` rendered from it. The upstream tool

    ${LLMD_PATH}/scripts/guide.py emit <guide> <section...> --var NAME=VALUE

turns selected step lists into executable bash. This script prints what is
needed to choose those sections and variables:

  * ``env.static`` variables with defaults and declared values
  * the support matrix (accelerator -> model servers -> infra providers)
  * the endpoint modes (for example ``standalone`` and ``gateway``)
  * every step-list path, classified as stage / mode / option / test, with
    the ``when:`` and ``skip_in:`` filters of its steps

Usage:
    list-guide-steps.py <guide-dir | guide.yaml> [--json]

Exit codes: 0 success, 1 the guide has no parseable guide.yaml, 2 usage error.
Requires python3 and PyYAML (the dependency ``scripts/guide.py`` already has).
Read-only: it never touches the cluster or the guide files.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.stderr.write(
        "error: PyYAML is required (pip install pyyaml, or run via "
        "`uv run --with pyyaml list-guide-steps.py ...`)\n"
    )
    sys.exit(1)

SECTIONS = ("prerequisites", "deploy", "verify", "benchmark", "cleanup")


def load(target: str) -> tuple[dict, Path]:
    path = Path(target)
    if path.is_dir():
        path = path / "guide.yaml"
    if not path.is_file():
        raise SystemExit(
            f"error: {path} not found. README-only guides have no guide.yaml; "
            "follow their README manually."
        )
    try:
        data = yaml.safe_load(path.read_text())
    except yaml.YAMLError as exc:
        raise SystemExit(f"error: {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise SystemExit(f"error: {path}: top level must be a map")
    return data, path


def env_vars(data: dict) -> list[dict]:
    env = data.get("env") or {}
    static = env.get("static") if isinstance(env, dict) else None
    out = []
    for name, spec in (static or {}).items():
        if isinstance(spec, dict):
            values = spec.get("values")
            out.append(
                {
                    "name": str(name),
                    "default": spec.get("default"),
                    "values": [str(v) for v in values] if isinstance(values, list) else None,
                    "sensitive": bool(spec.get("sensitive")),
                    "comment": spec.get("comment"),
                }
            )
        else:
            out.append(
                {"name": str(name), "default": spec, "values": None, "sensitive": False, "comment": None}
            )
    return out


def env_source(data: dict) -> list[str]:
    env = data.get("env") or {}
    src = env.get("source") if isinstance(env, dict) else None
    if src is None:
        return []
    return [str(s) for s in src] if isinstance(src, list) else [str(src)]


def support(data: dict) -> dict | None:
    sup = data.get("support")
    if not isinstance(sup, dict):
        return None
    accelerators = []
    for name, spec in (sup.get("accelerators") or {}).items():
        spec = spec if isinstance(spec, dict) else {}
        providers = []
        for prov in spec.get("providers") or []:
            providers.append(str(prov.get("name")) if isinstance(prov, dict) else str(prov))
        accelerators.append(
            {
                "accelerator": str(name),
                "label": spec.get("label"),
                "model": spec.get("model"),
                "engines": {str(k): str(v) for k, v in (spec.get("engines") or {}).items()},
                "providers": providers,
                "notes": spec.get("notes"),
            }
        )
    return {
        "engines": {str(k): str(v) for k, v in (sup.get("engines") or {}).items()},
        "accelerators": accelerators,
    }


def modes(data: dict) -> list[str]:
    """Endpoint modes, mirroring scripts/guide.py discover_modes()."""
    for section in ("verify", "benchmark"):
        node = data.get(section)
        endpoint = node.get("endpoint") if isinstance(node, dict) else None
        if isinstance(endpoint, dict):
            return [str(k) for k in endpoint]
    return []


def _filters(steps: list) -> dict:
    whens: list[str] = []
    skips: set[str] = set()
    for step in steps:
        if not isinstance(step, dict):
            continue
        when = step.get("when")
        if isinstance(when, dict):
            whens.append(
                ", ".join(
                    f"{var} in [{', '.join(str(x) for x in (allowed or []))}]"
                    for var, allowed in when.items()
                )
            )
        else:
            whens.append("")
        for tag in step.get("skip_in") or []:
            skips.add(str(tag))
    unique: list[str] = []
    for w in whens:
        if w not in unique:
            unique.append(w)
    return {
        "when": [w for w in unique if w],
        "unconditional_steps": "" in unique,
        "skip_in": sorted(skips),
    }


def _walk(node, path: str, out: list) -> None:
    if isinstance(node, list):
        out.append({"path": path, "steps": len(node), **_filters(node)})
        return
    if isinstance(node, dict):
        for key, value in node.items():
            _walk(value, f"{path}.{key}", out)


def steps(data: dict, mode_names: list[str]) -> list[dict]:
    found: list[dict] = []
    for section in SECTIONS:
        if section in data:
            _walk(data[section], section, found)

    parents: dict[str, list[str]] = {}
    for entry in found:
        parent = entry["path"].rsplit(".", 1)[0] if "." in entry["path"] else ""
        parents.setdefault(parent, []).append(entry["path"])

    for entry in found:
        parts = entry["path"].split(".")
        section, leaf = parts[0], parts[-1]
        parent = ".".join(parts[:-1])
        siblings = [p for p in parents.get(parent, []) if p != entry["path"]]
        if leaf in mode_names and len(parts) >= 2:
            entry["kind"] = "mode"
            entry["mode"] = leaf
        elif section == "verify" and len(parts) >= 2 and parts[1] == "tests":
            entry["kind"] = "test"
        elif len(parts) <= 2:
            entry["kind"] = "stage"
        else:
            entry["kind"] = "option"
            # Options whose steps all carry when: filters select themselves
            # from the variables; the others need an explicit choice.
            entry["selection"] = (
                "by-variables" if entry["when"] and not entry["unconditional_steps"] else "manual"
            )
            entry["alternatives"] = siblings
    return found


def _text(summary: dict) -> str:
    lines: list[str] = []
    lines.append(f"guide: {summary['guide']}  ({summary['path']})")
    lines.append(f"modes: {', '.join(summary['modes']) or '(none declared)'}")
    lines.append("")
    lines.append("env.static (NAME = default | values | comment):")
    for var in summary["env"]:
        default = "<sensitive>" if var["sensitive"] else var["default"]
        line = f"  {var['name']:<22} = {default}"
        if var["values"]:
            line += f"  | values: {', '.join(var['values'])}"
        if var["comment"]:
            line += f"  | {var['comment']}"
        lines.append(line)
    for src in summary["env_source"]:
        lines.append(f"  source: {src}")
    lines.append("")

    sup = summary["support"]
    if sup:
        engines = ", ".join(f"{k}={v}" for k, v in sup["engines"].items())
        lines.append(f"support matrix (engines: {engines}):")
        for acc in sup["accelerators"]:
            eng = " ".join(f"{k}={v}" for k, v in acc["engines"].items())
            prov = ", ".join(acc["providers"]) if acc["providers"] else "(INFRA_PROVIDER not used)"
            lines.append(f"  {acc['accelerator']:<22} model={acc['model']}  {eng}  providers: {prov}")
        lines.append("")
    else:
        lines.append("support matrix: (none declared; the guide has no accelerator/engine axis)")
        lines.append("")

    lines.append("steps (path | kind | filters):")
    current = None
    for entry in summary["steps"]:
        section = entry["path"].split(".")[0]
        if section != current:
            lines.append(f"{section}:")
            current = section
        filters = []
        if entry["when"]:
            filters.append("when: " + " | ".join(entry["when"]))
        if entry["skip_in"]:
            filters.append("skip_in: " + ",".join(entry["skip_in"]))
        kind = entry["kind"]
        if kind == "mode":
            kind = f"mode={entry['mode']}"
        elif kind == "option":
            kind = f"option({entry['selection']})"
        lines.append(f"  {entry['path']:<44} {kind:<22} {'; '.join(filters)}".rstrip())
    lines.append("")
    lines.append("emit example:")
    lines.append(
        "  python3 ${LLMD_PATH}/scripts/guide.py emit <guide-dir> env <path...> "
        "--var NAMESPACE=<ns> --var ACCELERATOR_TYPE=<acc> ..."
    )
    lines.append(
        "  (one mode only; options marked manual need a choice; verify.tests.* send traffic)"
    )
    return "\n".join(lines) + "\n"


def summarize(target: str) -> dict:
    data, path = load(target)
    mode_names = modes(data)
    return {
        "guide": str(data.get("name") or path.parent.name),
        "path": str(path),
        "modes": mode_names,
        "env": env_vars(data),
        "env_source": env_source(data),
        "support": support(data),
        "steps": steps(data, mode_names),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Summarize an llm-d guide.yaml (variables, support matrix, modes, step paths)."
    )
    parser.add_argument("target", help="guide directory or path to guide.yaml")
    parser.add_argument("--json", action="store_true", help="emit JSON instead of text")
    args = parser.parse_args(argv)
    summary = summarize(args.target)
    if args.json:
        json.dump(summary, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        sys.stdout.write(_text(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
