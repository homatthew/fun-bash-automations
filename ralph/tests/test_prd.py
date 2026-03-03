"""Tests for prd.json schema, story prompts, and stream-json parsing."""

import json
from pathlib import Path
from unittest.mock import MagicMock, patch

from ralph.engine import (
    EngineConfig,
    Event,
    _parse_stream_event,
    _plan_hash,
    _summarize_tool_input,
    read_meta,
    run_prd_loop,
)
from ralph.prompt import (
    PrdDocument,
    UserStory,
    build_story_prompt,
    load_prd,
    save_prd,
)

# ---------------------------------------------------------------------------
# prd.json load/save round-trip
# ---------------------------------------------------------------------------


def _sample_prd() -> PrdDocument:
    return PrdDocument(
        project="test-project",
        branch_name="test-branch",
        description="A test project",
        user_stories=[
            UserStory(
                id="US-001",
                title="Add status field",
                description="As a dev, I want a status field",
                acceptance_criteria=["Column exists", "Tests pass"],
                priority=1,
                passes=False,
                notes="",
            ),
            UserStory(
                id="US-002",
                title="Display status badge",
                description="As a user, I want to see status",
                acceptance_criteria=["Badge renders", "Tests pass"],
                priority=2,
                passes=False,
                notes="",
            ),
        ],
    )


def test_save_and_load_prd_round_trip(tmp_path: Path):
    prd = _sample_prd()
    path = tmp_path / "prd.json"
    save_prd(path, prd)
    loaded = load_prd(path)
    assert loaded.project == "test-project"
    assert loaded.branch_name == "test-branch"
    assert len(loaded.user_stories) == 2
    assert loaded.user_stories[0].id == "US-001"
    assert loaded.user_stories[1].title == "Display status badge"


def test_save_prd_is_valid_json(tmp_path: Path):
    prd = _sample_prd()
    path = tmp_path / "prd.json"
    save_prd(path, prd)
    data = json.loads(path.read_text())
    assert "user_stories" in data
    assert data["user_stories"][0]["passes"] is False


def test_save_prd_is_atomic(tmp_path: Path):
    """No .tmp file remains after save."""
    prd = _sample_prd()
    path = tmp_path / "prd.json"
    save_prd(path, prd)
    assert not path.with_suffix(".tmp").exists()


def test_load_prd_preserves_passes(tmp_path: Path):
    prd = _sample_prd()
    prd.user_stories[0].passes = True
    prd.user_stories[0].notes = "Done in iter 1"
    path = tmp_path / "prd.json"
    save_prd(path, prd)
    loaded = load_prd(path)
    assert loaded.user_stories[0].passes is True
    assert loaded.user_stories[0].notes == "Done in iter 1"
    assert loaded.user_stories[1].passes is False


def test_load_prd_missing_optional_fields(tmp_path: Path):
    """Load a prd.json with minimal fields."""
    data = {
        "project": "minimal",
        "branch_name": "min",
        "description": "Minimal test",
        "user_stories": [{
            "id": "US-001",
            "title": "First",
            "description": "Minimal story",
        }],
    }
    path = tmp_path / "prd.json"
    path.write_text(json.dumps(data))
    loaded = load_prd(path)
    assert loaded.user_stories[0].passes is False
    assert loaded.user_stories[0].notes == ""
    assert loaded.user_stories[0].acceptance_criteria == []


def test_prd_plan_context_round_trip(tmp_path: Path):
    """plan_context should survive save/load cycle."""
    prd = _sample_prd()
    prd.plan_context = "Use existing auth middleware. Follow REST conventions."
    path = tmp_path / "prd.json"
    save_prd(path, prd)
    loaded = load_prd(path)
    assert loaded.plan_context == "Use existing auth middleware. Follow REST conventions."


def test_prd_load_backward_compat_no_plan_context(tmp_path: Path):
    """Old prd.json without plan_context should default to empty string."""
    data = {
        "project": "old",
        "branch_name": "old",
        "description": "Old PRD",
        "user_stories": [],
    }
    path = tmp_path / "prd.json"
    path.write_text(json.dumps(data))
    loaded = load_prd(path)
    assert loaded.plan_context == ""


