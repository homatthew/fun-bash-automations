"""Core iteration engine — shared constants, helpers, and loop logic.

Supports two modes:
1. prd.json mode (new): story-by-story execution with stream-json parsing
2. Legacy mode: flat plan execution with --print (backward compat)
"""

import hashlib
import json
import os
import subprocess
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum, auto
from pathlib import Path

# --- Shared constants ---
PLANS_DIR = Path.home() / ".claude" / "plans"
RALPH_DIR_NAME = ".ralph"
SANDBOX_SETTINGS = json.dumps(
    {"sandbox": {"enabled": True, "autoAllowBashIfSandboxed": True}}
)


def write_meta(meta_path: Path, data: dict) -> None:
    """Atomic write of meta.json (write tmp, rename)."""
    tmp = meta_path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    tmp.rename(meta_path)


def read_meta(ralph_dir: Path) -> dict | None:
    """Read meta.json from a .ralph directory. Returns None if missing or corrupt."""
    meta_path = ralph_dir / "meta.json"
    if not meta_path.is_file():
        return None
    try:
        return json.loads(meta_path.read_text())
    except (json.JSONDecodeError, OSError):
        return None


class Event(Enum):
    """Events emitted during the iteration loop."""

    ITERATION_START = auto()
    PROMPT_BUILT = auto()
    OUTPUT_LINE = auto()
    TOOL_USE = auto()
    TOOL_RESULT = auto()
    ITERATION_END = auto()
    DONE = auto()


@dataclass
class IterationEvent:
    """Payload for an engine event.

    Not all fields are populated for every event kind:
    - ITERATION_START: iteration, max_iter, story_id
    - PROMPT_BUILT: iteration, max_iter, prompt
    - OUTPUT_LINE: iteration, line
    - TOOL_USE: iteration, tool_name, tool_input
    - TOOL_RESULT: iteration, tool_name
    - ITERATION_END: iteration, max_iter, elapsed, exit_code
    - DONE: iteration, max_iter, elapsed, reason
    """

    kind: Event
    iteration: int = 0
    max_iter: int = 0
    prompt: str = ""
    line: str = ""
    elapsed: int = 0
    exit_code: int = 0
    reason: str = ""
    tool_name: str = ""
    tool_input: str = ""
    story_id: str = ""


@dataclass
class EngineConfig:
    """Configuration for the iteration engine.

    Callers resolve CLI args, .ralphrc, and defaults before constructing this.
    """

    plan: Path
    max_iter: int
    tools: str
    sandbox: bool
    ralph_dir: Path = field(default_factory=lambda: Path.cwd() / ".ralph")
    min_iter: int = 0
    max_step_turns: int = 20
    git_checkpoint: bool = False


def _plan_hash(plan: Path) -> str:
    """SHA-256 content hash of a plan file (first 16 hex chars)."""
    return hashlib.sha256(plan.read_bytes()).hexdigest()[:16]


def check_resume(ralph_dir: Path, plan: Path) -> dict | None:
    """Check if a previous run can be resumed.

    Returns the meta dict if resume is possible (same plan, status is
    'interrupted' or 'max_iterations'), otherwise None.

    Compares by content hash when available, falls back to filename
    for backward compatibility with old meta.json files.
    """
    meta = read_meta(ralph_dir)
    if meta is None:
        return None
    if meta.get("status") not in ("interrupted", "max_iterations"):
        return None
    # Prefer hash comparison; fall back to name if no hash stored
    stored_hash = meta.get("plan_hash")
    if stored_hash:
        if stored_hash != _plan_hash(plan):
            return None
    elif Path(meta.get("plan", "")).name != plan.name:
        return None
    return meta


def _ensure_git_exclude(dirname: str) -> None:
    """Add dirname to .git/info/exclude if not already present.

    This keeps .ralph/ invisible to git without modifying .gitignore.
    Silently does nothing if not in a git repo.
    """
    exclude = Path(".git") / "info" / "exclude"
    if not exclude.is_file():
        return
    content = exclude.read_text()
    if dirname in content.splitlines():
        return
    with open(exclude, "a") as f:
        f.write(f"{dirname}\n")


