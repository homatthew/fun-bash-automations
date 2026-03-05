"""ralph-watch — Rich live tail for Ralph output.

Tails .ralph/output.log with a spinner, elapsed time per line,
and color-coded output. Ported from the dgi-tools SSH streaming
pattern (SpinnerColumn + TimeElapsedColumn + tree connectors).

Usage:
  ralph-watch              # Watch .ralph/ in cwd
  ralph-watch /path/to/dir # Watch specific directory
  ralph-watch -f           # Follow from start of file (not just tail)
"""

import json
import os
import sys
import time
from collections import Counter
from pathlib import Path

from rich.console import Console
from rich.progress import Progress, SpinnerColumn, TextColumn, TimeElapsedColumn

console = Console()


def _read_meta(ralph_dir: Path) -> dict:
    meta_path = ralph_dir / "meta.json"
    if not meta_path.exists():
        return {}
    try:
        return json.loads(meta_path.read_text())
    except (json.JSONDecodeError, OSError):
        return {}


def _find_latest_iter_log(ralph_dir: Path) -> Path | None:
    logs = sorted(ralph_dir.glob("iteration-*.log"), key=lambda p: p.stat().st_mtime)
    return logs[-1] if logs else None


class IterStats:
    """Track activity within an iteration for the spinner status line."""

    def __init__(self):
        self.reset()
        self.steps_done = 0  # across all iterations
        self.total_tools = 0

    def reset(self):
        self.tools = Counter()
        self.files_touched: set[str] = set()
        self.last_activity = ""
        self.iter_tools = 0

    def record_tool(self, tool: str, detail: str):
        self.tools[tool] += 1
        self.iter_tools += 1
        self.total_tools += 1
        self.last_activity = tool
        # Track files from Read/Edit/Write/Grep/Glob
        if tool in ("Read", "Edit", "Write") and detail:
            # Extract just filename from path
            name = Path(detail.strip()).name
            if name:
                self.files_touched.add(name)

    def record_step_done(self):
        self.steps_done += 1

    def spinner_text(self, current_iter: str) -> str:
        parts = [f"[bold cyan]{current_iter}[/bold cyan]"]
        if self.iter_tools:
            parts.append(f"[dim]{self.iter_tools} tools[/dim]")
        if self.files_touched:
            n = len(self.files_touched)
            parts.append(f"[dim]{n} file{'s' if n != 1 else ''}[/dim]")
        if self.last_activity:
            parts.append(f"[magenta]{self.last_activity}[/magenta]")
        if self.steps_done:
            parts.append(f"[green]step {self.steps_done} done[/green]")
        return "  ".join(parts)

    def iter_summary(self) -> str:
        """One-line summary printed after an iteration completes."""
        parts = []
        if self.iter_tools:
            # Top 3 tools
            top = self.tools.most_common(3)
            tool_str = " ".join(f"{t}:{n}" for t, n in top)
            parts.append(f"tools: {tool_str}")
        if self.files_touched:
            files = sorted(self.files_touched)
            if len(files) <= 4:
                parts.append(f"files: {', '.join(files)}")
            else:
                parts.append(f"files: {', '.join(files[:3])} +{len(files)-3}")
        if not parts:
            return ""
        return "  [dim]│  " + "  |  ".join(parts) + "[/dim]"


