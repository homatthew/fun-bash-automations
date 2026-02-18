"""Tests for the shared iteration engine."""

import json
import subprocess
from pathlib import Path
from unittest.mock import MagicMock, patch

from ralph.engine import (
    PLANS_DIR,
    RALPH_DIR_NAME,
    SANDBOX_SETTINGS,
    EngineConfig,
    Event,
    IterationEvent,
    _ensure_git_exclude,
    check_resume,
    read_meta,
    run_loop,
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


def test_engine_config_min_iter_default(tmp_path):
    config = EngineConfig(
        plan=tmp_path / "plan.md",
        max_iter=5,
        tools="Edit Read Write",
        sandbox=True,
    )
    assert config.min_iter == 0


# --- run_loop TDD tests ---


def _make_config(tmp_path, max_iter=2) -> EngineConfig:
    """Helper to create an EngineConfig for tests."""
    plan = tmp_path / "plan.md"
    plan.write_text("# Test Plan\n\n1. Do something\n")
    return EngineConfig(
        plan=plan,
        max_iter=max_iter,
        tools="Edit Read Write",
        sandbox=True,
        ralph_dir=tmp_path / ".ralph",
    )


def _mock_popen(stdout_lines: list[str], returncode: int = 0):
    """Create a mock Popen that yields the given stdout lines.

    Uses io.StringIO so the mock supports both readline() and iteration,
    matching real file-object behaviour from subprocess pipes.
    """
    import io

    mock_proc = MagicMock()
    mock_proc.stdin = MagicMock()
    mock_proc.stdout = io.StringIO("".join(stdout_lines))
    mock_proc.wait.return_value = returncode
    mock_proc.returncode = returncode
    return mock_proc


@patch("ralph.engine.subprocess.Popen")
def test_run_loop_emits_events_in_order(mock_popen, tmp_path):
    """Events: ITERATION_START -> PROMPT_BUILT -> OUTPUT_LINE* -> ITERATION_END -> ... -> DONE"""
    mock_popen.return_value = _mock_popen(["Working...\n", "RALPH_DONE\n"])
    config = _make_config(tmp_path, max_iter=1)
    events = []
    run_loop(config, on_event=lambda ev: events.append(ev.kind))
    assert Event.ITERATION_START in events
    assert Event.PROMPT_BUILT in events
    assert Event.OUTPUT_LINE in events
    assert Event.ITERATION_END in events
    assert Event.DONE in events
    # Verify ordering: START before END, END before DONE
    start_idx = events.index(Event.ITERATION_START)
    end_idx = events.index(Event.ITERATION_END)
    done_idx = events.index(Event.DONE)
    assert start_idx < end_idx < done_idx


@patch("ralph.engine.subprocess.Popen")
def test_run_loop_detects_ralph_done(mock_popen, tmp_path):
    mock_popen.return_value = _mock_popen(["Step 1 done\n", "RALPH_DONE\n"])
    config = _make_config(tmp_path, max_iter=5)
    reason = run_loop(config, on_event=lambda ev: None)
    assert reason == "done"


@patch("ralph.engine.subprocess.Popen")
def test_run_loop_returns_max_iterations(mock_popen, tmp_path):
    mock_popen.return_value = _mock_popen(["Working...\n"])
    config = _make_config(tmp_path, max_iter=2)
    reason = run_loop(config, on_event=lambda ev: None)
    assert reason == "max_iterations"


@patch("ralph.engine.subprocess.Popen")
def test_run_loop_returns_interrupted(mock_popen, tmp_path):
    mock_popen.return_value = _mock_popen(["Working...\n"])
    config = _make_config(tmp_path, max_iter=5)
    call_count = [0]

    def _interrupt():
        call_count[0] += 1
        return call_count[0] > 1  # interrupt after first iteration

    reason = run_loop(config, on_event=lambda ev: None, is_interrupted=_interrupt)
    assert reason == "interrupted"


@patch("ralph.engine.subprocess.Popen")
def test_run_loop_creates_ralph_dir(mock_popen, tmp_path):
    mock_popen.return_value = _mock_popen(["RALPH_DONE\n"])
    config = _make_config(tmp_path, max_iter=1)
    run_loop(config, on_event=lambda ev: None)
    assert (tmp_path / ".ralph").is_dir()


@patch("ralph.engine.subprocess.Popen")
def test_run_loop_writes_meta_json(mock_popen, tmp_path):
    mock_popen.return_value = _mock_popen(["RALPH_DONE\n"])
    config = _make_config(tmp_path, max_iter=1)
    run_loop(config, on_event=lambda ev: None)
    meta = read_meta(tmp_path / ".ralph")
    assert meta is not None
    assert meta["status"] == "done"


@patch("ralph.engine.subprocess.Popen")
def test_run_loop_writes_iteration_log(mock_popen, tmp_path):
    mock_popen.return_value = _mock_popen(["line 1\n", "line 2\n", "RALPH_DONE\n"])
    config = _make_config(tmp_path, max_iter=1)
    run_loop(config, on_event=lambda ev: None)
    log = tmp_path / ".ralph" / "iteration-1.log"
    assert log.is_file()
    assert "line 1" in log.read_text()
    assert "line 2" in log.read_text()


@patch("ralph.engine.subprocess.Popen")
def test_run_loop_consumes_directive(mock_popen, tmp_path):
    mock_popen.return_value = _mock_popen(["RALPH_DONE\n"])
    config = _make_config(tmp_path, max_iter=1)
    ralph_dir = tmp_path / ".ralph"
    ralph_dir.mkdir()
    (ralph_dir / "directives.md").write_text("Fix the bug first\n")
    run_loop(config, on_event=lambda ev: None)
    # Directive should be consumed (renamed)
    assert not (ralph_dir / "directives.md").exists()
    assert (ralph_dir / "directive-consumed-1.md").is_file()
    assert "Fix the bug" in (ralph_dir / "directive-consumed-1.md").read_text()


@patch("ralph.engine.subprocess.Popen")
def test_run_loop_directive_in_prompt(mock_popen, tmp_path):
    mock_popen.return_value = _mock_popen(["RALPH_DONE\n"])
    config = _make_config(tmp_path, max_iter=1)
    ralph_dir = tmp_path / ".ralph"
    ralph_dir.mkdir()
    (ralph_dir / "directives.md").write_text("Priority: fix auth\n")
    prompts = []

    def capture_prompt(ev):
        if ev.kind == Event.PROMPT_BUILT:
            prompts.append(ev.prompt)

    run_loop(config, on_event=capture_prompt)
    assert len(prompts) == 1
    assert "Priority: fix auth" in prompts[0]


@patch("ralph.engine.subprocess.Popen")
def test_run_loop_passes_allowed_tools(mock_popen, tmp_path):
    mock_popen.return_value = _mock_popen(["RALPH_DONE\n"])
    config = _make_config(tmp_path, max_iter=1)
    config.tools = "Edit Read Write Grep"
    run_loop(config, on_event=lambda ev: None)
    call_args = mock_popen.call_args[0][0]  # first positional arg is the cmd list
    assert "--allowedTools" in call_args
    tools_idx = call_args.index("--allowedTools")
    assert call_args[tools_idx + 1] == "Edit Read Write Grep"


@patch("ralph.engine.subprocess.Popen")
def test_run_loop_sandbox_on_passes_settings(mock_popen, tmp_path):
    mock_popen.return_value = _mock_popen(["RALPH_DONE\n"])
    config = _make_config(tmp_path, max_iter=1)
    config.sandbox = True
    run_loop(config, on_event=lambda ev: None)
    call_args = mock_popen.call_args[0][0]
    assert "--settings" in call_args


@patch("ralph.engine.subprocess.Popen")
def test_run_loop_sandbox_off_no_settings(mock_popen, tmp_path):
    mock_popen.return_value = _mock_popen(["RALPH_DONE\n"])
    config = _make_config(tmp_path, max_iter=1)
    config.sandbox = False
    run_loop(config, on_event=lambda ev: None)
    call_args = mock_popen.call_args[0][0]
    assert "--settings" not in call_args


@patch("ralph.engine.subprocess.Popen")
def test_run_loop_start_iter_skips_numbering(mock_popen, tmp_path):
    mock_popen.return_value = _mock_popen(["RALPH_DONE\n"])
    config = _make_config(tmp_path, max_iter=5)
    events = []
    run_loop(config, on_event=lambda ev: events.append(ev), start_iter=3)
    starts = [ev for ev in events if ev.kind == Event.ITERATION_START]
    assert len(starts) >= 1
    assert starts[0].iteration == 3


@patch("ralph.engine.subprocess.Popen")
def test_run_loop_output_line_events_have_text(mock_popen, tmp_path):
    mock_popen.return_value = _mock_popen(["hello world\n", "RALPH_DONE\n"])
    config = _make_config(tmp_path, max_iter=1)
    lines = []

    def capture_lines(ev):
        if ev.kind == Event.OUTPUT_LINE:
            lines.append(ev.line)

    run_loop(config, on_event=capture_lines)
    assert any("hello world" in line for line in lines)


@patch("ralph.engine.subprocess.Popen")
def test_run_loop_meta_status_on_interrupt(mock_popen, tmp_path):
    mock_popen.return_value = _mock_popen(["Working...\n"])
    config = _make_config(tmp_path, max_iter=5)
    run_loop(config, on_event=lambda ev: None, is_interrupted=lambda: True)
    meta = read_meta(tmp_path / ".ralph")
    assert meta["status"] == "interrupted"


@patch("ralph.engine.subprocess.Popen")
def test_run_loop_meta_status_on_max_iter(mock_popen, tmp_path):
    mock_popen.return_value = _mock_popen(["Working...\n"])
    config = _make_config(tmp_path, max_iter=1)
    run_loop(config, on_event=lambda ev: None)
    meta = read_meta(tmp_path / ".ralph")
    assert meta["status"] == "max_iterations"


# --- check_resume tests ---


def test_check_resume_returns_none_when_no_meta(tmp_path):
    assert check_resume(tmp_path, Path("plan.md")) is None


def test_check_resume_returns_none_when_different_plan(tmp_path):
    write_meta(tmp_path / "meta.json", {"plan": "/other/old-plan.md", "status": "interrupted"})
    assert check_resume(tmp_path, Path("/different/new-plan.md")) is None


def test_check_resume_returns_none_when_done(tmp_path):
    write_meta(tmp_path / "meta.json", {"plan": "/path/plan.md", "status": "done"})
    assert check_resume(tmp_path, Path("/path/plan.md")) is None


def test_check_resume_returns_none_when_running(tmp_path):
    write_meta(tmp_path / "meta.json", {"plan": "/path/plan.md", "status": "running"})
    assert check_resume(tmp_path, Path("/path/plan.md")) is None


def test_check_resume_returns_meta_when_interrupted(tmp_path):
    meta = {"plan": "/path/plan.md", "status": "interrupted", "current_iter": 3}
    write_meta(tmp_path / "meta.json", meta)
    result = check_resume(tmp_path, Path("/path/plan.md"))
    assert result is not None
    assert result["current_iter"] == 3


def test_check_resume_returns_meta_when_max_iterations(tmp_path):
    meta = {"plan": "/path/plan.md", "status": "max_iterations", "current_iter": 10}
    write_meta(tmp_path / "meta.json", meta)
    result = check_resume(tmp_path, Path("/path/plan.md"))
    assert result is not None
    assert result["current_iter"] == 10


# --- _ensure_git_exclude tests ---


def test_ensure_git_exclude_adds_entry(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    git_info = tmp_path / ".git" / "info"
    git_info.mkdir(parents=True)
    exclude = git_info / "exclude"
    exclude.write_text("# git ls-files --others --exclude-from=.git/info/exclude\n")
    _ensure_git_exclude(".ralph")
    assert ".ralph" in exclude.read_text().splitlines()


def test_ensure_git_exclude_idempotent(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    git_info = tmp_path / ".git" / "info"
    git_info.mkdir(parents=True)
    exclude = git_info / "exclude"
    exclude.write_text(".ralph\n")
    _ensure_git_exclude(".ralph")
    # Should not duplicate
    assert exclude.read_text().count(".ralph") == 1


def test_ensure_git_exclude_no_git_dir(tmp_path, monkeypatch):
    """Does nothing if not in a git repo."""
    monkeypatch.chdir(tmp_path)
    _ensure_git_exclude(".ralph")  # should not raise


# --- Live output streaming tests ---


@patch("ralph.engine.subprocess.Popen")
def test_run_loop_uses_line_buffered_popen(mock_popen, tmp_path):
    """Popen must use bufsize=1 so pipe output is line-buffered, not block-buffered."""
    mock_popen.return_value = _mock_popen(["RALPH_DONE\n"])
    config = _make_config(tmp_path, max_iter=1)
    run_loop(config, on_event=lambda ev: None)
    _, kwargs = mock_popen.call_args
    assert kwargs.get("bufsize") == 1, (
        "Popen should use bufsize=1 for line-buffered streaming; "
        "default (fully buffered) blocks live output"
    )


class _ReadlineOnlyStdout:
    """Mock stdout that only supports readline(), not iteration.

    The file iterator protocol (``for line in file``) uses an internal
    read-ahead buffer that delays output delivery from subprocess pipes.
    Using ``readline()`` reads one line at a time without buffering.
    This mock proves the engine uses readline() by raising on __iter__.
    """

    def __init__(self, lines: list[str]) -> None:
        self._lines = list(lines)
        self._pos = 0

    def readline(self) -> str:
        if self._pos >= len(self._lines):
            return ""
        line = self._lines[self._pos]
        self._pos += 1
        return line

    def __iter__(self):
        raise AssertionError(
            "Engine must use readline(), not file iteration (causes output buffering)"
        )


@patch("ralph.engine.subprocess.Popen")
def test_run_loop_reads_output_via_readline(mock_popen, tmp_path):
    """Output must be read via readline() to avoid iterator read-ahead buffering."""
    mock_proc = MagicMock()
    mock_proc.stdin = MagicMock()
    mock_proc.stdout = _ReadlineOnlyStdout(["Working...\n", "RALPH_DONE\n"])
    mock_proc.wait.return_value = 0
    mock_popen.return_value = mock_proc

    config = _make_config(tmp_path, max_iter=1)
    events = []
    run_loop(config, on_event=lambda ev: events.append(ev))

    output_lines = [ev for ev in events if ev.kind == Event.OUTPUT_LINE]
    assert len(output_lines) == 2, "Should emit one OUTPUT_LINE event per line"


# --- Mid-iteration interrupt tests ---


@patch("ralph.engine.subprocess.Popen")
def test_run_loop_interrupt_mid_iteration_terminates_subprocess(mock_popen, tmp_path):
    """When is_interrupted() fires mid-readline, engine should terminate the subprocess."""
    mock_proc = MagicMock()
    mock_proc.stdin = MagicMock()
    call_count = [0]

    def _readline():
        call_count[0] += 1
        if call_count[0] == 1:
            return "Working...\n"
        if call_count[0] == 2:
            return "Still going...\n"
        return ""

    mock_proc.stdout.readline = _readline
    mock_proc.wait.return_value = -15  # SIGTERM
    mock_popen.return_value = mock_proc

    interrupt_after = [0]

    def _interrupt():
        interrupt_after[0] += 1
        return interrupt_after[0] > 1  # True after first line processed

    config = _make_config(tmp_path, max_iter=5)
    reason = run_loop(config, on_event=lambda ev: None, is_interrupted=_interrupt)

    mock_proc.terminate.assert_called_once()
    assert reason == "interrupted"
    meta = read_meta(tmp_path / ".ralph")
    assert meta["status"] == "interrupted"


@patch("ralph.engine.subprocess.Popen")
def test_run_loop_interrupt_kills_on_timeout(mock_popen, tmp_path):
    """If proc.terminate() doesn't stop the subprocess, engine should escalate to kill()."""
    mock_proc = MagicMock()
    mock_proc.stdin = MagicMock()
    call_count = [0]

    def _readline():
        call_count[0] += 1
        if call_count[0] == 1:
            return "Working...\n"
        return ""

    mock_proc.stdout.readline = _readline
    # wait() raises TimeoutExpired after terminate, then succeeds after kill
    mock_proc.wait.side_effect = [
        subprocess.TimeoutExpired(cmd="claude", timeout=5),  # after terminate
        -9,  # after kill
        -9,  # final proc.wait() outside loop
    ]
    mock_popen.return_value = mock_proc

    interrupt_calls = [0]

    def _interrupt():
        interrupt_calls[0] += 1
        return interrupt_calls[0] > 1  # False at top-of-loop check, True inside readline

    config = _make_config(tmp_path, max_iter=5)
    reason = run_loop(
        config, on_event=lambda ev: None, is_interrupted=_interrupt,
    )

    mock_proc.terminate.assert_called_once()
    mock_proc.kill.assert_called_once()
    assert reason == "interrupted"


# --- min_iter tests ---


def _make_config_with_min(tmp_path, max_iter=5, min_iter=0) -> EngineConfig:
    """Helper to create an EngineConfig with min_iter for tests."""
    plan = tmp_path / "plan.md"
    plan.write_text("# Test Plan\n\n1. Do something\n")
    return EngineConfig(
        plan=plan,
        max_iter=max_iter,
        tools="Edit Read Write",
        sandbox=True,
        ralph_dir=tmp_path / ".ralph",
        min_iter=min_iter,
    )


@patch("ralph.engine.subprocess.Popen")
def test_run_loop_ignores_ralph_done_before_min_iter(mock_popen, tmp_path):
    """RALPH_DONE on iteration 1 should be ignored when min_iter=3."""
    call_count = [0]

    def _popen_factory(*args, **kwargs):
        call_count[0] += 1
        if call_count[0] <= 2:
            return _mock_popen(["Working...\n", "RALPH_DONE\n"])
        return _mock_popen(["Final iteration\n", "RALPH_DONE\n"])

    mock_popen.side_effect = _popen_factory
    config = _make_config_with_min(tmp_path, max_iter=5, min_iter=3)
    events = []
    reason = run_loop(config, on_event=lambda ev: events.append(ev))

    assert reason == "done"
    # Should have run at least 3 iterations (RALPH_DONE ignored on 1 and 2)
    iter_starts = [ev for ev in events if ev.kind == Event.ITERATION_START]
    assert len(iter_starts) >= 3


@patch("ralph.engine.subprocess.Popen")
def test_run_loop_accepts_ralph_done_at_min_iter(mock_popen, tmp_path):
    """RALPH_DONE on iteration 1 should be accepted when min_iter=1."""
    mock_popen.return_value = _mock_popen(["RALPH_DONE\n"])
    config = _make_config_with_min(tmp_path, max_iter=10, min_iter=1)
    reason = run_loop(config, on_event=lambda ev: None)
    assert reason == "done"


# --- status.md validation tests ---


@patch("ralph.engine.subprocess.Popen")
def test_run_loop_rejects_ralph_done_with_incomplete_status(mock_popen, tmp_path):
    """RALPH_DONE should be ignored if status.md has unchecked boxes."""
    call_count = [0]

    def _popen_factory(*args, **kwargs):
        call_count[0] += 1
        if call_count[0] == 1:
            return _mock_popen(["RALPH_DONE\n"])
        return _mock_popen(["Finishing up\n"])

    mock_popen.side_effect = _popen_factory
    config = _make_config(tmp_path, max_iter=2)

    # Pre-create status.md with incomplete progress
    ralph_dir = tmp_path / ".ralph"
    ralph_dir.mkdir()
    (ralph_dir / "status.md").write_text(
        "- [x] Step 1 (DONE)\n- [ ] Step 2\n"
    )

    reason = run_loop(config, on_event=lambda ev: None)
    # Should NOT return "done" — status.md has unchecked boxes
    assert reason == "max_iterations"


@patch("ralph.engine.subprocess.Popen")
def test_run_loop_accepts_ralph_done_with_complete_status(mock_popen, tmp_path):
    """RALPH_DONE should be accepted when all status.md boxes are checked."""
    mock_popen.return_value = _mock_popen(["All done\n", "RALPH_DONE\n"])
    config = _make_config(tmp_path, max_iter=5)

    # Pre-create status.md with complete progress
    ralph_dir = tmp_path / ".ralph"
    ralph_dir.mkdir()
    (ralph_dir / "status.md").write_text(
        "- [x] Step 1 (DONE)\n- [x] Step 2 (DONE)\n"
    )

    reason = run_loop(config, on_event=lambda ev: None)
    assert reason == "done"


@patch("ralph.engine.subprocess.Popen")
def test_run_loop_accepts_ralph_done_with_no_status_file(mock_popen, tmp_path):
    """RALPH_DONE should be accepted if status.md doesn't exist (no progress tracking)."""
    mock_popen.return_value = _mock_popen(["RALPH_DONE\n"])
    config = _make_config(tmp_path, max_iter=5)
    reason = run_loop(config, on_event=lambda ev: None)
    assert reason == "done"


@patch("ralph.engine.subprocess.Popen")
def test_run_loop_accepts_ralph_done_with_prose_only_status(mock_popen, tmp_path):
    """status.md with prose but no checkboxes should not block RALPH_DONE."""
    mock_popen.return_value = _mock_popen(["RALPH_DONE\n"])
    config = _make_config(tmp_path, max_iter=5)
    ralph_dir = tmp_path / ".ralph"
    ralph_dir.mkdir()
    (ralph_dir / "status.md").write_text(
        "Working on the feature.\nNo checkbox progress tracking here.\n"
    )
    reason = run_loop(config, on_event=lambda ev: None)
    assert reason == "done"


# --- Composition / integration tests ---
#
# These test that multiple features work together correctly,
# not just individually.


@patch("ralph.engine.subprocess.Popen")
def test_min_iter_and_status_validation_compose(mock_popen, tmp_path):
    """Both guards must pass: min_iter AND status.md complete.

    Scenario: min_iter=2, status incomplete on iter 1-2, complete on iter 3.
    - Iter 1: RALPH_DONE + incomplete status → rejected (min_iter)
    - Iter 2: RALPH_DONE + incomplete status → rejected (status)
    - Iter 3: RALPH_DONE + complete status → accepted
    """
    ralph_dir = tmp_path / ".ralph"
    ralph_dir.mkdir()
    status_file = ralph_dir / "status.md"
    call_count = [0]

    def _popen_factory(*args, **kwargs):
        call_count[0] += 1
        # Simulate Claude updating status.md each iteration
        if call_count[0] == 1:
            status_file.write_text("- [x] Step 1 (DONE)\n- [ ] Step 2\n")
        elif call_count[0] == 2:
            status_file.write_text("- [x] Step 1 (DONE)\n- [ ] Step 2\n")
        else:
            status_file.write_text(
                "- [x] Step 1 (DONE)\n- [x] Step 2 (DONE)\n"
            )
        return _mock_popen(["Working...\n", "RALPH_DONE\n"])

    mock_popen.side_effect = _popen_factory
    config = _make_config_with_min(tmp_path, max_iter=5, min_iter=2)
    events = []
    reason = run_loop(config, on_event=lambda ev: events.append(ev))

    assert reason == "done"
    iter_starts = [ev for ev in events if ev.kind == Event.ITERATION_START]
    # Iter 1: blocked by min_iter. Iter 2: blocked by incomplete status.
    # Iter 3: both pass.
    assert len(iter_starts) == 3
    done_events = [ev for ev in events if ev.kind == Event.DONE]
    assert done_events[0].iteration == 3


@patch("ralph.engine.subprocess.Popen")
def test_status_evolves_across_iterations(mock_popen, tmp_path):
    """Realistic scenario: status.md progresses 1/3 → 2/3 → 3/3.

    Engine should keep going until all steps are complete.
    """
    ralph_dir = tmp_path / ".ralph"
    ralph_dir.mkdir()
    status_file = ralph_dir / "status.md"
    call_count = [0]

    def _popen_factory(*args, **kwargs):
        call_count[0] += 1
        if call_count[0] == 1:
            status_file.write_text(
                "- [x] Step 1 (DONE)\n- [ ] Step 2\n- [ ] Step 3\n"
            )
        elif call_count[0] == 2:
            status_file.write_text(
                "- [x] Step 1 (DONE)\n- [x] Step 2 (DONE)\n- [ ] Step 3\n"
            )
        else:
            status_file.write_text(
                "- [x] Step 1 (DONE)\n"
                "- [x] Step 2 (DONE)\n"
                "- [x] Step 3 (DONE)\n"
            )
        return _mock_popen(["RALPH_DONE\n"])

    mock_popen.side_effect = _popen_factory
    config = _make_config(tmp_path, max_iter=10)
    events = []
    reason = run_loop(config, on_event=lambda ev: events.append(ev))

    assert reason == "done"
    iter_starts = [ev for ev in events if ev.kind == Event.ITERATION_START]
    assert len(iter_starts) == 3, (
        "Should take exactly 3 iterations: "
        "rejected at 1/3, rejected at 2/3, accepted at 3/3"
    )


@patch("ralph.engine.subprocess.Popen")
def test_interrupt_works_before_min_iter(mock_popen, tmp_path):
    """User can always quit, even if min_iter hasn't been reached."""
    mock_popen.return_value = _mock_popen(["Working...\n"])
    config = _make_config_with_min(tmp_path, max_iter=10, min_iter=5)
    interrupt_calls = [0]

    def _interrupt():
        interrupt_calls[0] += 1
        # False on first check (top of loop), True on second (after iter)
        return interrupt_calls[0] > 1

    reason = run_loop(
        config, on_event=lambda ev: None, is_interrupted=_interrupt,
    )
    assert reason == "interrupted"
    meta = read_meta(tmp_path / ".ralph")
    assert meta["status"] == "interrupted"


@patch("ralph.engine.subprocess.Popen")
def test_resume_respects_min_iter(mock_popen, tmp_path):
    """After resume at iter 3, min_iter=2 should accept RALPH_DONE."""
    mock_popen.return_value = _mock_popen(["RALPH_DONE\n"])
    config = _make_config_with_min(tmp_path, max_iter=10, min_iter=2)
    reason = run_loop(
        config, on_event=lambda ev: None, start_iter=3,
    )
    assert reason == "done"


@patch("ralph.engine.subprocess.Popen")
def test_resume_before_min_iter_still_enforces(mock_popen, tmp_path):
    """After resume at iter 1, min_iter=3 should still block RALPH_DONE."""
    call_count = [0]

    def _popen_factory(*args, **kwargs):
        call_count[0] += 1
        return _mock_popen(["RALPH_DONE\n"])

    mock_popen.side_effect = _popen_factory
    config = _make_config_with_min(tmp_path, max_iter=5, min_iter=3)
    events = []
    reason = run_loop(
        config, on_event=lambda ev: events.append(ev), start_iter=1,
    )
    assert reason == "done"
    iter_starts = [ev for ev in events if ev.kind == Event.ITERATION_START]
    assert iter_starts[0].iteration == 1
    # Should run at least 3 iterations before accepting
    assert len(iter_starts) >= 3


@patch("ralph.engine.subprocess.Popen")
def test_multi_iteration_meta_tracks_current_iter(mock_popen, tmp_path):
    """meta.json current_iter should reflect the last completed iteration."""
    call_count = [0]

    def _popen_factory(*args, **kwargs):
        call_count[0] += 1
        if call_count[0] < 3:
            return _mock_popen(["Working...\n"])
        return _mock_popen(["RALPH_DONE\n"])

    mock_popen.side_effect = _popen_factory
    config = _make_config(tmp_path, max_iter=5)
    run_loop(config, on_event=lambda ev: None)

    meta = read_meta(tmp_path / ".ralph")
    assert meta["current_iter"] == 3
    assert meta["status"] == "done"


@patch("ralph.engine.subprocess.Popen")
def test_multi_iteration_creates_separate_logs(mock_popen, tmp_path):
    """Each iteration should produce its own log file with correct content."""
    call_count = [0]

    def _popen_factory(*args, **kwargs):
        call_count[0] += 1
        if call_count[0] < 3:
            return _mock_popen([f"Iteration {call_count[0]} output\n"])
        return _mock_popen([f"Iteration {call_count[0]} output\n", "RALPH_DONE\n"])

    mock_popen.side_effect = _popen_factory
    config = _make_config(tmp_path, max_iter=5)
    run_loop(config, on_event=lambda ev: None)

    ralph_dir = tmp_path / ".ralph"
    for i in range(1, 4):
        log = ralph_dir / f"iteration-{i}.log"
        assert log.is_file(), f"iteration-{i}.log should exist"
        assert f"Iteration {i} output" in log.read_text()
    # No iteration 4 log
    assert not (ralph_dir / "iteration-4.log").exists()


@patch("ralph.engine.subprocess.Popen")
def test_prompt_includes_status_from_prior_iteration(mock_popen, tmp_path):
    """Iteration 2's prompt should contain status.md written by iteration 1."""
    ralph_dir = tmp_path / ".ralph"
    ralph_dir.mkdir()
    status_file = ralph_dir / "status.md"
    call_count = [0]
    prompts = []

    def _capture(ev):
        if ev.kind == Event.PROMPT_BUILT:
            prompts.append(ev.prompt)

    def _popen_factory(*args, **kwargs):
        call_count[0] += 1
        if call_count[0] == 1:
            # Simulate Claude writing status.md during iteration 1
            status_file.write_text(
                "- [x] Step 1: set up database (DONE)\n"
                "- [ ] Step 2: add API endpoints\n"
            )
            return _mock_popen(["Did step 1\n"])
        return _mock_popen(["RALPH_DONE\n"])

    mock_popen.side_effect = _popen_factory
    config = _make_config(tmp_path, max_iter=3)
    run_loop(config, on_event=_capture)

    assert len(prompts) >= 2
    # First prompt should say "Fresh start"
    assert "Fresh start" in prompts[0]
    # Second prompt should include iteration 1's status
    assert "set up database" in prompts[1]
    assert "API endpoints" in prompts[1]


@patch("ralph.engine.subprocess.Popen")
def test_mid_iteration_interrupt_still_writes_log(mock_popen, tmp_path):
    """Lines received before interrupt should still be in the log file."""
    mock_proc = MagicMock()
    mock_proc.stdin = MagicMock()
    line_num = [0]

    def _readline():
        line_num[0] += 1
        if line_num[0] <= 3:
            return f"Line {line_num[0]}\n"
        return ""

    mock_proc.stdout.readline = _readline
    mock_proc.wait.return_value = -15
    mock_popen.return_value = mock_proc

    interrupt_calls = [0]

    def _interrupt():
        interrupt_calls[0] += 1
        # False at top-of-loop, True after 2nd line in readline loop
        return interrupt_calls[0] > 2

    config = _make_config(tmp_path, max_iter=5)
    run_loop(config, on_event=lambda ev: None, is_interrupted=_interrupt)

    log = tmp_path / ".ralph" / "iteration-1.log"
    log_text = log.read_text()
    assert "Line 1" in log_text
    assert "Line 2" in log_text
