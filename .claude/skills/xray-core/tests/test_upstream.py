"""Offline contract tests for the official upstream observer."""

from contextlib import redirect_stderr, redirect_stdout
from copy import deepcopy
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError, URLError


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "upstream.py"
spec = importlib.util.spec_from_file_location("skill_upstream", SCRIPT)
upstream = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upstream)
A, B, C, D = (char * 40 for char in "abcd")
CHECKED = "2026-09-30T10:00:00Z"


def release(tag, prerelease=False, day=1, draft=False):
    return {"tag_name": tag, "draft": draft, "prerelease": prerelease,
            "published_at": f"2026-09-{day:02d}T00:00:00Z", "id": day}


def fixtures(releases=None, stable=None):
    stable = stable or release("stable-tag", day=2)
    releases = releases or [release("preview-tag", prerelease=True, day=3), stable]
    values = {
        upstream.API + "/releases?per_page=100&page=1": releases,
        upstream.API + "/releases/latest": stable,
        upstream.API + "/git/ref/heads/main": {"ref": "refs/heads/main", "object": {"type": "commit", "sha": C}},
        upstream.DOCS_API + "/git/ref/heads/main": {"ref": "refs/heads/main", "object": {"type": "commit", "sha": D}},
    }
    for item in releases:
        if not item["draft"]:
            values[upstream.API + "/git/ref/tags/" + item["tag_name"]] = {
                "ref": "refs/tags/" + item["tag_name"],
                "object": {"type": "commit", "sha": B if item["prerelease"] else A},
            }
    return values


def observation():
    return upstream.observe(fixtures().__getitem__, checked_at=CHECKED)


def pin_text():
    return f'''metadata:
  skill_name: xray-core
covered_versions:
  stable:
    version: "stable-tag"
    commit: {A}
    source_root: source/stable/
  beta:
    version: 'preview-tag'
    commit: {B}
    source_roots:
    - source/config/
    - source/runtime/
  dev:
    branch: main
    commit: {C}
documentation:
  directory: docs/stable/
  track: rolling official docs
  commit: {D}
repositories:
  core_dev:
    commit: {C}
  docs:
    commit: {D}
extraction:
- repository: core_release
  source_prefix: infra/conf/
  destination: source/config/
  suffixes:
  - .go
- repository: core_stable
  source_prefix: infra/conf/
  destination: source/stable/
'''