def ensure_prd(ralph_dir: Path, plan: Path) -> bool:
    """Ensure prd.json exists. Convert from plan if needed.

    Returns True if prd.json is available, False otherwise.
    """
    from ralph.prompt import convert_plan_to_prd

    prd_path = ralph_dir / "prd.json"
    if prd_path.is_file():
        return True

    try:
        prd_json = convert_plan_to_prd(plan)
        ralph_dir.mkdir(exist_ok=True)
        prd_path.write_text(prd_json)
        return True
    except (RuntimeError, json.JSONDecodeError, OSError):
        return False


def _summarize_tool_input(input_dict: dict) -> str:
    """Produce a short summary of a tool call's input for the activity log."""
    if "file_path" in input_dict:
        return str(input_dict["file_path"])
    if "command" in input_dict:
        return str(input_dict["command"])[:80]
    if "pattern" in input_dict:
        return str(input_dict["pattern"])
    return str(input_dict)[:60]


def _extract_progress_notes(
    text_output: str, status_file: Path | None,
) -> str:
    """Extract progress notes from the text output or status.md.

    When falling back to text output (no status.md), extracts error
    lines and tracebacks for actionable retry context.
    """
    if status_file and status_file.is_file():
        content = status_file.read_text().strip()
        if content:
            return content
    if not text_output:
        return ""

    lines = text_output.splitlines()

    # Extract error lines (FAILED, ERROR, AssertionError), deduplicated
    error_lines: list[str] = []
    seen: set[str] = set()
    for line in lines:
        stripped = line.strip()
        if any(
            marker in stripped
            for marker in ("FAILED", "AssertionError", "ERROR")
        ) and stripped not in seen:
            seen.add(stripped)
            error_lines.append(stripped)
            if len(error_lines) >= 10:
                break

    # Extract last traceback (up to 20 lines)
    traceback_lines: list[str] = []
    last_tb_start = -1
    for i, line in enumerate(lines):
        if line.strip().startswith("Traceback (most recent call last)"):
            last_tb_start = i
    if last_tb_start >= 0:
        traceback_lines = lines[last_tb_start:last_tb_start + 20]

    sections: list[str] = []
    if error_lines:
        sections.append(
            "## Errors detected\n" + "\n".join(error_lines)
        )
    if traceback_lines:
        sections.append(
            "## Last traceback\n" + "\n".join(traceback_lines)
        )

    if sections:
        return "\n\n".join(sections)

    # Fallback: last 2000 chars
    return text_output[-2000:]


# ---------------------------------------------------------------------------
# Git checkpoint helpers
# ---------------------------------------------------------------------------


def _git_head_sha() -> str | None:
    """Return the current HEAD SHA, or None if not in a git repo."""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            capture_output=True, text=True, check=True,
        )
        return result.stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


def _git_untracked_files() -> set[str]:
    """Return the set of untracked files (excluding ignored)."""
    try:
        result = subprocess.run(
            ["git", "ls-files", "--others", "--exclude-standard"],
            capture_output=True, text=True, check=True,
        )
        return {f for f in result.stdout.strip().splitlines() if f}
    except (subprocess.CalledProcessError, FileNotFoundError):
        return set()


def _git_rollback(sha: str, pre_untracked: set[str]) -> bool:
    """Roll back to the given SHA if no new untracked files appeared.

    Returns True if rollback was performed, False if skipped for safety.
    """
    current_untracked = _git_untracked_files()
    new_untracked = current_untracked - pre_untracked
    if new_untracked:
        return False
    try:
        subprocess.run(
            ["git", "reset", "--hard", sha],
            capture_output=True, text=True, check=True,
        )
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


def _build_cmd(
    config: EngineConfig, *, stream_json: bool = False,
) -> list[str]:
    """Build the claude CLI command list."""
    if stream_json:
        cmd = [
            "claude", "-p",
            "--dangerously-skip-permissions",
            "--output-format", "stream-json",
            "--max-turns", str(config.max_step_turns),
            "--allowedTools", config.tools,
        ]
    else:
        cmd = ["claude", "--print", "--allowedTools", config.tools]
    if config.sandbox:
        cmd.extend(["--settings", SANDBOX_SETTINGS])
    return cmd


# ---------------------------------------------------------------------------
# prd.json-driven loop (new)
# ---------------------------------------------------------------------------


