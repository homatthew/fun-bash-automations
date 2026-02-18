"""Core iteration engine — shared constants, helpers, and loop logic."""

import json
from collections.abc import Callable
from dataclasses import dataclass, field
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
    raise NotImplementedError("run_loop not yet implemented")