def _format_line(line: str, elapsed: int) -> str | None:
    """Format a line with elapsed time and tree connectors. Returns None to skip."""
    stripped = line.rstrip("\n")
    if not stripped:
        return None

    ts = f"[dim]{elapsed:>4}s[/dim]"

    # Iteration boundaries
    if stripped.startswith("=== iteration"):
        return None  # handled by progress bar update

    # Completion signals
    if any(s in stripped for s in ("RALPH_DONE", "RALPH_STEP_DONE", "RALPH_STORY_DONE")):
        return f"  [dim]│[/dim] {ts} [bold green]{stripped}[/bold green]"

    # Tool calls
    if stripped.startswith("[") and "]" in stripped[:30]:
        bracket_end = stripped.index("]")
        tool = stripped[1:bracket_end]
        rest = stripped[bracket_end + 2:]
        return f"  [dim]│[/dim] {ts} [bold]{tool}[/bold] [dim]{rest}[/dim]"

    # Failure diagnostics — make these stand out
    if "No completion signal" in stripped or "consecutive failures" in stripped:
        return f"  [dim]│[/dim] {ts} [bold yellow]{stripped}[/bold yellow]"

    if "hit turn limit" in stripped or "error_max_turns" in stripped:
        return f"  [dim]│[/dim] {ts} [bold yellow]{stripped}[/bold yellow]"

    if stripped.startswith("Crash report:"):
        return f"  [dim]│[/dim] {ts} [bold red]{stripped}[/bold red]"

    # Error lines
    if any(m in stripped for m in ("FAILED", "Error", "Traceback", "error:")):
        return f"  [dim]│[/dim] {ts} [red]{stripped}[/red]"

    # Normal text — truncate long lines
    if len(stripped) > 120:
        stripped = stripped[:117] + "..."
    return f"  [dim]│[/dim] {ts} {stripped}"


def _parse_tool(line: str) -> tuple[str, str] | None:
    """Extract (tool_name, detail) from a tool-call line, or None."""
    stripped = line.rstrip("\n")
    if stripped.startswith("[") and "]" in stripped[:30]:
        bracket_end = stripped.index("]")
        return stripped[1:bracket_end], stripped[bracket_end + 2:]
    return None


