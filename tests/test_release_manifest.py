import os
import json
import subprocess
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
GENERATOR = PROJECT_ROOT / "scripts" / "generate_release_manifest.py"
APP_BUILD_SCRIPT = PROJECT_ROOT / "MeetingBotMenuBarApp" / "build_release_app.sh"
UNINSTALLER_BUILD_SCRIPT = PROJECT_ROOT / "MeetingBotUninstaller" / "build_uninstaller_app.sh"


def create_payload(
    tmp_path: Path,
    signed: bool = False,
    security_mode: str = "development",
) -> Path:
    payload = tmp_path / "payload"
    scripts = payload / "scripts"
    scripts.mkdir(parents=True)
    (payload / ".meetingbot-packaged-payload").write_text("", encoding="utf-8")
    (payload / "bot.py").write_text("print('ok')\n", encoding="utf-8")
    install_script = scripts / "install.sh"
    install_script.write_bytes((PROJECT_ROOT / "scripts" / "install.sh").read_bytes())
    command = [
            sys.executable,
            str(GENERATOR),
            "payload",
            "--root",
            str(payload),
            "--output",
            str(payload / "release-manifest.json"),
            "--checksums",
            str(payload / "payload-files.sha256"),
            "--app-version",
            "0.5.0",
            "--build-number",
            "32",
            "--payload-version",
            "test-payload",
            "--security-mode",
            security_mode,
        ]
    if signed:
        private_key = tmp_path / "release-private.pem"
        public_key = tmp_path / "release-public.pem"
        subprocess.run(
            [
                "/usr/bin/openssl",
                "ecparam",
                "-name",
                "prime256v1",
                "-genkey",
                "-noout",
                "-out",
                str(private_key),
            ],
            check=True,
        )
        subprocess.run(
            [
                "/usr/bin/openssl",
                "ec",
                "-in",
                str(private_key),
                "-pubout",
                "-out",
                str(public_key),
            ],
            check=True,
        )
        command.extend(
            [
                "--signing-key",
                str(private_key),
                "--signature",
                str(payload / "release-manifest.sig"),
            ]
        )
    subprocess.run(
        command,
        check=True,
    )
    return payload


def verify(payload: Path) -> subprocess.CompletedProcess:
    manifest = json.loads((payload / "release-manifest.json").read_text(encoding="utf-8"))
    environment = os.environ.copy()
    environment["MEETINGBOT_PAYLOAD_TRUST_MODE"] = manifest["security_mode"]
    public_key = payload.parent / "release-public.pem"
    if public_key.exists():
        environment["MEETINGBOT_RELEASE_PUBLIC_KEY_PATH"] = str(public_key)
    return subprocess.run(
        ["/bin/bash", str(payload / "scripts" / "install.sh"), "--verify-payload-only"],
        cwd=payload,
        capture_output=True,
        text=True,
        env=environment,
    )


def test_payload_manifest_contains_version_and_verifies(tmp_path):
    payload = create_payload(tmp_path)
    manifest = json.loads((payload / "release-manifest.json").read_text(encoding="utf-8"))

    result = verify(payload)

    assert result.returncode == 0, result.stderr
    assert manifest["app_version"] == "0.5.0"
    assert manifest["build_number"] == "32"
    assert manifest["security_mode"] == "development"
    assert manifest["signature"]["status"] == "unsigned"
    assert "安装载荷验证完成" in result.stdout


def test_payload_verification_rejects_tampered_file(tmp_path):
    payload = create_payload(tmp_path)
    (payload / "bot.py").write_text("print('tampered')\n", encoding="utf-8")

    result = verify(payload)

    assert result.returncode != 0
    assert "code=PAYLOAD_INTEGRITY_FAILED" in result.stderr
    assert "file_hash_mismatch" in result.stderr


def test_signed_distribution_payload_verifies_and_rejects_modified_manifest(tmp_path):
    payload = create_payload(tmp_path, signed=True, security_mode="distribution")

    assert verify(payload).returncode == 0
    manifest_path = payload / "release-manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["generated_at"] = "2000-01-01T00:00:00+00:00"
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    result = verify(payload)

    assert result.returncode != 0
    assert "signature_invalid" in result.stderr


