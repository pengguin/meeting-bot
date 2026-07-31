import os
import subprocess
from pathlib import Path

from meetingbot_config import resolve_tool_path


REPO_ROOT = Path(__file__).resolve().parents[1]
INSTALL_SCRIPT = REPO_ROOT / "scripts" / "install.sh"
XCODE_PROJECT = REPO_ROOT / "MeetingBotMenuBarApp" / "MeetingBotMenuBarApp.xcodeproj" / "project.pbxproj"
SWIFT_SOURCE_DIR = REPO_ROOT / "MeetingBotMenuBarApp" / "MeetingBotMenuBarApp"


def detect_exclusive_install_root(install_dir: Path, source_root: Path) -> str:
    command = """
source "$1"
INSTALL_DIR="$2"
SOURCE_ROOT="$3"
INSTALL_ROOT_EXCLUSIVE=0
detect_install_root_ownership
printf '%s' "$INSTALL_ROOT_EXCLUSIVE"
"""
    environment = os.environ.copy()
    environment["MEETINGBOT_INSTALL_LIBRARY_ONLY"] = "1"
    result = subprocess.run(
        ["/bin/bash", "-c", command, "meetingbot-test", str(INSTALL_SCRIPT), str(install_dir), str(source_root)],
        check=True,
        capture_output=True,
        text=True,
        cwd=REPO_ROOT,
        env=environment,
    )
    return result.stdout


def test_nonempty_custom_install_root_is_not_marked_exclusive(tmp_path):
    install_dir = tmp_path / "shared"
    install_dir.mkdir()
    (install_dir / "unrelated.txt").write_text("keep", encoding="utf-8")

    assert detect_exclusive_install_root(install_dir, REPO_ROOT) == "0"


def test_empty_custom_install_root_is_marked_exclusive(tmp_path):
    install_dir = tmp_path / "dedicated"
    install_dir.mkdir()

    assert detect_exclusive_install_root(install_dir, REPO_ROOT) == "1"


def test_source_checkout_is_never_marked_exclusive(tmp_path):
    source_root = tmp_path / "source"
    source_root.mkdir()
    (source_root / "bot.py").write_text("# source", encoding="utf-8")

    assert detect_exclusive_install_root(source_root, source_root) == "0"


def test_existing_valid_marker_preserves_exclusive_ownership(tmp_path):
    install_dir = tmp_path / "dedicated"
    install_dir.mkdir()
    (install_dir / ".meetingbot-install-root").write_text(
        "meeting-bot-exclusive-v1\n",
        encoding="utf-8",
    )
    (install_dir / "bot.py").write_text("# installed", encoding="utf-8")

    assert detect_exclusive_install_root(install_dir, REPO_ROOT) == "1"


def test_xcode_project_compiles_every_app_swift_source():
    project = XCODE_PROJECT.read_text(encoding="utf-8")
    missing = [
        source.name
        for source in SWIFT_SOURCE_DIR.glob("*.swift")
        if f"{source.name} in Sources" not in project
    ]

    assert missing == []


def test_dependency_discovery_covers_non_homebrew_install_locations():
    swift = (SWIFT_SOURCE_DIR / "EnvironmentHealth.swift").read_text(encoding="utf-8")
    preflight = (REPO_ROOT / "scripts" / "preflight.sh").read_text(encoding="utf-8")
    install = INSTALL_SCRIPT.read_text(encoding="utf-8")

    for marker in [".local/bin", ".nvm/versions/node", ".npm/_npx", "Library/pnpm"]:
        assert marker in swift
        assert marker in preflight
        assert marker in install
    assert "HOME/Applications/LibreOffice.app" in preflight
    assert "HOME/Applications/LibreOffice.app" in install


def test_stale_configured_tool_path_falls_back_to_discovery():
    stale_path = "/definitely/missing/bin/codex"

    assert resolve_tool_path(stale_path, "codex") != stale_path


def test_meeting_library_indexes_only_a_bounded_transcript_preview():
    source = (SWIFT_SOURCE_DIR / "MeetingLibraryStore.swift").read_text(encoding="utf-8")

    assert "let previewByteLimit = 16 * 1024" in source
    assert "transcriptURL.map(transcriptSearchPreview)" in source
