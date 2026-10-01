#!/usr/bin/env python3
"""Observe official Xray versions without changing source pins or installing anything.

An upstream match is not a configuration-support claim. Offline reports retain
an observation's original timestamp and explicitly have unknown freshness.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener


ROOT = Path(__file__).resolve().parents[1]
API = "https://api.github.com/repos/XTLS/Xray-core"
DOCS_API = "https://api.github.com/repos/XTLS/Xray-docs-next"
DEFAULT_CACHE = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "xray-core" / "upstream.json"
SHA = re.compile(r"[0-9a-f]{40}\Z")
TAG = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]*\Z")


class UpstreamError(ValueError):
    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


def utc_now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()


def sha256(value):
    return hashlib.sha256(value).hexdigest()


def check_url(url):
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.hostname != "api.github.com" or parsed.username or parsed.password or parsed.port not in (None, 443):
        raise UpstreamError("Refusing a URL outside the official HTTPS GitHub API")


class OfficialRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        check_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class HttpClient:
    def __init__(self, timeout=20, token=None):
        if timeout <= 0 or timeout > 120:
            raise UpstreamError("HTTP timeout must be greater than 0 and at most 120 seconds")
        self.timeout = timeout
        self.token = token
        self.opener = build_opener(OfficialRedirects())

    def json(self, url):
        check_url(url)
        headers = {"User-Agent": "xray-core-skill", "Accept": "application/vnd.github+json"}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        try:
            with self.opener.open(Request(url, headers=headers), timeout=self.timeout) as response:
                check_url(response.geturl())
                data = response.read(16 * 1024 * 1024 + 1)
        except HTTPError as error:
            if error.code in (403, 429):
                raise UpstreamError(f"Official API access refused or rate limited (HTTP {error.code}); no fresh observation was recorded", error.code) from None
            raise UpstreamError(f"Official request failed (HTTP {error.code}); no fresh observation was recorded", error.code) from None
        except (URLError, TimeoutError, OSError) as error:
            raise UpstreamError(f"Official request failed ({type(error).__name__}); no fresh observation was recorded") from None
        if len(data) > 16 * 1024 * 1024:
            raise UpstreamError("Official response exceeds the configured size limit")
        try:
            return json.loads(data)
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise UpstreamError("Official API returned invalid JSON") from None


def timestamp(value):
    if not isinstance(value, str):
        raise UpstreamError("Release has no publication timestamp")
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise UpstreamError("Release has an invalid publication timestamp") from None
    if result.tzinfo is None:
        raise UpstreamError("Publication timestamp must include a timezone")
    return result


def validate_release(release):
    if not isinstance(release, dict) or not isinstance(release.get("draft"), bool):
        raise UpstreamError("Malformed release record")
    if release["draft"]:
        return False
    if not isinstance(release.get("prerelease"), bool) or not isinstance(release.get("tag_name"), str) or not TAG.fullmatch(release["tag_name"]):
        raise UpstreamError("Public release has invalid channel or tag metadata")
    timestamp(release.get("published_at"))
    return True


def resolve_tag(get_json, tag, raw=None):
    """Resolve lightweight or nested annotated tags, with cycle/depth checks."""
    if not isinstance(tag, str) or not TAG.fullmatch(tag):
        raise UpstreamError("Invalid release tag")
    url = API + "/git/ref/tags/" + quote(tag, safe="")
    ref = get_json(url)
    if raw is not None:
        raw[url] = ref
    if not isinstance(ref, dict) or ref.get("ref") != "refs/tags/" + tag:
        raise UpstreamError("Tag API returned a different reference")
    obj = ref.get("object")
    seen = set()
    for _ in range(8):
        if not isinstance(obj, dict) or not isinstance(obj.get("sha"), str) or not SHA.fullmatch(obj["sha"]):
            raise UpstreamError("Tag does not resolve to a full immutable SHA")
        if obj.get("type") == "commit":
            return obj["sha"]
        if obj.get("type") != "tag" or obj["sha"] in seen:
            raise UpstreamError("Tag is cyclic or does not resolve to a commit")
        seen.add(obj["sha"])
        url = API + "/git/tags/" + obj["sha"]
        value = get_json(url)
        if raw is not None:
            raw[url] = value
        obj = value.get("object") if isinstance(value, dict) else None
    raise UpstreamError("Annotated tag depth exceeds the safety limit")


def resolve_main(get_json, base, raw):
    url = base + "/git/ref/heads/main"
    value = get_json(url)
    raw[url] = value
    obj = value.get("object") if isinstance(value, dict) else None
    if not isinstance(value, dict) or value.get("ref") != "refs/heads/main" or not isinstance(obj, dict) or obj.get("type") != "commit" or not isinstance(obj.get("sha"), str) or not SHA.fullmatch(obj["sha"]):
        raise UpstreamError("main does not resolve to an immutable commit")
    return {"branch": "main", "commit": obj["sha"], "source_url": url}


def observe(get_json, max_pages=100, checked_at=None):
    """Read complete release pages; /latest is GitHub's stable-channel authority."""
    if type(max_pages) is not int or max_pages < 1:
        raise UpstreamError("max_pages must be positive")
    raw, releases, seen = {}, [], set()
    for page in range(1, max_pages + 1):
        url = f"{API}/releases?per_page=100&page={page}"
        values = get_json(url)
        raw[url] = values
        if not isinstance(values, list) or len(values) > 100:
            raise UpstreamError("Release pagination returned a malformed page")
        for release in values:
            if validate_release(release):
                tag = release["tag_name"]
                if tag in seen:
                    raise UpstreamError("Release pages overlap or changed during pagination; retry the observation")
                seen.add(tag)
                releases.append(release)
        if len(values) < 100:
            break
    else:
        raise UpstreamError("Release pagination limit reached; refusing an incomplete latest-version result")
    if not releases:
        raise UpstreamError("Official API contains no public releases")
    latest_url = API + "/releases/latest"
    try:
        stable = get_json(latest_url)
    except UpstreamError as error:
        if error.status != 404 or any(not r["prerelease"] for r in releases):
            raise
        stable = None
    raw[latest_url] = stable
    warnings = []
    if stable is not None:
        if not validate_release(stable) or stable["prerelease"]:
            raise UpstreamError("The /latest endpoint did not return a stable public release")
        matches = [r for r in releases if r["tag_name"] == stable["tag_name"]]
        if len(matches) != 1 or any(matches[0].get(k) != stable.get(k) for k in ("id", "draft", "prerelease", "published_at")):
            raise UpstreamError("The /latest endpoint disagrees with the release list; retry the observation")
        by_time = max((r for r in releases if not r["prerelease"]), key=lambda r: timestamp(r["published_at"]))
        if stable["tag_name"] != by_time["tag_name"]:
            warnings.append("GitHub /latest differs from the most recently published stable release; /latest remains the stable-channel authority")
    prereleases = [r for r in releases if r["prerelease"]]
    selected = {
        "stable": stable,
        "prerelease": max(prereleases, key=lambda r: timestamp(r["published_at"])) if prereleases else None,
        "latest_published": max(releases, key=lambda r: timestamp(r["published_at"])),
    }
    commits, channels = {}, {}
    for channel, release in selected.items():
        if release is None:
            channels[channel] = None
            continue
        tag = release["tag_name"]
        if tag not in commits:
            commits[tag] = resolve_tag(get_json, tag, raw)
        channels[channel] = {
            "tag": tag, "commit": commits[tag], "prerelease": release["prerelease"],
            "published_at": release["published_at"],
            "source_url": API + "/releases/tags/" + quote(tag, safe=""),
            "html_url": "https://github.com/XTLS/Xray-core/releases/tag/" + quote(tag, safe=""),
        }
    observed_at = checked_at or utc_now()
    timestamp(observed_at)
    return {
        "checked_at": observed_at, "channels": channels,
        "main": resolve_main(get_json, API, raw),
        "documentation": resolve_main(get_json, DOCS_API, raw),
        "public_release_count": len(releases), "warnings": warnings, "raw": raw,
    }