# ---------------------------------------------------------------------------
# Per-story prompt builder
# ---------------------------------------------------------------------------


def test_build_story_prompt_contains_story_id():
    prd = _sample_prd()
    story = prd.user_stories[0]
    prompt = build_story_prompt(prd, story)
    assert "US-001" in prompt


def test_build_story_prompt_contains_task_title():
    prd = _sample_prd()
    story = prd.user_stories[0]
    prompt = build_story_prompt(prd, story)
    assert "Add status field" in prompt


def test_build_story_prompt_contains_acceptance_criteria():
    prd = _sample_prd()
    story = prd.user_stories[0]
    prompt = build_story_prompt(prd, story)
    assert "Column exists" in prompt
    assert "Tests pass" in prompt


def test_build_story_prompt_shows_story_overview():
    prd = _sample_prd()
    prd.user_stories[0].passes = True
    story = prd.user_stories[1]
    prompt = build_story_prompt(prd, story)
    # First story should show as done
    assert "V US-001" in prompt
    # Current story should be marked
    assert "YOU ARE HERE" in prompt
    assert "> US-002" in prompt


def test_build_story_prompt_contains_ralph_story_done():
    prd = _sample_prd()
    prompt = build_story_prompt(prd, prd.user_stories[0])
    assert "RALPH_STORY_DONE" in prompt


def test_build_story_prompt_forbids_push_to_main():
    prd = _sample_prd()
    prompt = build_story_prompt(prd, prd.user_stories[0])
    assert "main" in prompt
    assert "master" in prompt


def test_build_story_prompt_fresh_start_when_no_notes():
    prd = _sample_prd()
    prompt = build_story_prompt(prd, prd.user_stories[0])
    assert "Fresh start" in prompt


def test_build_story_prompt_includes_notes():
    prd = _sample_prd()
    prd.user_stories[0].notes = "Got halfway through migration"
    prompt = build_story_prompt(prd, prd.user_stories[0])
    assert "Got halfway through migration" in prompt


def test_build_story_prompt_reads_status_file(tmp_path: Path):
    prd = _sample_prd()
    status = tmp_path / "status.md"
    status.write_text("Made progress on column\n")
    prompt = build_story_prompt(prd, prd.user_stories[0], status)
    assert "Made progress on column" in prompt


def test_build_story_prompt_only_current_story():
    """Prompt should NOT contain 'Execute ONLY this story'."""
    prd = _sample_prd()
    prompt = build_story_prompt(prd, prd.user_stories[0])
    assert "Execute ONLY this story" in prompt


def test_build_story_prompt_includes_plan_context():
    """Prompt should include plan_context when set."""
    prd = _sample_prd()
    prd.plan_context = "Use existing auth middleware. Follow REST conventions."
    prompt = build_story_prompt(prd, prd.user_stories[0])
    assert "## Project context" in prompt
    assert "Use existing auth middleware" in prompt


def test_build_story_prompt_omits_empty_plan_context():
    """Prompt should NOT include project context section when empty."""
    prd = _sample_prd()
    prd.plan_context = ""
    prompt = build_story_prompt(prd, prd.user_stories[0])
    assert "## Project context" not in prompt


def test_build_story_prompt_error_header_on_failures():
    """Notes with error markers should use error-specific header."""
    prd = _sample_prd()
    prd.user_stories[0].notes = (
        "## Errors detected\ntest_foo.py::test_one FAILED"
    )
    prompt = build_story_prompt(prd, prd.user_stories[0])
    assert "## What went wrong last time (fix these issues)" in prompt
    assert "## Previous progress on this story" not in prompt


def test_build_story_prompt_normal_header_without_errors():
    """Notes without error markers should use normal header."""
    prd = _sample_prd()
    prd.user_stories[0].notes = "Made some progress on the migration"
    prompt = build_story_prompt(prd, prd.user_stories[0])
    assert "## Previous progress on this story" in prompt
    assert "## What went wrong last time" not in prompt


# ---------------------------------------------------------------------------
# stream-json event parsing
# ---------------------------------------------------------------------------


