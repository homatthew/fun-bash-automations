"""Core iteration engine — shared constants, helpers, and loop logic."""

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
SANDBOX_SETTINGS = json.dumps({"sandbox": {"enabled": True, "autoAllowBashIfSandboxed": True}})


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
    ITERATION_END = auto()
    DONE = auto()


@dataclass
class IterationEvent:
    """Payload for an engine event.

    Not all fields are populated for every event kind:
    - ITERATION_START: iteration, max_iter
    - PROMPT_BUILT: iteration, max_iter, prompt
    - OUTPUT_LINE: iteration, line
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


def run_loop(
    config: EngineConfig,
    on_event: Callable[[IterationEvent], None],
    is_interrupted: Callable[[], bool] = lambda: False,
    start_iter: int = 1,
) -> str:
    """Run the iteration loop, calling on_event for each significant event.

    Returns the reason for stopping: "done", "max_iterations", or "interrupted".
    """
    from ralph.prompt import build_prompt

    ralph_dir = config.ralph_dir
    ralph_dir.mkdir(exist_ok=True)
    meta_path = ralph_dir / "meta.json"
    status_file = ralph_dir / "status.md"

    meta = {
        "plan": str(config.plan),
        "pid": os.getpid(),
        "start_time": datetime.now().isoformat(),
        "max_iter": config.max_iter,
        "status": "running",
        "current_iter": 0,
    }
    write_meta(meta_path, meta)
    loop_start = time.time()

    for i in range(start_iter, config.max_iter + 1):
        if is_interrupted():
            elapsed = int(time.time() - loop_start)
            meta["status"] = "interrupted"
            write_meta(meta_path, meta)
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
            kind=Event.ITERATION_START, iteration=i, max_iter=config.max_iter,
        ))

        # Check for directives
        prompt_extra = ""
        if directives_file.is_file():
            directive_content = directives_file.read_text().strip()
            if directive_content:
                prompt_extra = (
                    f"\n## Operator directive (priority)\n{directive_content}\n"
                )
                archive = ralph_dir / f"directive-consumed-{i}.md"
                directives_file.rename(archive)

        # Build prompt
        prompt_content = build_prompt(str(config.plan), status_file)
        if prompt_extra:
            prompt_content = prompt_content + "\n" + prompt_extra

        on_event(IterationEvent(
            kind=Event.PROMPT_BUILT, iteration=i, max_iter=config.max_iter,
            prompt=prompt_content,
        ))

        # Build command
        cmd = ["claude", "--print", "--allowedTools", config.tools]
        if config.sandbox:
            cmd.extend(["--settings", SANDBOX_SETTINGS])

        # Run subprocess, stream output
        with open(log_file, "w") as lf:
            proc = subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            proc.stdin.write(prompt_content)
            proc.stdin.close()

            for line in proc.stdout:
                lf.write(line)
                on_event(IterationEvent(
                    kind=Event.OUTPUT_LINE, iteration=i, line=line,
                ))

            exit_code = proc.wait()

        iter_elapsed = int(time.time() - iter_start)
        on_event(IterationEvent(
            kind=Event.ITERATION_END, iteration=i, max_iter=config.max_iter,
            elapsed=iter_elapsed, exit_code=exit_code,
        ))

        # Check for completion signal
        log_text = log_file.read_text()
        if "RALPH_DONE" in log_text:
            elapsed = int(time.time() - loop_start)
            meta["status"] = "done"
            write_meta(meta_path, meta)
            on_event(IterationEvent(
                kind=Event.DONE, iteration=i, max_iter=config.max_iter,
                elapsed=elapsed, reason="done",
            ))
            return "done"

        # Check interrupt after iteration
        if is_interrupted():
            elapsed = int(time.time() - loop_start)
            meta["status"] = "interrupted"
            write_meta(meta_path, meta)
            on_event(IterationEvent(
                kind=Event.DONE, iteration=i, max_iter=config.max_iter,
                elapsed=elapsed, reason="interrupted",
            ))
            return "interrupted"

    # Reached max iterations
    elapsed = int(time.time() - loop_start)
    meta["status"] = "max_iterations"
    write_meta(meta_path, meta)
    on_event(IterationEvent(
        kind=Event.DONE, iteration=config.max_iter, max_iter=config.max_iter,
        elapsed=elapsed, reason="max_iterations",
    ))
    return "max_iterations"
