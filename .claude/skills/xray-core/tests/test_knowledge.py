"""Offline knowledge-contract checks, not an LLM evaluation or deployment test."""
import json
from pathlib import Path
import unittest
from urllib.parse import urlparse

import yaml

ROOT = Path(__file__).resolve().parents[1]


class KnowledgeContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.contract = yaml.safe_load((ROOT / 'tests/knowledge_cases.yaml').read_text())
        cls.cases = cls.contract['cases']

    def test_cases_cover_user_workflows(self):
        ids = [case['id'] for case in self.cases]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertTrue({'current-release', 'unsupported-helper-field', 'reality-target',
                         'xhttp-cdn', 'certificate-renewal', 'private-artifacts', 'two-nodes'} <= set(ids))
        self.assertIn('not actual harness reasoning', self.contract['scope'])
        for case in self.cases:
            self.assertTrue(case['prompt'])
            self.assertGreaterEqual(len(case['required']), 3)
            self.assertGreaterEqual(len(case['forbidden']), 2)
            self.assertFalse(set(case['required']) & set(case['forbidden']))

    def test_case_evidence_and_guides_exist(self):
        manifest = json.loads((ROOT / 'source/snapshot-manifest.json').read_text())['files']
        for case in self.cases:
            for relative in case['guides'] + case['evidence']:
                with self.subTest(case=case['id'], path=relative):
                    path = ROOT / relative
                    self.assertTrue(path.resolve().is_relative_to(ROOT.resolve()))
                    self.assertTrue(path.is_file())
                    if relative.startswith('source/'):
                        self.assertIn(relative, manifest)

    def test_entry_links_all_case_guides(self):
        entry = (ROOT / 'SKILL.md').read_text()
        for guide in {guide for case in self.cases for guide in case['guides']}:
            self.assertIn('(' + guide + ')', entry)

    def test_external_sources_are_separate_from_snapshots(self):
        sources = yaml.safe_load((ROOT / 'references/operations-sources.yaml').read_text())
        self.assertIn('not bundled', sources['snapshot_policy'])
        hosts = {'letsencrypt.org', 'eff-certbot.readthedocs.io', 'developers.cloudflare.com'}
        for source in sources['sources'].values():
            parsed = urlparse(source['url'])
            self.assertEqual(parsed.scheme, 'https')
            self.assertIn(parsed.hostname, hosts)
            self.assertTrue(source['reviewed_claims'])

    def test_knowledge_revision_does_not_relabel_snapshot_dates(self):
        sources = yaml.safe_load((ROOT / 'sources.yaml').read_text())
        front = yaml.safe_load((ROOT / 'SKILL.md').read_text().split('---', 2)[1])
        self.assertEqual(front['metadata']['revision'], sources['metadata']['revision'])
        self.assertEqual(front['metadata']['last_sync'], sources['metadata']['last_sync'])
        self.assertLessEqual(sources['documentation']['last_sync'], sources['metadata']['last_sync'])
        self.assertIn('optional', front['description'])


if __name__ == '__main__':
    unittest.main()