def _watch(ralph_dir: Path, from_start: bool = False) -> None:
    output_log = ralph_dir / "output.log"

    # Show header from meta.json
    meta = _read_meta(ralph_dir)
    plan_name = "unknown"
    session = ""
    if meta:
        plan_name = Path(meta.get("plan", "unknown")).name
        session = meta.get("session", "")
        status = meta.get("status", "?")
        itr = meta.get("iter", 0)
        mx = meta.get("max_iter", "?")
        cwd = meta.get("cwd", "")
        if session:
            title = f"[bold magenta]{session}[/bold magenta]"
        else:
            title = "[bold]ralph-watch[/bold]"
        console.rule(title)
        console.print(
            f"  Plan: [cyan]{plan_name}[/cyan]  |  "
            f"Iter: [yellow]{itr}/{mx}[/yellow]  |  "
            f"Status: [bold]{status}[/bold]"
        )
        if cwd:
            console.print(f"  Dir:  [dim]{cwd}[/dim]")
        console.print()

    # Wait for log to exist
    if not output_log.exists():
        latest = _find_latest_iter_log(ralph_dir)
        if latest:
            output_log = latest
            console.print(f"[dim]Following {output_log.name}[/dim]")
        else:
            console.print("[yellow]Waiting for Ralph to start...[/yellow]")
            while not output_log.exists():
                latest = _find_latest_iter_log(ralph_dir)
                if latest:
                    output_log = latest
                    break
                time.sleep(0.5)

    iter_start = time.monotonic()
    current_iter = ""
    stats = IterStats()

    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        TimeElapsedColumn(),
        console=console,
        transient=True,
    ) as progress:
        label = session if session else plan_name
        task = progress.add_task(
            f"[magenta]{label}[/magenta] watching...", total=None,
        )

        with open(output_log) as f:
            if not from_start:
                f.seek(0, 2)

            last_meta_check = 0.0
            last_line_time = time.monotonic()
            stale_warned = False
            while True:
                line = f.readline()
                if line:
                    last_line_time = time.monotonic()
                    stale_warned = False
                    stripped = line.rstrip("\n")

                    # Track tool calls for spinner
                    tool_info = _parse_tool(stripped)
                    if tool_info:
                        stats.record_tool(*tool_info)
                        if current_iter:
                            progress.update(
                                task,
                                description=stats.spinner_text(current_iter),
                            )

                    # Track step completions
                    if "RALPH_STEP_DONE" in stripped:
                        stats.record_step_done()

                    # Detect iteration boundaries — update spinner
                    # Check completion FIRST (both formats start with "=== iteration")
                    if stripped.startswith("=== iteration") and "result:" in stripped:
                        result_text = stripped.strip("= ")
                        # Color-code by result type
                        if "plan_complete" in stripped:
                            style = "bold green"
                        elif "success" in stripped:
                            style = "cyan"
                        else:
                            style = "yellow"
                        # Print iteration summary before result
                        summary = stats.iter_summary()
                        if summary:
                            progress.console.print(summary, highlight=False)
                        progress.console.print(
                            f"\n  [dim]┌─[/dim] [{style}]{result_text}[/{style}]"
                        )
                        stats.reset()
                        continue

                    if stripped.startswith("=== iteration") and "===" in stripped[3:]:
                        # New iteration — reset per-iter stats
                        current_iter = stripped.strip("= ")
                        iter_start = time.monotonic()
                        stats.reset()
                        progress.update(
                            task,
                            description=stats.spinner_text(current_iter),
                        )
                        progress.console.print(
                            f"\n  [dim]┌─[/dim] [bold cyan]{current_iter}[/bold cyan]"
                        )
                        continue

                    elapsed = int(time.monotonic() - iter_start)
                    formatted = _format_line(line, elapsed)
                    if formatted:
                        progress.console.print(formatted, highlight=False)
                else:
                    # Check if ralph finished
                    now = time.time()
                    if now - last_meta_check > 2:
                        last_meta_check = now
                        meta = _read_meta(ralph_dir)
                        if meta.get("status") in (
                            "done", "interrupted", "max_iterations", "failed",
                        ):
                            progress.update(
                                task,
                                description=(
                                    f"[bold]Ralph {meta['status']}[/bold] "
                                    f"(iter {meta.get('iter', '?')})"
                                ),
                            )
                            # Drain remaining
                            remaining = f.read()
                            if remaining:
                                for rem_line in remaining.splitlines():
                                    elapsed = int(time.monotonic() - iter_start)
                                    # Track tools from drained lines too
                                    tool_info = _parse_tool(rem_line)
                                    if tool_info:
                                        stats.record_tool(*tool_info)
                                    fmt = _format_line(rem_line, elapsed)
                                    if fmt:
                                        progress.console.print(fmt, highlight=False)
                            break
                        pid = meta.get("pid")
                        if pid:
                            try:
                                os.kill(pid, 0)
                            except (OSError, ProcessLookupError):
                                remaining = f.read()
                                if remaining:
                                    for rem_line in remaining.splitlines():
                                        elapsed = int(time.monotonic() - iter_start)
                                        fmt = _format_line(rem_line, elapsed)
                                        if fmt:
                                            progress.console.print(fmt, highlight=False)
                                progress.update(
                                    task,
                                    description="[bold]Ralph exited[/bold] (process gone)",
                                )
                                break
                        # Stale warning — no output for 60s
                        silence = time.monotonic() - last_line_time
                        if silence > 60 and not stale_warned:
                            stale_warned = True
                            progress.console.print(
                                f"  [dim]│[/dim] [dim yellow]"
                                f"    No output for {int(silence)}s — "
                                f"Claude may be thinking or stuck[/dim yellow]"
                            )
                    time.sleep(0.1)

    # End summary after Progress exits (cursor restored, spinner gone)
    meta = _read_meta(ralph_dir)
    status = meta.get("status", "exited")
    itr = meta.get("iter", "?")
    mx = meta.get("max_iter", "?")
    label = meta.get("session", plan_name)

    if status == "done":
        style = "bold green"
    elif status in ("interrupted", "max_iterations"):
        style = "bold yellow"
    elif status == "failed":
        style = "bold red"
    else:
        style = "bold"

    console.print(f"\n  [{style}]Ralph {status}[/{style}] — {label} (iter {itr}/{mx})")
    if stats.total_tools:
        console.print(f"  [dim]{stats.total_tools} total tool calls, {stats.steps_done} steps completed[/dim]")
    console.print()


