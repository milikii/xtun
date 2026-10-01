#!/usr/bin/env python3
"""Conservative, reversible VLESS connection-link codec.

The official protocol guide points to XTLS/Xray-core#91 for the sharing proposal.
This module implements only a deliberately small connection-field subset; it is
not a claim of compatibility with any GUI client or a version/config validator.
Native JSON remains authoritative. In particular, XHTTP extra/downloadSettings,
ECH, custom headers, socket options and routing settings are not exported.

Canonicalization is explicit: method/network and transport aliases become
network; REALITY publicKey becomes password; WebSocket headers.Host becomes
host; the optional local outbound tag is limited to "proxy". Missing transport,
security and encryption use the sharing defaults raw, none and none. No other
configuration fields are silently discarded. Encoded links contain credentials.
"""

import argparse
import ipaddress
import json
from pathlib import Path
import re
import sys
from urllib.parse import quote, unquote_to_bytes, urlsplit
import uuid


class LinkUnsupported(ValueError):
    """The input is malformed or cannot be represented without losing fields."""


_TRANSPORTS = {
    "raw": "raw", "tcp": "raw", "xhttp": "xhttp", "splithttp": "xhttp",
    "ws": "ws", "websocket": "ws", "grpc": "grpc", "httpupgrade": "httpupgrade",
}
_SETTINGS = {
    "raw": ("rawSettings", "tcpSettings"),
    "xhttp": ("xhttpSettings", "splithttpSettings"),
    "ws": ("wsSettings",), "grpc": ("grpcSettings",),
    "httpupgrade": ("httpupgradeSettings",),
}
_TRANSPORT_FIELDS = {
    "raw": set(), "xhttp": {"host", "path", "mode"},
    "ws": {"host", "path"}, "grpc": {"serviceName"},
    "httpupgrade": {"host", "path"},
}
_XHTTP_MODES = {"", "auto", "packet-up", "stream-up", "stream-one"}
_FLOWS = {"", "xtls-rprx-vision", "xtls-rprx-vision-udp443"}
_CONTROL = re.compile(r"[\x00-\x1f\x7f]")
_BAD_ESCAPE = re.compile(r"%(?![0-9a-fA-F]{2})")


def _object(value, allowed, location):
    if not isinstance(value, dict) or any(not isinstance(key, str) for key in value):
        raise LinkUnsupported(f"{location} must be an object")
    if set(value) - set(allowed):
        raise LinkUnsupported(f"{location} contains fields outside the lossless link subset; use native JSON")
    return value


def _string(value, location, *, empty=True):
    if not isinstance(value, str) or _CONTROL.search(value) or (not empty and not value):
        raise LinkUnsupported(f"{location} must be a string without control characters")
    try:
        value.encode("utf-8", errors="strict")
    except UnicodeError:
        raise LinkUnsupported(f"{location} contains invalid Unicode") from None
    return value


def _one(value, location):
    if not isinstance(value, list) or len(value) != 1:
        raise LinkUnsupported(f"{location} must contain exactly one item; use native JSON otherwise")
    return value[0]


def _identifier(value):
    value = _string(value, "VLESS id", empty=False)
    try:
        normalized = str(uuid.UUID(value))
    except ValueError:
        raise LinkUnsupported("Sharing requires a UUID; map custom Xray identifiers with the target core first") from None
    if value.lower() != normalized:
        raise LinkUnsupported("Sharing requires a hyphenated UUID")
    return normalized


def _port(value):
    if type(value) is not int or not 1 <= value <= 65535:
        raise LinkUnsupported("The endpoint port must be an integer from 1 to 65535")
    return value