def private_write(path, data, replace=False):
    path = Path(path)
    if path.is_symlink() or (path.exists() and not replace):
        raise UpstreamError("Refusing to overwrite an existing output or symlink")
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        if replace:
            os.replace(temporary, path)
        else:
            os.link(temporary, path)
            os.unlink(temporary)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def load_cache(path):
    path = Path(path)
    if path.is_symlink():
        raise UpstreamError("Refusing a symlink as an upstream cache")
    try:
        if path.stat().st_size > 64 * 1024 * 1024:
            raise ValueError
        value = json.loads(path.read_bytes())
        if value.get("schema_version") != 1 or value.get("payload_sha256") != sha256(canonical(value["payload"])):
            raise ValueError
        payload = value["payload"]
        timestamp(payload["checked_at"])
        if not all(isinstance(payload[k], dict) for k in ("channels", "main", "documentation", "raw")):
            raise ValueError
        for key in ("stable", "prerelease", "latest_published"):
            entry = payload["channels"][key]
            if entry is not None and (not isinstance(entry, dict) or not TAG.fullmatch(entry["tag"]) or not SHA.fullmatch(entry["commit"])):
                raise ValueError
        return payload
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        raise UpstreamError("Upstream cache is missing, malformed or modified; use a new cache path or explicitly remove the invalid cache") from None


def store_cache(path, payload):
    path = Path(path)
    if path.exists() or path.is_symlink():
        load_cache(path)  # A corrupt observation is not silently erased.
    value = {"schema_version": 1, "payload_sha256": sha256(canonical(payload)), "payload": payload}
    private_write(path, json.dumps(value, ensure_ascii=False, indent=2).encode() + b"\n", replace=True)


