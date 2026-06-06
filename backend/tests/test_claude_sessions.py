"""Claude session discovery (scan ~/.claude/projects) + the sessions endpoint."""
import json
import os
import time
from pathlib import Path

from app.adapters.claude import (
    list_claude_sessions,
    session_cwd_from_disk,
    session_meta_from_file,
)
from tests.conftest import FakeHermes, build_client


def _write_session(projects: Path, slug: str, sid: str, lines: list[dict]) -> Path:
    d = projects / slug
    d.mkdir(parents=True, exist_ok=True)
    p = d / f"{sid}.jsonl"
    p.write_text("\n".join(json.dumps(o) for o in lines) + "\n", encoding="utf-8")
    return p


def test_session_meta_extracts_cwd_preview_title(tmp_path):
    sid = "11111111-1111-1111-1111-111111111111"
    p = _write_session(
        tmp_path, "-Users-me-git-foo", sid,
        [
            {"type": "queue-operation", "timestamp": "2026-05-29T10:00:00.000Z",
             "content": "review the auth code", "sessionId": sid},
            {"type": "user", "timestamp": "2026-05-29T10:00:01.000Z",
             "cwd": "/Users/me/git/foo", "sessionId": sid,
             "message": {"content": "review the auth code"}},
            {"type": "assistant", "timestamp": "2026-05-29T10:00:05.000Z",
             "message": {"content": [
                 {"type": "text", "text": "ok"},
                 {"type": "tool_use", "name": "Read", "id": "t1",
                  "input": {"file_path": "a.py"}},
             ]}},
            {"type": "ai-title", "aiTitle": "Auth review"},
        ],
    )
    meta = session_meta_from_file(p)
    assert meta is not None
    assert meta.session_id == sid
    assert meta.source == "claude"
    assert meta.cwd == "/Users/me/git/foo"
    assert meta.title == "Auth review"
    assert "review the auth code" in meta.preview
    assert meta.tool_call_count == 1
    assert meta.message_count == 2  # 1 user + 1 assistant


def test_session_meta_reports_transcript_size(tmp_path):
    sid = "33333333-3333-3333-3333-333333333333"
    p = _write_session(
        tmp_path, "-Users-me-git-foo", sid,
        [{"type": "user", "cwd": "/Users/me/git/foo", "sessionId": sid,
          "message": {"content": "hi"}}],
    )
    meta = session_meta_from_file(p)
    assert meta is not None
    assert meta.size_bytes == p.stat().st_size > 0


def test_list_claude_sessions_orders_by_mtime_and_limits(tmp_path):
    for i in range(3):
        sid = f"0000000{i}-0000-0000-0000-000000000000"
        p = _write_session(
            tmp_path, "-Users-me-git-foo", sid,
            [{"type": "queue-operation", "content": f"q{i}", "sessionId": sid}],
        )
        os.utime(p, (time.time() + i, time.time() + i))  # deterministic ordering
    out = list_claude_sessions(limit=2, projects_dir=tmp_path)
    assert len(out) == 2
    assert out[0].session_id.startswith("00000002")  # newest first


def test_session_cwd_from_disk(tmp_path):
    sid = "22222222-2222-2222-2222-222222222222"
    _write_session(
        tmp_path, "-Users-me-git-bar", sid,
        [{"type": "user", "cwd": "/Users/me/git/bar", "sessionId": sid,
          "message": {"content": "hi"}}],
    )
    assert session_cwd_from_disk(sid, projects_dir=tmp_path) == "/Users/me/git/bar"
    assert session_cwd_from_disk("nope", projects_dir=tmp_path) is None


def test_list_claude_sessions_missing_dir_is_empty(tmp_path):
    assert list_claude_sessions(projects_dir=tmp_path / "nonexistent") == []


