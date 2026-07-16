import json
import subprocess
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
GENERATOR = PROJECT_ROOT / "scripts" / "generate_release_manifest.py"


def create_payload(tmp_path: Path, signed: bool = False) -> Path:
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
        ]
    if signed:
        private_key = tmp_path / "release-private.pem"
        public_key = payload / "release-public-key.pem"
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
    return subprocess.run(
        ["/bin/bash", str(payload / "scripts" / "install.sh"), "--verify-payload-only"],
        cwd=payload,
        capture_output=True,
        text=True,
    )


def test_payload_manifest_contains_version_and_verifies(tmp_path):
    payload = create_payload(tmp_path)
    manifest = json.loads((payload / "release-manifest.json").read_text(encoding="utf-8"))

    result = verify(payload)

    assert result.returncode == 0, result.stderr
    assert manifest["app_version"] == "0.5.0"
    assert manifest["build_number"] == "32"
    assert manifest["signature"]["status"] == "unsigned"
    assert "安装载荷验证完成" in result.stdout


def test_payload_verification_rejects_tampered_file(tmp_path):
    payload = create_payload(tmp_path)
    (payload / "bot.py").write_text("print('tampered')\n", encoding="utf-8")

    result = verify(payload)

    assert result.returncode != 0
    assert "code=PAYLOAD_INTEGRITY_FAILED" in result.stderr
    assert "file_hash_mismatch" in result.stderr


def test_signed_payload_verifies_and_rejects_modified_manifest(tmp_path):
    payload = create_payload(tmp_path, signed=True)

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