def test_payload_verification_rejects_unlisted_file(tmp_path):
    payload = create_payload(tmp_path)
    (payload / "sitecustomize.py").write_text("raise SystemExit('unexpected')\n", encoding="utf-8")

    result = verify(payload)

    assert result.returncode != 0
    assert "file_set_mismatch" in result.stderr


def test_payload_verification_rejects_symbolic_link(tmp_path):
    payload = create_payload(tmp_path)
    (payload / "unexpected-link").symlink_to(payload / "bot.py")

    result = verify(payload)

    assert result.returncode != 0
    assert "unsupported_file_type" in result.stderr


def test_payload_verification_rejects_embedded_public_key(tmp_path):
    payload = create_payload(tmp_path)
    (payload / "release-public-key.pem").write_text("untrusted", encoding="utf-8")

    result = verify(payload)

    assert result.returncode != 0
    assert "embedded_trust_anchor" in result.stderr


def test_distribution_payload_requires_signature(tmp_path):
    payload = create_payload(tmp_path, security_mode="distribution")

    result = verify(payload)

    assert result.returncode != 0
    assert "incomplete_signature" in result.stderr


def test_manifest_generation_rejects_symbolic_link(tmp_path):
    payload = tmp_path / "payload"
    payload.mkdir()
    target = payload / "target.txt"
    target.write_text("target", encoding="utf-8")
    (payload / "link.txt").symlink_to(target)

    result = subprocess.run(
        [
            sys.executable,
            str(GENERATOR),
            "payload",
            "--root",
            str(payload),
            "--output",
            str(payload / "release-manifest.json"),
            "--checksums",
            str(payload / "payload-files.sha256"),
            "--app-version",
            "0.5.0",
            "--build-number",
            "32",
            "--payload-version",
            "test-payload",
        ],
        capture_output=True,
        text=True,
    )

    assert result.returncode != 0
    assert "symbolic link" in result.stderr


def test_development_build_security_preflight_succeeds():
    environment = os.environ.copy()
    environment["MEETINGBOT_BUILD_SECURITY_MODE"] = "development"

    result = subprocess.run(
        ["/bin/bash", str(APP_BUILD_SCRIPT), "--security-preflight-only"],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        env=environment,
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "development"


def test_distribution_build_security_preflight_fails_closed_without_credentials():
    environment = os.environ.copy()
    for key in [
        "MEETINGBOT_RELEASE_SIGNING_KEY",
        "MEETINGBOT_RELEASE_PUBLIC_KEY",
        "MEETINGBOT_CODESIGN_IDENTITY",
        "MEETINGBOT_NOTARYTOOL_PROFILE",
    ]:
        environment.pop(key, None)
    environment["MEETINGBOT_BUILD_SECURITY_MODE"] = "distribution"

    result = subprocess.run(
        ["/bin/bash", str(APP_BUILD_SCRIPT), "--security-preflight-only"],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        env=environment,
    )

    assert result.returncode != 0
    assert "正式构建必须配置" in result.stderr


def test_uninstaller_development_security_preflight_succeeds():
    environment = os.environ.copy()
    environment["MEETINGBOT_BUILD_SECURITY_MODE"] = "development"

    result = subprocess.run(
        ["/bin/bash", str(UNINSTALLER_BUILD_SCRIPT), "--security-preflight-only"],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        env=environment,
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "development"


def test_uninstaller_distribution_preflight_fails_closed_without_identity():
    environment = os.environ.copy()
    environment.pop("MEETINGBOT_CODESIGN_IDENTITY", None)
    environment["MEETINGBOT_BUILD_SECURITY_MODE"] = "distribution"

    result = subprocess.run(
        ["/bin/bash", str(UNINSTALLER_BUILD_SCRIPT), "--security-preflight-only"],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        env=environment,
    )

    assert result.returncode != 0
    assert "正式构建必须配置" in result.stderr