def test_list_claude_sessions_excludes_probe_dirs(tmp_path):
    real = "aaaa1111-0000-0000-0000-000000000000"
    probe = "bbbb2222-0000-0000-0000-000000000000"
    _write_session(tmp_path, "-Users-me-git-foo", real,
                   [{"type": "queue-operation", "content": "real work", "sessionId": real}])
    _write_session(tmp_path, "-Users-me-Library-CodexBar-ClaudeProbe", probe,
                   [{"type": "queue-operation", "content": "/usage", "sessionId": probe}])
    ids = {s.session_id for s in list_claude_sessions(projects_dir=tmp_path)}
    assert real in ids
    assert probe not in ids  # default exclude=("ClaudeProbe",)
    # No exclusion → both surface.
    ids_all = {s.session_id for s in list_claude_sessions(projects_dir=tmp_path, exclude=())}
    assert real in ids_all and probe in ids_all


def test_harness_sessions_endpoint_hermes_lists_nothing():
    # FakeHermes has no list_sessions → endpoint returns [] (the optional-
    # capability path), still a clean 200.
    client = build_client(hermes=FakeHermes(), stt=None, tts=None)
    resp = client.get("/api/harnesses/hermes/sessions")
    assert resp.status_code == 200
    assert resp.json() == []


def test_harness_sessions_endpoint_unknown_harness_422():
    client = build_client(hermes=FakeHermes(), stt=None, tts=None)
    resp = client.get("/api/harnesses/bogus/sessions")
    assert resp.status_code == 422


def test_resolve_cwd_external_session_is_readonly(monkeypatch, tmp_path):
    from app.adapters.claude import ClaudeAdapter
    from app.config import Settings

    ws = str(tmp_path / "ws")
    a = ClaudeAdapter(Settings(harness_workspace_dir=ws))

    # Resuming a session whose real cwd is a repo outside the workspace → external.
    monkeypatch.setattr(a, "_session_cwd", lambda sid: "/Users/me/git/foo")
    cwd, is_ext = a._resolve_cwd("some-id")
    assert cwd == "/Users/me/git/foo" and is_ext is True

    # Fresh turn (no session) → the shared workspace, not external.
    monkeypatch.setattr(a, "_session_cwd", lambda sid: None)
    _, is_ext = a._resolve_cwd(None)
    assert is_ext is False

    # A session that already lives in the workspace → not external.
    monkeypatch.setattr(a, "_session_cwd", lambda sid: ws)
    _, is_ext = a._resolve_cwd("id2")
    assert is_ext is False


def test_base_args_readonly_vs_write(tmp_path):
    from app.adapters.claude import ClaudeAdapter
    from app.config import Settings

    a = ClaudeAdapter(Settings(harness_workspace_dir=str(tmp_path)))
    ro = a._base_args("hi", "sid", read_only=True)
    assert "plan" in ro and "Read,Bash(git *)" in ro and "acceptEdits" not in ro
    wr = a._base_args("hi", None, read_only=False)
    assert "acceptEdits" in wr and "plan" not in wr


def test_base_args_voice_system_prompt_on_every_turn(tmp_path):
    """The voice instruction is a per-invocation --append-system-prompt flag,
    present on BOTH a fresh turn and a --resume turn (the attached-session bug),
    and the prompt itself is no longer prelude-prefixed."""
    from app.adapters.claude import _VOICE_SYSTEM_PROMPT, ClaudeAdapter
    from app.config import Settings

    a = ClaudeAdapter(Settings(harness_workspace_dir=str(tmp_path)))
    for session_id in (None, "sid"):
        args = a._base_args("hi", session_id, read_only=False)
        assert "--append-system-prompt" in args
        i = args.index("--append-system-prompt")
        assert args[i + 1] == _VOICE_SYSTEM_PROMPT
        # raw prompt, not prelude-prefixed
        assert args[args.index("-p") + 1] == "hi"
    # resume case still carries --resume alongside the system prompt
    resumed = a._base_args("hi", "sid", read_only=True)
    assert "--resume" in resumed and "--append-system-prompt" in resumed