def run_prd_loop(
    config: EngineConfig,
    on_event: Callable[[IterationEvent], None],
    is_interrupted: Callable[[], bool] = lambda: False,
    start_iter: int = 1,
) -> str:
    """Run story-by-story execution from prd.json.

    Returns the reason for stopping: "done", "max_iterations", or
    "interrupted".
    """
    from ralph.prompt import (
        build_story_prompt,
        load_prd,
        save_prd,
    )

    ralph_dir = config.ralph_dir
    ralph_dir.mkdir(exist_ok=True)
    _ensure_git_exclude(ralph_dir.name)
    meta_path = ralph_dir / "meta.json"
    status_file = ralph_dir / "status.md"
    prd_path = ralph_dir / "prd.json"
    output_log = ralph_dir / "output.log"

    prd = load_prd(prd_path)
    stories = sorted(prd.user_stories, key=lambda s: s.priority)

    passed_count = sum(1 for s in stories if s.passes)
    meta = {
        "plan": str(config.plan),
        "plan_hash": _plan_hash(config.plan),
        "prd_file": str(prd_path),
        "pid": os.getpid(),
        "start_time": datetime.now().isoformat(),
        "max_iter": config.max_iter,
        "total_stories": len(stories),
        "stories_passed": passed_count,
        "current_story": "",
        "status": "running",
        "current_iter": 0,
    }
    write_meta(meta_path, meta)
    loop_start = time.time()

    # Combined output log for `rt` / `ralph-watch` tailing
    combined_log = open(output_log, "a")

    for i in range(start_iter, config.max_iter + 1):
        if is_interrupted():
            elapsed = int(time.time() - loop_start)
            meta["status"] = "interrupted"
            write_meta(meta_path, meta)
            combined_log.close()
            on_event(IterationEvent(
                kind=Event.DONE, iteration=i, max_iter=config.max_iter,
                elapsed=elapsed, reason="interrupted",
            ))
            return "interrupted"

        # Find current story (first non-passing)
        current = next((s for s in stories if not s.passes), None)
        if current is None:
            elapsed = int(time.time() - loop_start)
            meta["status"] = "done"
            write_meta(meta_path, meta)
            combined_log.close()
            on_event(IterationEvent(
                kind=Event.DONE, iteration=i, max_iter=config.max_iter,
                elapsed=elapsed, reason="done",
            ))
            return "done"

        meta["current_iter"] = i
        meta["current_story"] = current.id
        write_meta(meta_path, meta)

        iter_start = time.time()
        log_file = ralph_dir / f"iteration-{i}.log"

        # Git checkpoint: capture state before iteration
        pre_sha: str | None = None
        pre_untracked: set[str] = set()
        if config.git_checkpoint:
            pre_sha = _git_head_sha()
            pre_untracked = _git_untracked_files()

        on_event(IterationEvent(
            kind=Event.ITERATION_START, iteration=i,
            max_iter=config.max_iter, story_id=current.id,
        ))

        # Check for directives
        directives_file = ralph_dir / "directives.md"
        prompt_extra = ""
        if directives_file.is_file():
            directive_content = directives_file.read_text().strip()
            if directive_content:
                prompt_extra = (
                    f"\n## Operator directive (priority)\n"
                    f"{directive_content}\n"
                )
                archive = ralph_dir / f"directive-consumed-{i}.md"
                directives_file.rename(archive)

        # Build prompt for current story
        prompt_content = build_story_prompt(prd, current, status_file)
        if prompt_extra:
            prompt_content = prompt_content + "\n" + prompt_extra

        on_event(IterationEvent(
            kind=Event.PROMPT_BUILT, iteration=i,
            max_iter=config.max_iter, prompt=prompt_content,
        ))

        # Build command with stream-json
        cmd = _build_cmd(config, stream_json=True)

        # Write iteration header to combined log
        combined_log.write(
            f"=== iteration {i}/{config.max_iter}  "
            f"[{current.id}] ===\n"
        )
        combined_log.flush()

        # Run subprocess, parse stream-json events
        text_buffer: list[str] = []
        with open(log_file, "w") as lf:
            proc = subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            proc.stdin.write(prompt_content)
            proc.stdin.close()

            for raw_line in iter(proc.stdout.readline, ""):
                lf.write(raw_line)
                _parse_stream_event(
                    raw_line, i, text_buffer, on_event,
                    combined_log=combined_log,
                )
                if is_interrupted():
                    proc.terminate()
                    try:
                        proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()
                    break

            exit_code = proc.wait()

        combined_log.write(f"=== iteration {i} complete ===\n\n")
        combined_log.flush()

        iter_elapsed = int(time.time() - iter_start)
        on_event(IterationEvent(
            kind=Event.ITERATION_END, iteration=i,
            max_iter=config.max_iter, elapsed=iter_elapsed,
            exit_code=exit_code,
        ))

        # Check for story completion
        full_text = "\n".join(text_buffer)
        if "RALPH_STORY_DONE" in full_text:
            current.passes = True
            current.notes = f"Completed in iteration {i}"
            meta["stories_passed"] = sum(
                1 for s in stories if s.passes
            )
            save_prd(prd_path, prd)
            write_meta(meta_path, meta)

            if all(s.passes for s in stories):
                elapsed = int(time.time() - loop_start)
                meta["status"] = "done"
                write_meta(meta_path, meta)
                combined_log.close()
                on_event(IterationEvent(
                    kind=Event.DONE, iteration=i,
                    max_iter=config.max_iter, elapsed=elapsed,
                    reason="done",
                ))
                return "done"
        else:
            # Story not complete — save notes for retry
            current.notes = _extract_progress_notes(
                full_text, status_file,
            )
            save_prd(prd_path, prd)

            # Git checkpoint: rollback failed iteration
            if config.git_checkpoint and pre_sha:
                _git_rollback(pre_sha, pre_untracked)

        # Check interrupt after iteration
        if is_interrupted():
            elapsed = int(time.time() - loop_start)
            meta["status"] = "interrupted"
            write_meta(meta_path, meta)
            combined_log.close()
            on_event(IterationEvent(
                kind=Event.DONE, iteration=i, max_iter=config.max_iter,
                elapsed=elapsed, reason="interrupted",
            ))
            return "interrupted"

    # Reached max iterations
    elapsed = int(time.time() - loop_start)
    meta["status"] = "max_iterations"
    write_meta(meta_path, meta)
    combined_log.close()
    on_event(IterationEvent(
        kind=Event.DONE, iteration=config.max_iter,
        max_iter=config.max_iter, elapsed=elapsed,
        reason="max_iterations",
    ))
    return "max_iterations"


