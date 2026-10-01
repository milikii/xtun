#!/usr/bin/env python3
"""Test copied skill and current tracked/untracked distribution without committing."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    with tempfile.TemporaryDirectory(prefix='portable-skill-') as temp:
        temp = Path(temp)
        skill = temp / 'independent-skill'
        shutil.copytree(ROOT, skill, ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
        run(sys.executable, str(skill / 'scripts/snapshot.py'), 'verify', cwd=temp)
        sys.path.insert(0, str(skill / 'scripts'))
        from generate import generate, write_bundle
        from check_configs import load_bundle
        request = {'version': 'v26.3.27', 'server': {'address': 'proxy.example.com', 'port': 8443},
                   'transport': {'type': 'raw'}, 'security': {'type': 'tls', 'server_name': 'proxy.example.com',
                   'certificate_file': 'server.pem', 'key_file': 'server.key'}}
        write_bundle(temp / 'bundle', *generate(request))
        load_bundle(temp / 'bundle')
        repo = ROOT.parents[2]
        if (repo / '.git').exists():
            env = dict(os.environ, GIT_INDEX_FILE=str(temp / 'index'))
            run('git', 'read-tree', 'HEAD', cwd=repo, env=env)
            run('git', 'add', '-A', '--', '.', cwd=repo, env=env)
            tree = subprocess.check_output(['git', 'write-tree'], cwd=repo, env=env, text=True).strip()
            archive = temp / 'distribution.tar'
            run('git', 'archive', '--format=tar', '-o', str(archive), tree, cwd=repo, env=env)
            with tarfile.open(archive) as handle:
                names = set(handle.getnames())
            prefix = '.claude/skills/xray-core/'
            for relative in ('SKILL.md', 'sources.yaml', 'scripts/generate.py', 'scripts/check_handshake.py',
                             'extracted/compatibility/generation.yaml', 'tests/test_generation.py', 'source/licenses'):
                if not any(name == prefix + relative or name.startswith(prefix + relative + '/') for name in names):
                    raise RuntimeError('Required distribution entry missing: ' + relative)
            forbidden = ('.cache/', '.claude/worktrees/', '.claude/settings.local.json', 'output/', 'outputs/', '__pycache__')
            if any(any(part in name for part in forbidden) for name in names):
                raise RuntimeError('Private or transient files included in distribution')
    print('Copied skill generation and current-tree Git archive checks passed; no native core was executed.')


if __name__ == '__main__':
    main()