def _address(value):
    value = _string(value, "Endpoint address", empty=False)
    if ":" in value:
        try:
            if "%" in value:
                raise ValueError
            ipaddress.IPv6Address(value)
        except ValueError:
            raise LinkUnsupported("The endpoint must be an unscoped IPv6 address or an ASCII hostname") from None
        return value
    if not value.isascii() or len(value) > 253:
        raise LinkUnsupported("Use an ASCII hostname (IDNA form for an internationalized domain)")
    labels = value.removesuffix(".").split(".")
    if not all(re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label) for label in labels):
        raise LinkUnsupported("The endpoint contains an invalid hostname")
    if re.fullmatch(r"[0-9.]+", value):
        try:
            ipaddress.IPv4Address(value)
        except ValueError:
            raise LinkUnsupported("The endpoint contains an invalid IPv4 address") from None
    return value


def _alias(value, names, location, default=None):
    present = [name for name in names if name in value]
    if len(present) > 1:
        raise LinkUnsupported(f"{location} contains competing aliases; choose one explicitly")
    return value[present[0]] if present else default


def _transport(stream):
    name = _string(_alias(stream, ("network", "method"), "streamSettings", "raw"), "Transport")
    if name not in _TRANSPORTS:
        raise LinkUnsupported("This transport has no supported lossless link mapping; use native JSON")
    return _TRANSPORTS[name]


def _flow(value):
    value = _string(value, "VLESS flow")
    if value not in _FLOWS:
        raise LinkUnsupported("This flow has no supported link mapping")
    return value


def _check_transport_fields(transport, settings):
    allowed = _TRANSPORT_FIELDS[transport]
    if transport == "ws":
        settings = dict(_object(settings, allowed | {"headers"}, "wsSettings"))
        if "headers" in settings:
            headers = settings.pop("headers")
            if not isinstance(headers, dict) or len(headers) != 1:
                raise LinkUnsupported("Only the deprecated WebSocket Host header has a lossless alias mapping")
            name = next(iter(headers))
            if not isinstance(name, str) or name.lower() != "host" or "host" in settings:
                raise LinkUnsupported("Custom or competing WebSocket headers require native JSON")
            settings["host"] = headers[name]
    _object(settings, allowed, "Transport settings")
    result = {key: _string(value, "Transport field") for key, value in settings.items()}
    if "mode" in result and result["mode"] not in _XHTTP_MODES:
        raise LinkUnsupported("This XHTTP mode has no supported link mapping")
    return result


