#!/usr/bin/env python3
"""Archive official release bodies and commit ranges from cached API data/Git.

Does not generate factual parameter summaries or change source version pins.
"""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

import yaml


ROOT = Path(__file__).resolve().parents[1]


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args]).decode()


def generate(repo, releases, config):
    planned = {}
    evidence = {}
    def add(path, text, provenance):
        data = text.encode()
        planned[path] = data
        evidence[path] = dict(sha256=hashlib.sha256(data).hexdigest(), **provenance)

    normalized = []
    for release in releases:
        if release.get("draft"):
            continue
        tag = release["tag_name"]
        commit = git(repo, "rev-parse", "--verify", tag + "^{commit}").strip()
        entry = {k: release.get(k) for k in (
            "tag_name", "name", "prerelease", "published_at", "updated_at", "html_url", "body"
        )}
        entry.update(commit=commit, author=release["author"]["login"])
        normalized.append(entry)
        text = (f"# {tag}\n\n"
                f"- Official source: {entry['html_url']}\n"
                f"- Published: {entry['published_at']}\n"
                f"- Last edited: {entry['updated_at']}\n"
                f"- Author: {entry['author']}\n"
                f"- Pre-release: {str(entry['prerelease']).lower()}\n"
                f"- Tag commit: `{commit}`\n\n"
                "Release body from GitHub API; line endings normalized. A forwarding link\n"
                "is not a technical changelog; use the separate commit-range index.\n\n"
                + (entry['body'] or '').replace('\r\n', '\n') + '\n')
        add(f"source/releases/{tag}.md", text, dict(kind="release-api-body", url=entry['html_url'], commit=commit))
    add("source/releases/index.json", json.dumps(normalized, ensure_ascii=False, indent=2) + "\n",
        dict(kind="release-api-records", url=config['upstream']['releases_api']))

    stable = config['covered_versions']['stable']['version']
    latest = config['covered_versions']['beta']['version']
    ordered = sorted(normalized, key=lambda r: r['published_at'])
    tags = [r['tag_name'] for r in ordered]
    first = tags.index(stable)
    last = tags.index(latest)
    previous_stable = next((r['tag_name'] for r in reversed(ordered[:first]) if not r['prerelease']), None)
    pairs = [(previous_stable, stable)] if previous_stable else []
    pairs.extend(zip(tags[first:last], tags[first + 1:last + 1]))
    dev = config['repositories']['core_dev']['commit']
    pairs.append((latest, dev))
    for base, head in pairs:
        subprocess.run(['git', '-C', str(repo), 'merge-base', '--is-ancestor', base, head], check=True)
        base_sha = git(repo, 'rev-parse', base + '^{commit}').strip()
        head_sha = git(repo, 'rev-parse', head + '^{commit}').strip()
        commits = git(repo, 'log', '--reverse', '--format=%H%x09%cI%x09%an%x09%s', base + '..' + head).splitlines()
        filename = f"dev-after-{latest}" if head == dev else head
        text = (f"# {base} → {head}\n\n"
                f"- Base: `{base_sha}`\n- Head: `{head_sha}`\n"
                f"- Commits: {len(commits)}\n"
                "- This is an official Git commit index. Titles alone do not establish\n"
                "  runtime behavior; inspect the linked changes and versioned code.\n\n")
        for line in commits:
            sha, date, author, title = line.split('\t', 3)
            text += f"- [{sha[:8]}](https://github.com/XTLS/Xray-core/commit/{sha}) — {date} — {author}: {title}\n"
        add(f"source/commits/{filename}.md", text,
            dict(kind='git-commit-range', base=base_sha, head=head_sha, repository='XTLS/Xray-core'))
    for commit in config['history']['critical_commits']:
        full = git(repo, 'rev-parse', commit + '^{commit}').strip()
        patch = git(repo, 'show', '--format=fuller', '--no-ext-diff', full)
        add(f"source/commits/patches/{full[:8]}.patch", patch,
            dict(kind='git-show', repository='XTLS/Xray-core', commit=full))
    return planned, evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--core', type=Path, required=True)
    parser.add_argument('--releases-json', type=Path, required=True)
    parser.add_argument('--write', action='store_true')
    args = parser.parse_args()
    config = yaml.safe_load((args.root / 'sources.yaml').read_text())
    releases = json.loads(args.releases_json.read_text())
    planned, evidence = generate(args.core, releases, config)
    print(f"Release/history artifacts: {len(planned)}")
    if not args.write:
        print('Dry run; pass --write to archive the supplied official evidence')
        return
    for relative, data in planned.items():
        path = args.root / relative
        if not path.resolve().is_relative_to(args.root.resolve()):
            raise ValueError(f'Invalid destination: {relative}')
        path.parent.mkdir(parents=True, exist_ok=True)
        temp = path.with_name(path.name + '.history-tmp')
        temp.write_bytes(data)
        temp.replace(path)
    manifest = args.root / 'source/history-manifest.json'
    manifest.write_text(json.dumps({'schema_version': 1, 'files': evidence}, ensure_ascii=False, indent=2) + '\n')
    print('Official evidence archived; manually review changelog/ and extracted/ separately')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, yaml.YAMLError) as error:
        print(f'Error: {error}', file=sys.stderr)
        sys.exit(2)