def test_parse_stream_event_text():
    events = []
    buf = []
    line = json.dumps({
        "type": "assistant", "subtype": "text",
        "content": "Hello world",
    }) + "\n"
    _parse_stream_event(line, 1, buf, lambda ev: events.append(ev))
    assert len(events) == 1
    assert events[0].kind == Event.OUTPUT_LINE
    assert events[0].line == "Hello world"
    assert buf == ["Hello world"]


def test_parse_stream_event_tool_use():
    events = []
    buf = []
    line = json.dumps({
        "type": "assistant", "subtype": "tool_use",
        "tool": "Read", "input": {"file_path": "/tmp/foo.py"},
    }) + "\n"
    _parse_stream_event(line, 1, buf, lambda ev: events.append(ev))
    assert len(events) == 1
    assert events[0].kind == Event.TOOL_USE
    assert events[0].tool_name == "Read"
    assert "/tmp/foo.py" in events[0].tool_input


def test_parse_stream_event_tool_result():
    events = []
    buf = []
    line = json.dumps({"type": "tool_result"}) + "\n"
    _parse_stream_event(line, 1, buf, lambda ev: events.append(ev))
    assert len(events) == 1
    assert events[0].kind == Event.TOOL_RESULT


def test_parse_stream_event_invalid_json():
    events = []
    buf = []
    _parse_stream_event("not json\n", 1, buf, lambda ev: events.append(ev))
    assert len(events) == 1
    assert events[0].kind == Event.OUTPUT_LINE
    assert "not json" in events[0].line


def test_parse_stream_event_unknown_type():
    """Unknown event types are silently ignored."""
    events = []
    buf = []
    line = json.dumps({"type": "system", "subtype": "init"}) + "\n"
    _parse_stream_event(line, 1, buf, lambda ev: events.append(ev))
    assert len(events) == 0


# ---------------------------------------------------------------------------
# _summarize_tool_input
# ---------------------------------------------------------------------------


def test_summarize_file_path():
    assert _summarize_tool_input({"file_path": "/a/b.py"}) == "/a/b.py"


def test_summarize_command():
    result = _summarize_tool_input({"command": "git status"})
    assert "git status" in result


def test_summarize_command_truncates():
    long_cmd = "x" * 200
    result = _summarize_tool_input({"command": long_cmd})
    assert len(result) <= 80


def test_summarize_pattern():
    assert _summarize_tool_input({"pattern": "*.py"}) == "*.py"


def test_summarize_fallback():
    result = _summarize_tool_input({"foo": "bar"})
    assert len(result) <= 60


# ---------------------------------------------------------------------------
# run_prd_loop tests
# ---------------------------------------------------------------------------


def _make_prd_config(tmp_path: Path, max_iter: int = 5) -> EngineConfig:
    plan = tmp_path / "plan.md"
    plan.write_text("# Test Plan\n")
    return EngineConfig(
        plan=plan,
        max_iter=max_iter,
        tools="Edit Read Write",
        sandbox=True,
        ralph_dir=tmp_path / ".ralph",
        max_step_turns=3,
    )


def _write_prd(ralph_dir: Path, stories: list[dict] | None = None) -> None:
    ralph_dir.mkdir(exist_ok=True)
    if stories is None:
        stories = [
            {
                "id": "US-001", "title": "First story",
                "description": "Do first thing",
                "acceptance_criteria": ["Tests pass"],
                "priority": 1, "passes": False, "notes": "",
            },
            {
                "id": "US-002", "title": "Second story",
                "description": "Do second thing",
                "acceptance_criteria": ["Tests pass"],
                "priority": 2, "passes": False, "notes": "",
            },
        ]
    data = {
        "project": "test", "branch_name": "test",
        "description": "Test PRD", "user_stories": stories,
    }
    (ralph_dir / "prd.json").write_text(json.dumps(data, indent=2))


def _mock_popen_stream(lines: list[str], returncode: int = 0):
    """Create a mock Popen for stream-json output."""
    import io
    mock_proc = MagicMock()
    mock_proc.stdin = MagicMock()
    mock_proc.stdout = io.StringIO("".join(lines))
    mock_proc.wait.return_value = returncode
    mock_proc.returncode = returncode
    return mock_proc


