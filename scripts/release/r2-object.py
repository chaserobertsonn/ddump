#!/usr/bin/env python3
"""Minimal Cloudflare R2 object client using AWS Signature V4.

This avoids third-party Actions and runtime package installs in release jobs.
Secrets are read from the environment and are never printed.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import hmac
import os
import sys
import urllib.error
import urllib.parse
import urllib.request


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def env(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        fail(f"missing required environment variable: {name}")
    return value


def signing_key(secret_key: str, date: str, region: str, service: str) -> bytes:
    key = ("AWS4" + secret_key).encode()
    for part in (date, region, service, "aws4_request"):
        key = hmac.new(key, part.encode(), hashlib.sha256).digest()
    return key


def canonical_headers(headers: dict[str, str]) -> tuple[str, str]:
    normalized = {k.lower(): " ".join(v.strip().split()) for k, v in headers.items()}
    names = sorted(normalized)
    canonical = "".join(f"{name}:{normalized[name]}\n" for name in names)
    return canonical, ";".join(names)


def request(method: str, bucket: str, key: str, body: bytes, extra_headers: dict[str, str]) -> urllib.request.Request:
    account_id = env("DDUMP_R2_ACCOUNT_ID")
    access_key = env("DDUMP_R2_ACCESS_KEY_ID")
    secret_key = env("DDUMP_R2_SECRET_ACCESS_KEY")
    host = f"{account_id}.r2.cloudflarestorage.com"
    encoded_key = "/".join(urllib.parse.quote(part, safe="") for part in key.split("/"))
    path = f"/{bucket}/{encoded_key}"
    url = f"https://{host}{path}"
    now = dt.datetime.utcnow()
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = now.strftime("%Y%m%d")
    payload_hash = hashlib.sha256(body).hexdigest()
    headers = {
        "Host": host,
        "X-Amz-Content-Sha256": payload_hash,
        "X-Amz-Date": amz_date,
        **extra_headers,
    }
    canonical, signed_names = canonical_headers(headers)
    canonical_request = "\n".join(
        [method, path, "", canonical, signed_names, payload_hash]
    )
    scope = f"{date_stamp}/auto/s3/aws4_request"
    string_to_sign = "\n".join(
        [
            "AWS4-HMAC-SHA256",
            amz_date,
            scope,
            hashlib.sha256(canonical_request.encode()).hexdigest(),
        ]
    )
    signature = hmac.new(
        signing_key(secret_key, date_stamp, "auto", "s3"),
        string_to_sign.encode(),
        hashlib.sha256,
    ).hexdigest()
    headers["Authorization"] = (
        f"AWS4-HMAC-SHA256 Credential={access_key}/{scope}, "
        f"SignedHeaders={signed_names}, Signature={signature}"
    )
    return urllib.request.Request(url, data=body if method in {"PUT"} else None, headers=headers, method=method)


def perform(req: urllib.request.Request, output: str | None) -> None:
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            data = response.read()
            if output:
                with open(output, "wb") as handle:
                    handle.write(data)
            etag = response.headers.get("ETag", "")
            length = response.headers.get("Content-Length", "")
            print(f"status={response.status}")
            if etag:
                print(f"etag={etag}")
            if length:
                print(f"content_length={length}")
    except urllib.error.HTTPError as exc:
        details = exc.read().decode("utf-8", "replace")[:400]
        fail(f"R2 request failed with HTTP {exc.code}: {details}")


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    put = sub.add_parser("put")
    put.add_argument("--key", required=True)
    put.add_argument("--file", required=True)
    put.add_argument("--content-type", required=True)
    put.add_argument("--cache-control", required=True)
    put.add_argument("--if-none-match")
    put.add_argument("--if-match")

    get = sub.add_parser("get")
    get.add_argument("--key", required=True)
    get.add_argument("--output", required=True)

    head = sub.add_parser("head")
    head.add_argument("--key", required=True)

    args = parser.parse_args()
    bucket = env("DDUMP_R2_BUCKET")

    if args.command == "put":
        with open(args.file, "rb") as handle:
            body = handle.read()
        headers = {
            "Content-Type": args.content_type,
            "Cache-Control": args.cache_control,
        }
        if args.if_none_match:
            headers["If-None-Match"] = args.if_none_match
        if args.if_match:
            headers["If-Match"] = args.if_match
        perform(request("PUT", bucket, args.key, body, headers), None)
    elif args.command == "get":
        perform(request("GET", bucket, args.key, b"", {}), args.output)
    elif args.command == "head":
        perform(request("HEAD", bucket, args.key, b"", {}), None)


if __name__ == "__main__":
    main()