def _find_sessions() -> list[tuple[Path, dict]]:
    """Find all .ralph/ directories with meta.json across common locations."""
    candidates = []
    home = Path.home()

    # Check cwd
    candidates.append(Path.cwd())

    # Check ~/worktrees/*/
    wt_dir = home / "worktrees"
    if wt_dir.is_dir():
        candidates.extend(p for p in wt_dir.iterdir() if p.is_dir())

    # Check ~/repos/*/ (top-level only)
    repos_dir = home / "repos"
    if repos_dir.is_dir():
        candidates.extend(p for p in repos_dir.iterdir() if p.is_dir())

    sessions = []
    for d in candidates:
        ralph_dir = d / ".ralph"
        meta = _read_meta(ralph_dir)
        if meta:
            sessions.append((ralph_dir, meta))
    return sessions


def _list_sessions() -> None:
    """Show all discoverable Ralph sessions."""
    sessions = _find_sessions()
    if not sessions:
        console.print("[yellow]No Ralph sessions found.[/yellow]")
        return

    console.rule("[bold]Ralph sessions[/bold]")
    for ralph_dir, meta in sessions:
        plan = Path(meta.get("plan", "?")).name
        session = meta.get("session", "")
        status = meta.get("status", "?")
        itr = meta.get("iter", 0)
        mx = meta.get("max_iter", "?")
        parent = ralph_dir.parent

        # Check if PID is alive
        pid = meta.get("pid")
        alive = False
        if pid:
            try:
                os.kill(pid, 0)
                alive = True
            except (OSError, ProcessLookupError):
                pass

        if alive:
            icon = "[green]>[/green]"
        elif status == "done":
            icon = "[green]V[/green]"
        else:
            icon = "[dim].[/dim]"

        name = f"[magenta]{session}[/magenta] " if session else ""
        console.print(
            f"  {icon} {name}[cyan]{plan}[/cyan]  "
            f"iter {itr}/{mx}  "
            f"[{'bold' if alive else 'dim'}]{status}[/{'bold' if alive else 'dim'}]"
        )
        console.print(f"    [dim]ralph-watch {parent}[/dim]")
    console.print()


def main():
    from_start = False
    list_mode = False
    target = ""

    args = sys.argv[1:]
    for arg in args:
        if arg == "-f":
            from_start = True
        elif arg in ("-l", "--list"):
            list_mode = True
        elif arg in ("-h", "--help"):
            print(__doc__)
            print("  -f           Follow from start of file")
            print("  -l, --list   List all discoverable Ralph sessions")
            print("  <path>       Watch .ralph/ in this directory")
            print()
            print("With no args and no .ralph/ in cwd, shows --list automatically.")
            return
        else:
            target = arg

    if list_mode:
        _list_sessions()
        return

    # If no target and no .ralph/ in cwd, auto-list
    if not target:
        ralph_dir = Path.cwd() / ".ralph"
        if not ralph_dir.is_dir():
            _list_sessions()
            return
        target = "."

    ralph_dir = Path(target) / ".ralph"
    if not ralph_dir.is_dir():
        console.print(f"[red]No .ralph/ directory in {target}[/red]")
        console.print("Try: [bold]ralph-watch --list[/bold]")
        sys.exit(1)

    try:
        _watch(ralph_dir, from_start=from_start)
    except KeyboardInterrupt:
        console.print("\n[dim]Stopped watching.[/dim]")
    finally:
        console.show_cursor(True)


if __name__ == "__main__":
    main()