def _yaml_pin_mappings(text):
    """Read this project's plain scalar pin blocks, not arbitrary YAML syntax."""
    result, section, group = {}, None, None
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        top = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_-]*):\s*(?:#.*)?", line)
        if not line.startswith(" "):
            section = top[1] if top else None
            group = None
            if section in ("covered_versions", "repositories", "documentation"):
                if section in result:
                    raise UpstreamError("Duplicate source pin section")
                result[section] = {}
            continue
        if section not in result:
            continue
        match = re.fullmatch(r"( +)([A-Za-z_][A-Za-z0-9_-]*):(?: +(.*))?", line)
        if not match:
            continue
        indent, key, scalar = len(match[1]), match[2], match[3]
        if indent == 2 and section != "documentation":
            group = key if not scalar or scalar.lstrip().startswith("#") else None
            if group:
                if group in result[section]:
                    raise UpstreamError("Duplicate source pin group")
                result[section][group] = {}
            continue
        if (indent == 4 and group) or (indent == 2 and section == "documentation"):
            if key not in ("version", "commit"):
                continue
            if scalar is None:
                raise UpstreamError("Version pins must be scalar strings")
            scalar = scalar.split(" #", 1)[0].strip()
            if len(scalar) >= 2 and scalar[0] == scalar[-1] and scalar[0] in "\"'":
                scalar = scalar[1:-1]
            target = result[section] if section == "documentation" else result[section][group]
            if key in target:
                raise UpstreamError("Duplicate scalar version pin")
            target[key] = scalar
    return result


def read_source_pins(path):
    """Read maintained scalar YAML pins or an equivalent JSON mapping.

    Complex YAML serialization of pin blocks is intentionally rejected. Source
    extraction rules and other metadata are not interpreted or rewritten here.
    """
    text = Path(path).read_text(encoding="utf-8")
    value = json.loads(text) if text.lstrip().startswith("{") else _yaml_pin_mappings(text)
    if not isinstance(value, dict):
        raise UpstreamError("Source pins must be a mapping")
    covered, repos = value.get("covered_versions", {}), value.get("repositories", {})
    if not isinstance(covered, dict) or not isinstance(repos, dict):
        raise UpstreamError("Source pins use an unsupported mapping structure")
    result = {}
    for name, keys in (("stable", ("stable",)), ("prerelease", ("prerelease", "beta"))):
        entry = next((covered[k] for k in keys if k in covered), None)
        if entry is not None:
            if not isinstance(entry, dict) or not isinstance(entry.get("version"), str) or not TAG.fullmatch(entry["version"]) or not isinstance(entry.get("commit"), str) or not SHA.fullmatch(entry["commit"]):
                raise UpstreamError("Source release pin requires a scalar tag and full commit SHA")
            result[name] = {"tag": entry["version"], "commit": entry["commit"]}
    for name, entry in (("main", repos.get("core_dev", covered.get("dev"))), ("documentation", repos.get("docs", value.get("documentation")))):
        if entry is not None:
            if not isinstance(entry, dict) or not isinstance(entry.get("commit"), str) or not SHA.fullmatch(entry["commit"]):
                raise UpstreamError("Source branch pin requires a full commit SHA")
            result[name] = {"commit": entry["commit"]}
    if "stable" not in result:
        raise UpstreamError("No supported stable version pin found in sources file")
    return result


def make_report(payload, pins, offline=False):
    current = dict(payload["channels"], main=payload["main"], documentation=payload["documentation"])
    comparisons = {}
    for channel, pin in pins.items():
        observed = current.get(channel)
        comparisons[channel] = {
            "pinned": pin, "observed": observed,
            "matches": observed is not None and all(observed.get(k) == v for k, v in pin.items()),
        }
    return {
        "schema_version": 1, "mode": "offline-cache" if offline else "live-observation",
        "freshness": "unknown" if offline else "observed-at-checked_at",
        "checked_at": payload["checked_at"], "reported_at": utc_now(),
        "channels": payload["channels"], "main": payload["main"], "documentation": payload["documentation"],
        "pin_comparison": comparisons, "changes_detected": any(not c["matches"] for c in comparisons.values()),
        "configuration_support": "not_assessed",
        "scope": "Metadata observation only; matching pins do not prove configuration compatibility. Offline data does not establish the current latest release.",
        "warnings": payload.get("warnings", []),
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    check = sub.add_parser("check", help="Observe metadata; never update source pins")
    check.add_argument("--offline", action="store_true")
    check.add_argument("--cache", type=Path, default=DEFAULT_CACHE)
    check.add_argument("--sources", type=Path, default=ROOT / "sources.yaml")
    check.add_argument("--output", type=Path)
    check.add_argument("--max-pages", type=int, default=100)
    check.add_argument("--timeout", type=float, default=20)
    check.add_argument("--fail-on-change", action="store_true", help="Exit 1 when observed pins differ; normal successful observations exit 0")
    args = parser.parse_args(argv)
    try:
        pins = read_source_pins(args.sources)
        if args.offline:
            payload = load_cache(args.cache)
        else:
            payload = observe(HttpClient(args.timeout, os.environ.get("GITHUB_TOKEN")).json, max_pages=args.max_pages)
            store_cache(args.cache, payload)
        report = make_report(payload, pins, offline=args.offline)
        text = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
        if args.output:
            private_write(args.output, text.encode())
        else:
            print(text, end="")
        return 1 if args.fail_on_change and report["changes_detected"] else 0
    except (UpstreamError, OSError, ValueError, TypeError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