@patch("ralph.engine.subprocess.Popen")
def test_prd_loop_completes_single_story(mock_popen, tmp_path):
    """Single story with RALPH_STORY_DONE should return 'done'."""
    text_event = json.dumps({
        "type": "assistant", "subtype": "text",
        "content": "RALPH_STORY_DONE",
    }) + "\n"
    mock_popen.return_value = _mock_popen_stream([text_event])

    config = _make_prd_config(tmp_path, max_iter=3)
    _write_prd(config.ralph_dir, stories=[{
        "id": "US-001", "title": "Only story",
        "description": "Do the thing",
        "acceptance_criteria": ["Tests pass"],
        "priority": 1, "passes": False, "notes": "",
    }])

    reason = run_prd_loop(config, on_event=lambda ev: None)
    assert reason == "done"

    # Verify prd.json updated
    prd = load_prd(config.ralph_dir / "prd.json")
    assert prd.user_stories[0].passes is True


@patch("ralph.engine.subprocess.Popen")
def test_prd_loop_progresses_through_stories(mock_popen, tmp_path):
    """Two stories — each iteration completes one story."""
    text_event = json.dumps({
        "type": "assistant", "subtype": "text",
        "content": "RALPH_STORY_DONE",
    }) + "\n"

    def _factory(*args, **kwargs):
        return _mock_popen_stream([text_event])

    mock_popen.side_effect = _factory

    config = _make_prd_config(tmp_path, max_iter=5)
    _write_prd(config.ralph_dir)

    events = []
    reason = run_prd_loop(
        config, on_event=lambda ev: events.append(ev),
    )
    assert reason == "done"

    # Should have exactly 2 iteration starts
    starts = [ev for ev in events if ev.kind == Event.ITERATION_START]
    assert len(starts) == 2
    assert starts[0].story_id == "US-001"
    assert starts[1].story_id == "US-002"


@patch("ralph.engine.subprocess.Popen")
def test_prd_loop_retries_incomplete_story(mock_popen, tmp_path):
    """Story without RALPH_STORY_DONE retries on next iteration."""
    call_count = [0]

    def _factory(*args, **kwargs):
        call_count[0] += 1
        if call_count[0] == 1:
            # First try: no completion signal
            line = json.dumps({
                "type": "assistant", "subtype": "text",
                "content": "Still working...",
            }) + "\n"
            return _mock_popen_stream([line])
        # Second try: complete
        line = json.dumps({
            "type": "assistant", "subtype": "text",
            "content": "RALPH_STORY_DONE",
        }) + "\n"
        return _mock_popen_stream([line])

    mock_popen.side_effect = _factory

    config = _make_prd_config(tmp_path, max_iter=5)
    _write_prd(config.ralph_dir, stories=[{
        "id": "US-001", "title": "Retry story",
        "description": "Do the thing",
        "acceptance_criteria": ["Tests pass"],
        "priority": 1, "passes": False, "notes": "",
    }])

    events = []
    reason = run_prd_loop(
        config, on_event=lambda ev: events.append(ev),
    )
    assert reason == "done"

    starts = [ev for ev in events if ev.kind == Event.ITERATION_START]
    assert len(starts) == 2
    # Both iterations target the same story
    assert starts[0].story_id == "US-001"
    assert starts[1].story_id == "US-001"


@patch("ralph.engine.subprocess.Popen")
def test_prd_loop_max_iterations(mock_popen, tmp_path):
    """Should return 'max_iterations' when stories never complete."""
    line = json.dumps({
        "type": "assistant", "subtype": "text",
        "content": "Working...",
    }) + "\n"
    mock_popen.return_value = _mock_popen_stream([line])

    config = _make_prd_config(tmp_path, max_iter=2)
    _write_prd(config.ralph_dir)

    reason = run_prd_loop(config, on_event=lambda ev: None)
    assert reason == "max_iterations"


@patch("ralph.engine.subprocess.Popen")
def test_prd_loop_interrupt(mock_popen, tmp_path):
    """Interrupt should stop the loop."""
    line = json.dumps({
        "type": "assistant", "subtype": "text",
        "content": "Working...",
    }) + "\n"
    mock_popen.return_value = _mock_popen_stream([line])

    config = _make_prd_config(tmp_path, max_iter=5)
    _write_prd(config.ralph_dir)

    reason = run_prd_loop(
        config, on_event=lambda ev: None,
        is_interrupted=lambda: True,
    )
    assert reason == "interrupted"


