#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import stat
import subprocess
import unicodedata
from datetime import datetime, timezone
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def sign_manifest(manifest: Path, signature: Path, signing_key: str) -> None:
    subprocess.run(
        [
            "/usr/bin/openssl",
            "dgst",
            "-sha256",
            "-sign",
            signing_key,
            "-out",
            str(signature),
            str(manifest),
        ],
        check=True,
    )


def payload_manifest(args: argparse.Namespace) -> None:
    root = Path(args.root).resolve()
    manifest = Path(args.output).resolve()
    checksums = Path(args.checksums).resolve()
    signature = Path(args.signature).resolve() if args.signature else None
    excluded = {manifest, checksums}
    if signature:
        excluded.add(signature)

    files = []
    normalized_paths = set()
    for path in root.rglob("*"):
        mode = path.lstat().st_mode
        relative = path.relative_to(root).as_posix()
        if stat.S_ISLNK(mode):
            raise SystemExit(f"payload contains a symbolic link: {relative}")
        if stat.S_ISDIR(mode):
            continue
        if not stat.S_ISREG(mode):
            raise SystemExit(f"payload contains an unsupported file type: {relative}")
        if path.resolve() in excluded:
            continue
        if "\n" in relative or "\r" in relative or "\\" in relative:
            raise SystemExit(f"payload contains an unsafe path: {relative!r}")
        normalized = unicodedata.normalize("NFC", relative).casefold()
        if normalized in normalized_paths:
            raise SystemExit(f"payload contains a conflicting path: {relative}")
        normalized_paths.add(normalized)
        files.append(path)
    files.sort(key=lambda path: path.relative_to(root).as_posix())
    checksum_lines = []
    total_bytes = 0
    for path in files:
        relative = path.relative_to(root).as_posix()
        size = path.stat().st_size
        total_bytes += size
        checksum_lines.append(f"{sha256(path)}  {relative}")
    checksums.write_text("\n".join(checksum_lines) + "\n", encoding="utf-8")

    signing_key = args.signing_key or os.environ.get("MEETINGBOT_RELEASE_SIGNING_KEY", "")
    payload = {
        "schema_version": 1,
        "kind": "meetingbot-payload",
        "security_mode": args.security_mode,
        "app_version": args.app_version,
        "build_number": args.build_number,
        "payload_version": args.payload_version,
        "minimum_macos": args.minimum_macos,
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "file_count": len(files),
        "total_bytes": total_bytes,
        "checksum_file": checksums.name,
        "checksum_file_sha256": sha256(checksums),
        "signature": {
            "algorithm": "ECDSA-P256-SHA256",
            "status": "signed" if signing_key else "unsigned",
        },
    }
    write_json(manifest, payload)
    if signing_key:
        if not signature:
            raise SystemExit("--signature is required when a signing key is configured")
        sign_manifest(manifest, signature, signing_key)


def artifact_manifest(args: argparse.Namespace) -> None:
    artifact = Path(args.artifact).resolve()
    output = Path(args.output).resolve()
    signing_key = args.signing_key or os.environ.get("MEETINGBOT_RELEASE_SIGNING_KEY", "")
    payload = {
        "schema_version": 1,
        "kind": "meetingbot-release",
        "channel": args.channel,
        "app_version": args.app_version,
        "build_number": args.build_number,
        "minimum_macos": args.minimum_macos,
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "artifact": {
            "filename": artifact.name,
            "size": artifact.stat().st_size,
            "sha256": sha256(artifact),
            "download_url": args.download_url,
        },
        "signature": {
            "algorithm": "ECDSA-P256-SHA256",
            "status": "signed" if signing_key else "unsigned",
        },
    }
    write_json(output, payload)
    if signing_key:
        signature = Path(args.signature).resolve() if args.signature else output.with_suffix(".sig")
        sign_manifest(output, signature, signing_key)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description="Generate verifiable MeetingBot release metadata")
    subparsers = root.add_subparsers(dest="command", required=True)

    payload = subparsers.add_parser("payload")
    payload.add_argument("--root", required=True)
    payload.add_argument("--output", required=True)
    payload.add_argument("--checksums", required=True)
    payload.add_argument("--signature")
    payload.add_argument("--signing-key")
    payload.add_argument("--app-version", required=True)
    payload.add_argument("--build-number", required=True)
    payload.add_argument("--payload-version", required=True)
    payload.add_argument(
        "--security-mode",
        choices=["development", "distribution"],
        default="development",
    )
    payload.add_argument("--minimum-macos", default="14.0")
    payload.set_defaults(handler=payload_manifest)

    artifact = subparsers.add_parser("artifact")
    artifact.add_argument("--artifact", required=True)
    artifact.add_argument("--output", required=True)
    artifact.add_argument("--signature")
    artifact.add_argument("--signing-key")
    artifact.add_argument("--app-version", required=True)
    artifact.add_argument("--build-number", required=True)
    artifact.add_argument("--minimum-macos", default="14.0")
    artifact.add_argument("--channel", default="stable")
    artifact.add_argument("--download-url", default="")
    artifact.set_defaults(handler=artifact_manifest)
    return root


def main() -> None:
    args = parser().parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()