def _parse_stream_event(
    raw_line: str,
    iteration: int,
    text_buffer: list[str],
    on_event: Callable[[IterationEvent], None],
    combined_log: object | None = None,
) -> None:
    """Parse a single stream-json line and emit events.

    If combined_log is provided, text content is written to it for tailing.
    """
    try:
        event = json.loads(raw_line)
    except json.JSONDecodeError:
        on_event(IterationEvent(
            kind=Event.OUTPUT_LINE, iteration=iteration,
            line=raw_line,
        ))
        if combined_log:
            combined_log.write(raw_line)
            combined_log.flush()
        return

    msg_type = event.get("type")
    subtype = event.get("subtype")

    if msg_type == "assistant" and subtype == "text":
        text = event.get("content", "")
        text_buffer.append(text)
        on_event(IterationEvent(
            kind=Event.OUTPUT_LINE, iteration=iteration, line=text,
        ))
        if combined_log:
            combined_log.write(text)
            combined_log.flush()
    elif msg_type == "assistant" and subtype == "tool_use":
        tool = event.get("tool", "")
        tool_input = _summarize_tool_input(event.get("input", {}))
        on_event(IterationEvent(
            kind=Event.TOOL_USE, iteration=iteration,
            tool_name=tool, tool_input=tool_input,
        ))
        if combined_log:
            combined_log.write(f"[tool: {tool}] {tool_input}\n")
            combined_log.flush()
    elif msg_type == "tool_result":
        on_event(IterationEvent(
            kind=Event.TOOL_RESULT, iteration=iteration,
        ))


# ---------------------------------------------------------------------------
# Legacy loop (flat plan execution, backward compatible)
# ---------------------------------------------------------------------------