def encode_uri(outbound: dict, label: str) -> str:
    """Encode supported connection fields, rejecting unrepresentable information.

    A local tag of ``proxy`` is accepted and decode returns that canonical tag.
    Other tags, routing/mux options and non-connection metadata require JSON.
    ``encryption`` is carried as an opaque string, not validated or advertised as
    supported by a receiving application. No configuration or credential values
    are included in error messages.
    """
    _object(outbound, {"tag", "protocol", "settings", "streamSettings"}, "Outbound")
    if outbound.get("protocol") != "vless" or outbound.get("tag", "proxy") != "proxy":
        raise LinkUnsupported("Only VLESS connection outbounds with the optional local tag 'proxy' are supported")
    settings = _object(outbound.get("settings"), {"vnext"}, "VLESS settings")
    endpoint = _object(_one(settings.get("vnext"), "vnext"), {"address", "port", "users"}, "Endpoint")
    user = _object(_one(endpoint.get("users"), "users"), {"id", "encryption", "flow"}, "VLESS user")
    address, port = _address(endpoint.get("address")), _port(endpoint.get("port"))
    identifier = _identifier(user.get("id"))
    label = _string(label, "Link label")
    stream = _object(outbound.get("streamSettings", {}), {
        "network", "method", "security", "tlsSettings", "realitySettings",
        *(name for aliases in _SETTINGS.values() for name in aliases),
    }, "streamSettings")
    transport = _transport(stream)
    security = _string(stream.get("security", "none"), "Transport security")
    if security not in {"none", "tls", "reality"}:
        raise LinkUnsupported("This transport security has no supported link mapping")
    for name in (name for aliases in _SETTINGS.values() for name in aliases):
        if name in stream and name not in _SETTINGS[transport]:
            raise LinkUnsupported("Settings for a different transport cannot be represented")
    transport_settings = _alias(stream, _SETTINGS[transport], "Transport settings", {})
    fields = _check_transport_fields(transport, transport_settings)
    query = {
        "encryption": _string(user.get("encryption", "none"), "VLESS encryption", empty=False),
        "security": security, "type": "tcp" if transport == "raw" else transport,
    }
    if "flow" in user:
        query["flow"] = _flow(user["flow"])
    if security == "none":
        if "tlsSettings" in stream or "realitySettings" in stream:
            raise LinkUnsupported("Inactive TLS/REALITY settings cannot be represented")
    else:
        name = "tlsSettings" if security == "tls" else "realitySettings"
        other = "realitySettings" if security == "tls" else "tlsSettings"
        if other in stream:
            raise LinkUnsupported("Competing TLS/REALITY settings cannot be represented")
        allowed = {"serverName", "fingerprint", "alpn"} if security == "tls" else {
            "serverName", "fingerprint", "password", "publicKey", "shortId",
        }
        tls = _object(stream.get(name, {}), allowed, name)
        for native, uri in (("serverName", "sni"), ("fingerprint", "fp")):
            if native in tls:
                query[uri] = _string(tls[native], "TLS/REALITY field")
        if security == "tls" and "alpn" in tls:
            if not isinstance(tls["alpn"], list):
                raise LinkUnsupported("ALPN must be an array")
            alpns = [_string(item, "ALPN", empty=False) for item in tls["alpn"]]
            if any("," in item for item in alpns):
                raise LinkUnsupported("ALPN entries containing commas have no lossless mapping")
            query["alpn"] = ",".join(alpns)
        if security == "reality":
            query["pbk"] = _string(_alias(tls, ("password", "publicKey"), name), "REALITY credential", empty=False)
            if "shortId" in tls:
                short_id = _string(tls["shortId"], "REALITY shortId")
                if len(short_id) % 2 or not re.fullmatch(r"[0-9a-fA-F]{0,16}", short_id):
                    raise LinkUnsupported("REALITY shortId must be even-length hexadecimal, at most 16 characters")
                query["sid"] = short_id
    query.update(fields)
    host = f"[{address}]" if ":" in address else address
    encoded = "&".join(quote(key, safe="") + "=" + quote(value, safe="") for key, value in query.items())
    return f"vless://{identifier}@{host}:{port}?{encoded}#{quote(label, safe='')}"


def _unquote(value):
    if _BAD_ESCAPE.search(value):
        raise LinkUnsupported("The link contains malformed percent encoding")
    try:
        return _string(unquote_to_bytes(value).decode("utf-8", errors="strict"), "Link field")
    except UnicodeError:
        raise LinkUnsupported("The link contains invalid UTF-8") from None


def _query(value):
    result = {}
    if not value:
        return result
    for item in value.split("&"):
        if "=" not in item or "+" in item:
            raise LinkUnsupported("Query fields require key=value and percent encoding for reserved characters")
        raw_key, raw_value = item.split("=", 1)
        key, content = _unquote(raw_key), _unquote(raw_value)
        if not key or key in result:
            raise LinkUnsupported("The link contains empty or duplicate query keys")
        result[key] = content
    if "fingerprint" in result:
        if "fp" in result:
            raise LinkUnsupported("The link contains competing fingerprint aliases")
        result["fp"] = result.pop("fingerprint")
    return result