@patch("ralph.engine.subprocess.Popen")
def test_prd_loop_emits_tool_use_events(mock_popen, tmp_path):
    """Tool use events should be emitted from stream-json."""
    tool_event = json.dumps({
        "type": "assistant", "subtype": "tool_use",
        "tool": "Read", "input": {"file_path": "/tmp/test.py"},
    }) + "\n"
    done_event = json.dumps({
        "type": "assistant", "subtype": "text",
        "content": "RALPH_STORY_DONE",
    }) + "\n"
    mock_popen.return_value = _mock_popen_stream(
        [tool_event, done_event],
    )

    config = _make_prd_config(tmp_path, max_iter=3)
    _write_prd(config.ralph_dir, stories=[{
        "id": "US-001", "title": "Story",
        "description": "Do thing",
        "acceptance_criteria": ["Tests pass"],
        "priority": 1, "passes": False, "notes": "",
    }])

    events = []
    run_prd_loop(config, on_event=lambda ev: events.append(ev))

    tool_events = [ev for ev in events if ev.kind == Event.TOOL_USE]
    assert len(tool_events) == 1
    assert tool_events[0].tool_name == "Read"
    assert "/tmp/test.py" in tool_events[0].tool_input


@patch("ralph.engine.subprocess.Popen")
def test_prd_loop_builds_correct_command(mock_popen, tmp_path):
    """Command should include stream-json, max-turns, and tools."""
    line = json.dumps({
        "type": "assistant", "subtype": "text",
        "content": "RALPH_STORY_DONE",
    }) + "\n"
    mock_popen.return_value = _mock_popen_stream([line])

    config = _make_prd_config(tmp_path, max_iter=1)
    config.tools = "Edit Read Write Grep"
    config.max_step_turns = 15
    _write_prd(config.ralph_dir, stories=[{
        "id": "US-001", "title": "Story",
        "description": "Do thing",
        "acceptance_criteria": ["Tests pass"],
        "priority": 1, "passes": False, "notes": "",
    }])

    run_prd_loop(config, on_event=lambda ev: None)

    cmd = mock_popen.call_args[0][0]
    assert "--output-format" in cmd
    assert "stream-json" in cmd
    assert "--max-turns" in cmd
    assert "15" in cmd
    assert "--allowedTools" in cmd
    assert "Edit Read Write Grep" in cmd
    assert "--dangerously-skip-permissions" in cmd


@patch("ralph.engine.subprocess.Popen")
def test_prd_loop_meta_tracks_stories(mock_popen, tmp_path):
    """meta.json should track story progress."""
    line = json.dumps({
        "type": "assistant", "subtype": "text",
        "content": "RALPH_STORY_DONE",
    }) + "\n"
    mock_popen.side_effect = lambda *a, **kw: _mock_popen_stream([line])

    config = _make_prd_config(tmp_path, max_iter=5)
    _write_prd(config.ralph_dir)

    run_prd_loop(config, on_event=lambda ev: None)

    meta = json.loads(
        (config.ralph_dir / "meta.json").read_text()
    )
    assert meta["total_stories"] == 2
    assert meta["stories_passed"] == 2
    assert meta["status"] == "done"


@patch("ralph.engine.subprocess.Popen")
def test_prd_loop_saves_notes_on_incomplete(mock_popen, tmp_path):
    """Incomplete story should have notes saved to prd.json."""
    line = json.dumps({
        "type": "assistant", "subtype": "text",
        "content": "Made some progress but not done",
    }) + "\n"
    mock_popen.return_value = _mock_popen_stream([line])

    config = _make_prd_config(tmp_path, max_iter=1)
    _write_prd(config.ralph_dir, stories=[{
        "id": "US-001", "title": "Incomplete",
        "description": "Do thing",
        "acceptance_criteria": ["Tests pass"],
        "priority": 1, "passes": False, "notes": "",
    }])

    run_prd_loop(config, on_event=lambda ev: None)

    prd = load_prd(config.ralph_dir / "prd.json")
    assert prd.user_stories[0].passes is False
    # Notes should contain some progress info
    assert prd.user_stories[0].notes != ""


