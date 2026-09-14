#!/usr/bin/env python3
"""Copy pinned official sources, check integrity, or compare upstream metadata.

No network requests are made. Supply official local Git clones and downloaded
release JSON; updating the pins and reviewing derived summaries are separate.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

import yaml


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = "source/snapshot-manifest.json"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args])


def read_yaml(path):
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def local_path(root, relative):
    path = root / relative
    if Path(relative).is_absolute() or not path.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"Path outside skill: {relative}")
    return path


def selected(path, group):
    prefix = group["source_prefix"]
    if prefix and not path.startswith(prefix):
        return False
    relative = path[len(prefix):]
    if not relative or (not group.get("recursive", True) and "/" in relative):
        return False
    if group.get("files") and relative not in group["files"]:
        return False
    if group.get("include_prefixes") and not any(
        relative.startswith(p) for p in group["include_prefixes"]
    ):
        return False
    if group.get("suffixes") and not relative.endswith(tuple(group["suffixes"])):
        return False
    if relative.endswith(tuple(group.get("exclude_suffixes", []))):
        return False
    if any(relative.startswith(p) for p in group.get("exclude_prefixes", [])):
        return False
    return True


def snapshot_plan(root, config, repos):
    plans = {}
    trees = {}
    for group in config["extraction"]:
        source = config["repositories"][group["repository"]]
        repo = repos[source["clone"]]
        commit = source["commit"]
        actual = git(repo, "rev-parse", "--verify", commit + "^{commit}").decode().strip()
        if actual != commit:
            raise ValueError(f"Use a full commit SHA: {commit}")
        key = (str(repo), commit)
        if key not in trees:
            trees[key] = git(repo, "ls-tree", "-r", "--name-only", commit).decode().splitlines()
        for path in trees[key]:
            if not selected(path, group):
                continue
            relative = path[len(group["source_prefix"]):]
            dest = group["destination"] + relative
            local_path(root, dest)
            data = git(repo, "show", commit + ":" + path)
            entry = {
                "repository": group["repository"], "commit": commit,
                "source_path": path, "sha256": sha256(data),
            }
            if dest in plans and plans[dest][0] != data:
                raise ValueError(f"Conflicting mappings for {dest}")
            plans[dest] = (data, entry)
    if not plans:
        raise ValueError("No source files selected")
    return plans


def sync(args, root, config):
    repos = {name: getattr(args, name) for name in ("core", "docs", "reality")}
    plan = snapshot_plan(root, config, repos)
    old_path = root / MANIFEST
    old = json.loads(old_path.read_text()) if old_path.exists() else {"files": {}}
    obsolete = sorted(set(old["files"]) - set(plan))
    changed = [p for p, (data, _) in plan.items()
               if not (root / p).exists() or (root / p).read_bytes() != data]
    print(f"Pinned source files: {len(plan)}; changed/new: {len(changed)}; obsolete: {len(obsolete)}")
    if obsolete:
        for path in obsolete:
            print(f"Review obsolete snapshot file: {path}")
        raise ValueError("Remove/reclassify obsolete snapshots explicitly before updating the manifest")
    if not args.write:
        print("Dry run; pass --write after reviewing pins and source changes")
        return
    for relative in changed:
        dest = local_path(root, relative)
        dest.parent.mkdir(parents=True, exist_ok=True)
        temp = dest.with_name(dest.name + ".snapshot-tmp")
        temp.write_bytes(plan[relative][0])
        temp.replace(dest)
    manifest = {"schema_version": 1, "files": {p: item[1] for p, item in sorted(plan.items())}}
    old_path.parent.mkdir(parents=True, exist_ok=True)
    temp = old_path.with_name(old_path.name + ".snapshot-tmp")
    temp.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    temp.replace(old_path)
    print("Source snapshots and manifest written; review summaries before changing last_sync")


def verify(args, root, config):
    failures = []
    manifest = json.loads((root / MANIFEST).read_text())
    for relative, entry in manifest["files"].items():
        path = local_path(root, relative)
        if not path.is_file() or sha256(path.read_bytes()) != entry["sha256"]:
            failures.append(f"Snapshot missing or modified: {relative}")
        expected = config["repositories"][entry["repository"]]["commit"]
        if entry["commit"] != expected:
            failures.append(f"Stale snapshot pin: {relative}")
    evidence_count = 0
    for name in ("source/history-manifest.json", "citations/evidence-manifest.json"):
        evidence = json.loads((root / name).read_text())
        for relative, entry in evidence["files"].items():
            evidence_count += 1
            path = local_path(root, relative)
            if not path.is_file() or sha256(path.read_bytes()) != entry["sha256"]:
                failures.append(f"Evidence missing or modified: {relative}")
    front = (root / "SKILL.md").read_text().split("---", 2)
    metadata = yaml.safe_load(front[1])["metadata"]
    for key, expected in {
        "current_stable": config["covered_versions"]["stable"]["version"],
        "current_beta": config["covered_versions"]["beta"]["version"],
        "revision": config["metadata"]["revision"],
        "last_sync": config["metadata"]["last_sync"],
    }.items():
        if metadata.get(key) != expected:
            failures.append(f"SKILL.md metadata mismatch: {key}")
    for key, core_key in (("reality_stable", "core_stable"), ("reality_release", "core_release")):
        dep = config["repositories"][key]
        gomod = next((p for p, entry in manifest["files"].items()
                      if entry["repository"] == core_key and entry["source_path"] == "go.mod"), None)
        content = (root / gomod).read_text() if gomod else ""
        match = re.search(r"github.com/xtls/reality\s+(\S+)", content)
        if not match or match[1] != dep["module_version"] or not dep["commit"].startswith(match[1].rsplit("-", 1)[-1]):
            failures.append(f"REALITY dependency pin differs from {core_key} go.mod")
    yaml_count = 0
    for path in root.rglob("*.yaml"):
        yaml_count += 1
        value = read_yaml(path)
        if not isinstance(value, dict):
            failures.append(f"Expected YAML mapping: {path.relative_to(root)}")
            continue
        if path.parent.name == "parameters":
            source = value.get("source", {})
            if not re.fullmatch(r"[0-9a-f]{40}", str(source.get("commit", ""))):
                failures.append(f"Missing immutable parameter source: {path.name}")
            for relative in source.get("local", []):
                if relative not in manifest["files"]:
                    failures.append(f"Parameter source not in manifest: {relative}")
                elif manifest["files"][relative]["commit"] != source["commit"]:
                    failures.append(f"Parameter source version mismatch: {relative}")
    for path in (root / "examples").glob("*.json"):
        value = json.loads(path.read_text())
        if value.get("meta", {}).get("source_commit") not in {
            config["repositories"][k]["commit"] for k in ("core_stable", "core_release")
        }:
            failures.append(f"Unknown example source version: {path.name}")
        for side in ("server", "client"):
            if not isinstance(value.get(side), dict):
                failures.append(f"Missing example {side}: {path.name}")
        validation = value.get("meta", {}).get("validation", {})
        if validation.get("configuration_checked"):
            report_path = validation.get("report", "")
            report = json.loads(local_path(root, report_path).read_text()) if report_path else {}
            results = report.get("results", [])
            if report.get("version") != value["meta"]["target_version"] or not results or not all(r["passed"] for r in results):
                failures.append(f"Example has no matching successful validation report: {path.name}")
            example_hash = sha256(json.dumps(
                {side: value[side] for side in ("server", "client")},
                sort_keys=True, ensure_ascii=False).encode())
            if report.get("example_config_sha256") != example_hash:
                failures.append(f"Example config changed since validation: {path.name}")
    # Upstream manuals contain intentional omissions (translations/level-0).
    # Check our own maintained Markdown links, not those untouched upstream pages.
    paths = [root / "SKILL.md", root / "docs/README.md"]
    for directory in ("references", "changelog", "extracted", "citations"):
        paths.extend(p for p in (root / directory).rglob("*.md") if "raw" not in p.parts)
    for path in paths:
        body = re.sub(r"```.*?```", "", path.read_text(), flags=re.S)
        for target in re.findall(r"\[[^\]]*\]\(([^\s)]+)\)", body):
            target = target.strip("<>").split("#", 1)[0]
            if not target or re.match(r"[a-z]+:", target):
                continue
            if not (path.parent / target).exists():
                failures.append(f"Broken maintained link: {path.relative_to(root)} -> {target}")
    if failures:
        for failure in failures:
            print(failure, file=sys.stderr)
        raise ValueError(f"{len(failures)} validation errors")
    print(f"Verified {len(manifest['files'])} official source files, {evidence_count} evidence artifacts, {yaml_count} YAML files, examples and maintained links")


def upstream(args, root, config):
    releases = json.loads(Path(args.releases_json).read_text())
    public = [r for r in releases if not r.get("draft", False)]
    stable = max((r for r in public if not r["prerelease"]), key=lambda r: r["published_at"])
    latest = max(public, key=lambda r: r["published_at"])
    observed = {
        "stable": stable["tag_name"], "latest_release": latest["tag_name"],
        "core_main": git(args.core, "rev-parse", "HEAD").decode().strip(),
        "docs_main": git(args.docs, "rev-parse", "HEAD").decode().strip(),
    }
    expected = {
        "stable": config["covered_versions"]["stable"]["version"],
        "latest_release": config["covered_versions"]["beta"]["version"],
        "core_main": config["repositories"]["core_dev"]["commit"],
        "docs_main": config["repositories"]["docs"]["commit"],
    }
    for key, value in observed.items():
        print(f"{key}: {value} ({'matches' if value == expected[key] else 'CHANGED'})")
    print("Compared supplied local clones/API JSON; fetch them before claiming live currency")
    return int(observed != expected)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    subs = parser.add_subparsers(dest="command", required=True)
    sync_parser = subs.add_parser("sync", help="Copy pinned Git blobs; dry run by default")
    for name in ("core", "docs", "reality"):
        sync_parser.add_argument("--" + name, type=Path, required=True)
    sync_parser.add_argument("--write", action="store_true")
    subs.add_parser("verify", help="Check hashes, provenance, YAML, examples and links")
    up = subs.add_parser("check-upstream", help="Compare refreshed clones and release API data")
    for name in ("core", "docs"):
        up.add_argument("--" + name, type=Path, required=True)
    up.add_argument("--releases-json", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        config = read_yaml(root / "sources.yaml")
        function = {"sync": sync, "verify": verify, "check-upstream": upstream}[args.command]
        return function(args, root, config) or 0
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError, yaml.YAMLError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
