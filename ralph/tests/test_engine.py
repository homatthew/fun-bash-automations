"""Tests for the shared iteration engine."""

import json
from pathlib import Path

from ralph.engine import (
    PLANS_DIR,
    RALPH_DIR_NAME,
    SANDBOX_SETTINGS,
    EngineConfig,
    Event,
    IterationEvent,
    read_meta,
    write_meta,
)


def test_plans_dir_is_home_claude_plans():
    assert PLANS_DIR == Path.home() / ".claude" / "plans"


def test_ralph_dir_name():
    assert RALPH_DIR_NAME == ".ralph"


def test_sandbox_settings_is_valid_json():
    parsed = json.loads(SANDBOX_SETTINGS)
    assert parsed["sandbox"]["enabled"] is True
    assert parsed["sandbox"]["autoAllowBashIfSandboxed"] is True


def test_write_meta_creates_file(tmp_path: Path):
    meta_path = tmp_path / "meta.json"
    data = {"status": "running", "iteration": 1}
    write_meta(meta_path, data)
    assert meta_path.is_file()
    loaded = json.loads(meta_path.read_text())
    assert loaded == data


def test_write_meta_overwrites_existing(tmp_path: Path):
    meta_path = tmp_path / "meta.json"
    write_meta(meta_path, {"version": 1})
    write_meta(meta_path, {"version": 2})
    loaded = json.loads(meta_path.read_text())
    assert loaded["version"] == 2


def test_write_meta_is_atomic(tmp_path: Path):
    """Verify no .tmp file remains after write."""
    meta_path = tmp_path / "meta.json"
    write_meta(meta_path, {"ok": True})
    assert not meta_path.with_suffix(".tmp").exists()


def test_read_meta_returns_dict(tmp_path: Path):
    write_meta(tmp_path / "meta.json", {"plan": "test.md", "status": "done"})
    result = read_meta(tmp_path)
    assert result is not None
    assert result["plan"] == "test.md"
    assert result["status"] == "done"


def test_read_meta_missing_dir(tmp_path: Path):
    result = read_meta(tmp_path / "nonexistent")
    assert result is None


def test_read_meta_missing_file(tmp_path: Path):
    result = read_meta(tmp_path)
    assert result is None


def test_read_meta_corrupt_json(tmp_path: Path):
    (tmp_path / "meta.json").write_text("not valid json{{{")
    result = read_meta(tmp_path)
    assert result is None


def test_event_enum_has_all_stages():
    assert Event.ITERATION_START is not None
    assert Event.PROMPT_BUILT is not None
    assert Event.OUTPUT_LINE is not None
    assert Event.ITERATION_END is not None
    assert Event.DONE is not None


def test_iteration_event_defaults():
    ev = IterationEvent(kind=Event.OUTPUT_LINE)
    assert ev.iteration == 0
    assert ev.line == ""
    assert ev.elapsed == 0


def test_iteration_event_with_values():
    ev = IterationEvent(kind=Event.ITERATION_START, iteration=3, max_iter=10)
    assert ev.kind == Event.ITERATION_START
    assert ev.iteration == 3
    assert ev.max_iter == 10


def test_engine_config_defaults(tmp_path: Path):
    config = EngineConfig(
        plan=tmp_path / "plan.md",
        max_iter=5,
        tools="Edit Read Write",
        sandbox=True,
    )
    assert config.max_iter == 5
    assert config.sandbox is True
    assert config.ralph_dir == Path.cwd() / ".ralph"


def test_engine_config_custom_ralph_dir(tmp_path: Path):
    config = EngineConfig(
        plan=tmp_path / "plan.md",
        max_iter=5,
        tools="Edit Read Write",
        sandbox=True,
        ralph_dir=tmp_path / ".custom-ralph",
    )
    assert config.ralph_dir == tmp_path / ".custom-ralph"