def run_loop(
    config: EngineConfig,
    on_event: Callable[[IterationEvent], None],
    is_interrupted: Callable[[], bool] = lambda: False,
    start_iter: int = 1,
) -> str:
    """Run the iteration loop, calling on_event for each significant event.

    Returns the reason for stopping: "done", "max_iterations", or
    "interrupted".
    """
    from ralph.prompt import build_prompt, parse_progress

    ralph_dir = config.ralph_dir
    ralph_dir.mkdir(exist_ok=True)
    _ensure_git_exclude(ralph_dir.name)
    meta_path = ralph_dir / "meta.json"
    status_file = ralph_dir / "status.md"
    output_log = ralph_dir / "output.log"

    meta = {
        "plan": str(config.plan),
        "plan_hash": _plan_hash(config.plan),
        "pid": os.getpid(),
        "start_time": datetime.now().isoformat(),
        "max_iter": config.max_iter,
        "status": "running",
        "current_iter": 0,
    }
    write_meta(meta_path, meta)
    loop_start = time.time()

    # Combined output log for `rt` / `ralph-watch` tailing
    combined_log = open(output_log, "a")

    for i in range(start_iter, config.max_iter + 1):
        if is_interrupted():
            elapsed = int(time.time() - loop_start)
            meta["status"] = "interrupted"
            write_meta(meta_path, meta)
            combined_log.close()
            on_event(IterationEvent(
                kind=Event.DONE, iteration=i, max_iter=config.max_iter,
                elapsed=elapsed, reason="interrupted",
            ))
            return "interrupted"

        meta["current_iter"] = i
        write_meta(meta_path, meta)

        iter_start = time.time()
        directives_file = ralph_dir / "directives.md"
        log_file = ralph_dir / f"iteration-{i}.log"

        on_event(IterationEvent(
            kind=Event.ITERATION_START, iteration=i,
            max_iter=config.max_iter,
        ))

        # Check for directives
        prompt_extra = ""
        if directives_file.is_file():
            directive_content = directives_file.read_text().strip()
            if directive_content:
                prompt_extra = (
                    f"\n## Operator directive (priority)\n"
                    f"{directive_content}\n"
                )
                archive = ralph_dir / f"directive-consumed-{i}.md"
                directives_file.rename(archive)

        # Build prompt
        prompt_content = build_prompt(str(config.plan), status_file)
        if prompt_extra:
            prompt_content = prompt_content + "\n" + prompt_extra

        on_event(IterationEvent(
            kind=Event.PROMPT_BUILT, iteration=i,
            max_iter=config.max_iter, prompt=prompt_content,
        ))

        # Build command
        cmd = _build_cmd(config, stream_json=False)

        # Write iteration header to combined log
        combined_log.write(f"=== iteration {i}/{config.max_iter} ===\n")
        combined_log.flush()

        # Run subprocess, stream output
        with open(log_file, "w") as lf:
            proc = subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            proc.stdin.write(prompt_content)
            proc.stdin.close()

            for line in iter(proc.stdout.readline, ""):
                lf.write(line)
                combined_log.write(line)
                combined_log.flush()
                on_event(IterationEvent(
                    kind=Event.OUTPUT_LINE, iteration=i, line=line,
                ))
                if is_interrupted():
                    proc.terminate()
                    try:
                        proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()
                    break

            exit_code = proc.wait()

        combined_log.write(f"=== iteration {i} complete ===\n\n")
        combined_log.flush()

        iter_elapsed = int(time.time() - iter_start)
        on_event(IterationEvent(
            kind=Event.ITERATION_END, iteration=i,
            max_iter=config.max_iter, elapsed=iter_elapsed,
            exit_code=exit_code,
        ))

        # Check for completion signal
        log_text = log_file.read_text()
        if "RALPH_DONE" in log_text and i >= config.min_iter:
            # Validate status.md — reject if unchecked boxes remain
            if status_file.is_file():
                done, total = parse_progress(status_file.read_text())
                if total > 0 and done < total:
                    continue  # keep iterating
            elapsed = int(time.time() - loop_start)
            meta["status"] = "done"
            write_meta(meta_path, meta)
            combined_log.close()
            on_event(IterationEvent(
                kind=Event.DONE, iteration=i,
                max_iter=config.max_iter, elapsed=elapsed,
                reason="done",
            ))
            return "done"

        # Check interrupt after iteration
        if is_interrupted():
            elapsed = int(time.time() - loop_start)
            meta["status"] = "interrupted"
            write_meta(meta_path, meta)
            combined_log.close()
            on_event(IterationEvent(
                kind=Event.DONE, iteration=i,
                max_iter=config.max_iter, elapsed=elapsed,
                reason="interrupted",
            ))
            return "interrupted"

    # Reached max iterations
    elapsed = int(time.time() - loop_start)
    meta["status"] = "max_iterations"
    write_meta(meta_path, meta)
    combined_log.close()
    on_event(IterationEvent(
        kind=Event.DONE, iteration=config.max_iter,
        max_iter=config.max_iter, elapsed=elapsed,
        reason="max_iterations",
    ))
    return "max_iterations"