# ---------------------------------------------------------------------------
# Config max_step_turns
# ---------------------------------------------------------------------------


def test_config_max_step_turns_parses(tmp_path):
    from ralph.config import load_ralphrc

    rc = tmp_path / ".ralphrc"
    rc.write_text("RALPH_MAX_STEP_TURNS=30\n")
    result = load_ralphrc(rc)
    assert result["max_step_turns"] == 30


def test_config_max_step_turns_defaults_none(tmp_path):
    from ralph.config import load_ralphrc

    rc = tmp_path / ".ralphrc"
    rc.write_text('RALPH_TOOLS="Edit Read"\n')
    result = load_ralphrc(rc)
    assert result["max_step_turns"] is None


def test_engine_config_max_step_turns_default():
    config = EngineConfig(
        plan=Path("plan.md"),
        max_iter=5,
        tools="Edit Read Write",
        sandbox=True,
    )
    assert config.max_step_turns == 20


@patch("ralph.engine.subprocess.Popen")
def test_prd_loop_writes_plan_hash(mock_popen, tmp_path):
    """run_prd_loop should write plan_hash to meta.json."""
    line = json.dumps({
        "type": "assistant", "subtype": "text",
        "content": "RALPH_STORY_DONE",
    }) + "\n"
    mock_popen.return_value = _mock_popen_stream([line])

    config = _make_prd_config(tmp_path, max_iter=1)
    _write_prd(config.ralph_dir, stories=[{
        "id": "US-001", "title": "Story",
        "description": "Do thing",
        "acceptance_criteria": ["Tests pass"],
        "priority": 1, "passes": False, "notes": "",
    }])

    run_prd_loop(config, on_event=lambda ev: None)
    meta = read_meta(config.ralph_dir)
    assert "plan_hash" in meta
    assert meta["plan_hash"] == _plan_hash(config.plan)


# ---------------------------------------------------------------------------
# Git checkpoint tests
# ---------------------------------------------------------------------------


@patch("ralph.engine._git_rollback")
@patch("ralph.engine._git_untracked_files")
@patch("ralph.engine._git_head_sha")
@patch("ralph.engine.subprocess.Popen")
def test_prd_loop_with_checkpoint_rolls_back(
    mock_popen, mock_sha, mock_untracked, mock_rollback, tmp_path,
):
    """Failed iteration with git_checkpoint should call _git_rollback."""
    line = json.dumps({
        "type": "assistant", "subtype": "text",
        "content": "Still working...",
    }) + "\n"
    mock_popen.return_value = _mock_popen_stream([line])
    mock_sha.return_value = "abc123"
    mock_untracked.return_value = set()

    config = _make_prd_config(tmp_path, max_iter=1)
    config.git_checkpoint = True
    _write_prd(config.ralph_dir, stories=[{
        "id": "US-001", "title": "Story",
        "description": "Do thing",
        "acceptance_criteria": ["Tests pass"],
        "priority": 1, "passes": False, "notes": "",
    }])

    run_prd_loop(config, on_event=lambda ev: None)
    mock_rollback.assert_called_once_with("abc123", set())


@patch("ralph.engine._git_rollback")
@patch("ralph.engine._git_untracked_files")
@patch("ralph.engine._git_head_sha")
@patch("ralph.engine.subprocess.Popen")
def test_prd_loop_without_checkpoint_no_git_calls(
    mock_popen, mock_sha, mock_untracked, mock_rollback, tmp_path,
):
    """Without git_checkpoint, no git functions should be called."""
    line = json.dumps({
        "type": "assistant", "subtype": "text",
        "content": "Still working...",
    }) + "\n"
    mock_popen.return_value = _mock_popen_stream([line])

    config = _make_prd_config(tmp_path, max_iter=1)
    config.git_checkpoint = False
    _write_prd(config.ralph_dir, stories=[{
        "id": "US-001", "title": "Story",
        "description": "Do thing",
        "acceptance_criteria": ["Tests pass"],
        "priority": 1, "passes": False, "notes": "",
    }])

    run_prd_loop(config, on_event=lambda ev: None)
    mock_sha.assert_not_called()
    mock_untracked.assert_not_called()
    mock_rollback.assert_not_called()