class ObservationTests(unittest.TestCase):
    def test_channels_use_metadata_not_tag_name(self):
        data = fixtures([release("looks-stable", True, 4), release("looks-beta", False, 3)], stable=release("looks-beta", False, 3))
        result = upstream.observe(data.__getitem__, checked_at=CHECKED)
        self.assertEqual(result["channels"]["stable"]["tag"], "looks-beta")
        self.assertEqual(result["channels"]["prerelease"]["tag"], "looks-stable")
        self.assertTrue(result["channels"]["latest_published"]["prerelease"])
        self.assertEqual(result["main"]["commit"], C)
        self.assertEqual(result["documentation"]["commit"], D)
        self.assertEqual(result["checked_at"], CHECKED)
        self.assertIn(upstream.API + "/releases/latest", result["raw"])

    def test_latest_published_can_be_stable_without_losing_prerelease(self):
        stable = release("stable-tag", day=5)
        result = upstream.observe(fixtures([stable, release("preview-tag", True, 3)], stable).__getitem__)
        self.assertEqual(result["channels"]["latest_published"]["tag"], "stable-tag")
        self.assertEqual(result["channels"]["prerelease"]["tag"], "preview-tag")

    def test_no_prerelease_is_normal(self):
        stable = release("stable-tag", day=2)
        result = upstream.observe(fixtures([stable], stable).__getitem__)
        self.assertIsNone(result["channels"]["prerelease"])

    def test_drafts_are_ignored(self):
        data = fixtures()
        data[upstream.API + "/releases?per_page=100&page=1"].insert(0, {"draft": True})
        self.assertEqual(upstream.observe(data.__getitem__)["public_release_count"], 2)

    def test_no_stable_with_latest_404_is_normal(self):
        data = fixtures([release("preview-tag", True, 3)])
        def get(url):
            if url.endswith("/releases/latest"):
                raise upstream.UpstreamError("not found", 404)
            return data[url]
        self.assertIsNone(upstream.observe(get)["channels"]["stable"])

    def test_latest_404_with_listed_stable_is_error(self):
        data = fixtures()
        def get(url):
            if url.endswith("/releases/latest"):
                raise upstream.UpstreamError("not found", 404)
            return data[url]
        with self.assertRaises(upstream.UpstreamError):
            upstream.observe(get)

    def test_latest_stable_is_authoritative_not_just_publication_order(self):
        stable = release("stable-tag", day=2)
        data = fixtures([release("new-patch", day=8), stable], stable)
        result = upstream.observe(data.__getitem__)
        self.assertEqual(result["channels"]["stable"]["tag"], "stable-tag")
        self.assertEqual(result["channels"]["latest_published"]["tag"], "new-patch")
        self.assertTrue(result["warnings"])

    def test_latest_mismatch_is_not_silent(self):
        data = fixtures()
        data[upstream.API + "/releases/latest"] = release("missing-tag", day=9)
        with self.assertRaisesRegex(upstream.UpstreamError, "disagrees"):
            upstream.observe(data.__getitem__)

    def test_latest_must_not_be_prerelease(self):
        data = fixtures()
        data[upstream.API + "/releases/latest"] = release("preview-tag", True, 3)
        with self.assertRaisesRegex(upstream.UpstreamError, "stable public"):
            upstream.observe(data.__getitem__)

    def test_pagination_completes_before_claiming_latest(self):
        stable = release("stable-tag", day=2)
        page = [release(f"historical-{n}", day=1) for n in range(100)]
        data = fixtures([stable], stable)
        data[upstream.API + "/releases?per_page=100&page=1"] = page
        data[upstream.API + "/releases?per_page=100&page=2"] = [stable]
        result = upstream.observe(data.__getitem__)
        self.assertEqual(result["public_release_count"], 101)
        with self.assertRaisesRegex(upstream.UpstreamError, "pagination limit"):
            upstream.observe(data.__getitem__, max_pages=1)

    def test_overlapping_pages_are_rejected(self):
        data = fixtures()
        page = [release(f"historical-{n}") for n in range(100)]
        data[upstream.API + "/releases?per_page=100&page=1"] = page
        data[upstream.API + "/releases?per_page=100&page=2"] = [page[0]]
        with self.assertRaisesRegex(upstream.UpstreamError, "overlap"):
            upstream.observe(data.__getitem__)

    def test_malformed_channels_and_time_rejected(self):
        for field, value in (("prerelease", "false"), ("draft", "false"), ("published_at", "2026-09-30"), ("tag_name", "../../other")):
            record = release("tag")
            record[field] = value
            with self.subTest(field=field), self.assertRaises(upstream.UpstreamError):
                upstream.validate_release(record)

    def test_lightweight_tag(self):
        self.assertEqual(upstream.resolve_tag(fixtures().__getitem__, "stable-tag"), A)

    def test_nested_annotated_tag(self):
        values = {
            upstream.API + "/git/ref/tags/tag": {"ref": "refs/tags/tag", "object": {"type": "tag", "sha": A}},
            upstream.API + "/git/tags/" + A: {"object": {"type": "tag", "sha": B}},
            upstream.API + "/git/tags/" + B: {"object": {"type": "commit", "sha": C}},
        }
        raw = {}
        self.assertEqual(upstream.resolve_tag(values.__getitem__, "tag", raw), C)
        self.assertEqual(len(raw), 3)

    def test_tag_cycle_short_sha_and_other_ref_rejected(self):
        variants = [
            {"ref": "refs/tags/tag", "object": {"type": "tag", "sha": A}},
            {"ref": "refs/tags/tag", "object": {"type": "commit", "sha": "short"}},
            {"ref": "refs/tags/other", "object": {"type": "commit", "sha": A}},
        ]
        for value in variants:
            with self.subTest(value=value), self.assertRaises(upstream.UpstreamError):
                upstream.resolve_tag(lambda url: value, "tag")


class CacheAndPinsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.cache = self.root / "upstream.json"
        self.sources = self.root / "sources.yaml"
        self.sources.write_text(pin_text())

    def test_actual_source_layout_and_quoted_scalars(self):
        pins = upstream.read_source_pins(self.sources)
        self.assertEqual(pins["stable"], {"tag": "stable-tag", "commit": A})
        self.assertEqual(pins["prerelease"], {"tag": "preview-tag", "commit": B})
        self.assertEqual(pins["documentation"], {"commit": D})

    def test_json_pins(self):
        self.sources.write_text(json.dumps({"covered_versions": {"stable": {"version": "tag", "commit": A}}}))
        self.assertEqual(upstream.read_source_pins(self.sources)["stable"]["commit"], A)

    def test_complex_or_duplicate_pins_do_not_silently_match(self):
        for text in (
            "covered_versions: {stable: {version: tag, commit: " + A + "}}\n",
            pin_text().replace("    version: \"stable-tag\"", "    version: [stable-tag]"),
            pin_text().replace("    commit: " + A, "    commit: " + A + "\n    commit: " + A),
        ):
            self.sources.write_text(text)
            with self.subTest(text=text), self.assertRaises(upstream.UpstreamError):
                upstream.read_source_pins(self.sources)

    def test_cache_roundtrip_private_and_offline_freshness(self):
        payload = observation()
        upstream.store_cache(self.cache, payload)
        self.assertEqual(os.stat(self.cache).st_mode & 0o777, 0o600)
        self.assertEqual(upstream.load_cache(self.cache), payload)
        report = upstream.make_report(payload, upstream.read_source_pins(self.sources), offline=True)
        self.assertEqual(report["checked_at"], CHECKED)
        self.assertEqual(report["freshness"], "unknown")
        self.assertEqual(report["configuration_support"], "not_assessed")
        self.assertFalse(report["changes_detected"])

    def test_changed_tag_commit_detected_even_when_version_matches(self):
        payload = observation()
        payload["channels"]["stable"]["commit"] = D
        self.assertTrue(upstream.make_report(payload, upstream.read_source_pins(self.sources))["changes_detected"])

    def test_corrupted_cache_is_never_overwritten(self):
        upstream.store_cache(self.cache, observation())
        value = json.loads(self.cache.read_text())
        value["payload"]["checked_at"] = "2099-01-01T00:00:00Z"
        self.cache.write_text(json.dumps(value))
        original = self.cache.read_bytes()
        with self.assertRaisesRegex(upstream.UpstreamError, "modified"):
            upstream.store_cache(self.cache, observation())
        self.assertEqual(self.cache.read_bytes(), original)

    def test_symlink_and_existing_outputs_are_not_overwritten(self):
        target = self.root / "target"
        target.write_text("original")
        link = self.root / "link"
        link.symlink_to(target)
        for path in (target, link):
            with self.subTest(path=path), self.assertRaises(upstream.UpstreamError):
                upstream.private_write(path, b"new")
        with self.assertRaises(upstream.UpstreamError):
            upstream.store_cache(link, observation())
        self.assertEqual(target.read_text(), "original")

    def test_online_failure_does_not_silently_use_cache_or_modify_it(self):
        upstream.store_cache(self.cache, observation())
        original = self.cache.read_bytes()
        out, err = io.StringIO(), io.StringIO()
        with patch.object(upstream, "observe", side_effect=upstream.UpstreamError("rate limited", 429)), redirect_stdout(out), redirect_stderr(err):
            result = upstream.main(["check", "--sources", str(self.sources), "--cache", str(self.cache)])
        self.assertEqual(result, 2)
        self.assertEqual(out.getvalue(), "")
        self.assertIn("rate limited", err.getvalue())
        self.assertEqual(self.cache.read_bytes(), original)

    def test_offline_cli_uses_no_http_and_preserves_observed_time(self):
        upstream.store_cache(self.cache, observation())
        out = io.StringIO()
        with patch.object(upstream, "HttpClient", side_effect=AssertionError("network attempted")), redirect_stdout(out):
            result = upstream.main(["check", "--offline", "--sources", str(self.sources), "--cache", str(self.cache)])
        report = json.loads(out.getvalue())
        self.assertEqual(result, 0)
        self.assertEqual(report["mode"], "offline-cache")
        self.assertEqual(report["checked_at"], CHECKED)

    def test_cli_changed_status_optional(self):
        payload = observation()
        payload["channels"]["stable"]["commit"] = D
        upstream.store_cache(self.cache, payload)
        with redirect_stdout(io.StringIO()):
            result = upstream.main(["check", "--offline", "--fail-on-change", "--sources", str(self.sources), "--cache", str(self.cache)])
        self.assertEqual(result, 1)


class HttpTests(unittest.TestCase):
    def test_api_host_is_fixed_and_token_not_sent_elsewhere(self):
        client = upstream.HttpClient(token="private-test-token")
        client.opener = Mock()
        for url in ("http://api.github.com/", "https://example.com/", "https://api.github.com.evil.test/", "https://user:pass@api.github.com/", "https://api.github.com:444/"):
            with self.subTest(url=url), self.assertRaises(upstream.UpstreamError):
                client.json(url)
        client.opener.open.assert_not_called()

    def test_limits_timeouts_and_errors_are_not_fresh_success(self):
        for error in (HTTPError(upstream.API, 429, "rate limit", {}, None), HTTPError(upstream.API, 403, "forbidden", {}, None), URLError("offline"), TimeoutError()):
            client = upstream.HttpClient(timeout=3)
            client.opener = Mock()
            client.opener.open.side_effect = error
            with self.subTest(error=error), self.assertRaisesRegex(upstream.UpstreamError, "no fresh observation"):
                client.json(upstream.API)
            self.assertEqual(client.opener.open.call_args.kwargs["timeout"], 3)

    def test_bad_json_and_oversized_response(self):
        for body in (b"not-json", b"x" * (16 * 1024 * 1024 + 1)):
            client = upstream.HttpClient()
            response = Mock()
            response.geturl.return_value = upstream.API
            response.read.return_value = body
            client.opener = Mock()
            client.opener.open.return_value.__enter__ = Mock(return_value=response)
            client.opener.open.return_value.__exit__ = Mock(return_value=False)
            with self.subTest(size=len(body)), self.assertRaises(upstream.UpstreamError):
                client.json(upstream.API)


if __name__ == "__main__":
    unittest.main()