def decode_uri(uri: str) -> dict:
    """Decode the supported sharing subset to canonical native JSON and a label.

    Unknown fields, conflicting aliases and unsupported transports are rejected.
    Defaults are explicit and the local outbound tag is always ``proxy``. This
    function does not check a link's credentials or test a network connection.
    """
    uri = _string(uri, "URI", empty=False)
    if any(char.isspace() for char in uri) or not uri.startswith("vless://"):
        raise LinkUnsupported("A VLESS URI without raw whitespace is required")
    try:
        parts = urlsplit(uri)
    except ValueError:
        raise LinkUnsupported("The VLESS URI has a malformed authority") from None
    if parts.scheme != "vless" or parts.path or parts.netloc.count("@") != 1:
        raise LinkUnsupported("The VLESS URI must contain one UUID and an endpoint, without a URL path")
    identifier, authority = parts.netloc.split("@")
    identifier = _identifier(_unquote(identifier))
    if authority.startswith("["):
        match = re.fullmatch(r"\[([^\]]+)\]:([0-9]+)", authority)
    else:
        match = re.fullmatch(r"([^:]+):([0-9]+)", authority)
    if not match:
        raise LinkUnsupported("An explicit endpoint port and brackets around IPv6 are required")
    address, raw_port = match.groups()
    address = _address(address)
    if authority.startswith("[") != (":" in address):
        raise LinkUnsupported("Only IPv6 addresses may be bracketed")
    if len(raw_port) > 5:
        raise LinkUnsupported("The endpoint port is out of range")
    port = _port(int(raw_port))
    query = _query(parts.query)
    transport_name = query.pop("type", "tcp")
    if transport_name not in _TRANSPORTS:
        raise LinkUnsupported("This link transport is unsupported; use native JSON")
    transport = _TRANSPORTS[transport_name]
    security = query.pop("security", "none")
    if security not in {"none", "tls", "reality"}:
        raise LinkUnsupported("This link security is unsupported")
    user = {"id": identifier, "encryption": _string(query.pop("encryption", "none"), "VLESS encryption", empty=False)}
    if "flow" in query:
        user["flow"] = _flow(query.pop("flow"))
    stream = {"network": transport, "security": security}
    tls = {}
    if security != "none":
        for native, key in (("serverName", "sni"), ("fingerprint", "fp")):
            if key in query:
                tls[native] = query.pop(key)
        if security == "tls" and "alpn" in query:
            value = query.pop("alpn")
            tls["alpn"] = value.split(",") if value else []
            if any(not item for item in tls["alpn"]):
                raise LinkUnsupported("ALPN contains an empty protocol")
        if security == "reality":
            tls["password"] = _string(query.pop("pbk", None), "REALITY credential", empty=False)
            if "sid" in query:
                tls["shortId"] = query.pop("sid")
        stream["tlsSettings" if security == "tls" else "realitySettings"] = tls
    fields = {key: query.pop(key) for key in sorted(_TRANSPORT_FIELDS[transport]) if key in query}
    if fields:
        stream[_SETTINGS[transport][0]] = fields
    if transport == "raw" and "headerType" in query:
        if query.pop("headerType") != "none":
            raise LinkUnsupported("Only the RAW no-header link form is supported")
    if query:
        raise LinkUnsupported("The link contains fields outside the lossless subset; use native JSON")
    outbound = {
        "tag": "proxy", "protocol": "vless",
        "settings": {"vnext": [{"address": address, "port": port, "users": [user]}]},
        "streamSettings": stream,
    }
    label = _unquote(parts.fragment)
    encode_uri(outbound, label)
    return {"outbound": outbound, "label": label}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    encode = commands.add_parser("encode", help="Encode an outbound JSON file; stdout contains credentials")
    encode.add_argument("file", type=Path)
    encode.add_argument("--label", default="VLESS")
    decode = commands.add_parser("decode", help="Read one URI from stdin; stdout contains credentials")
    args = parser.parse_args()
    try:
        if args.command == "encode":
            print(encode_uri(json.loads(args.file.read_text()), args.label))
        else:
            print(json.dumps(decode_uri(sys.stdin.read().strip()), ensure_ascii=False, indent=2))
    except (LinkUnsupported, OSError, json.JSONDecodeError) as error:
        message = str(error) if isinstance(error, LinkUnsupported) else "Could not read valid input"
        print(f"Link not exported: {message}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
