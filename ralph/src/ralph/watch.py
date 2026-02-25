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
    if "RALPH_DONE" in stripped or "RALPH_STORY_DONE" in stripped:
        return f"  [dim]│[/dim] {ts} [bold green]{stripped}[/bold green]"

    # Tool calls
    if stripped.startswith("[") and "]" in stripped[:30]:
        bracket_end = stripped.index("]")
        tool = stripped[1:bracket_end]
        rest = stripped[bracket_end + 2:]
        return f"  [dim]│[/dim] {ts} [bold]{tool}[/bold] [dim]{rest}[/dim]"

    # Error lines
    if any(m in stripped for m in ("FAILED", "Error", "Traceback", "error:")):
        return f"  [dim]│[/dim] {ts} [red]{stripped}[/red]"

    # Normal text — truncate long lines
    if len(stripped) > 120:
        stripped = stripped[:117] + "..."
    return f"  [dim]│[/dim] {ts} {stripped}"


def _watch(ralph_dir: Path, from_start: bool = False) -> None:
    output_log = ralph_dir / "output.log"

    # Show header from meta.json
    meta = _read_meta(ralph_dir)
    plan_name = "unknown"
    if meta:
        plan_name = Path(meta.get("plan", "unknown")).name
        status = meta.get("status", "?")
        itr = meta.get("iter", 0)
        mx = meta.get("max_iter", "?")
        cwd = meta.get("cwd", "")
        console.rule("[bold]ralph-watch[/bold]")
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

    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        TimeElapsedColumn(),
        console=console,
        transient=False,
    ) as progress:
        task = progress.add_task(
            f"Watching {plan_name}...", total=None,
        )

        with open(output_log) as f:
            if not from_start:
                f.seek(0, 2)

            last_meta_check = 0.0
            while True:
                line = f.readline()
                if line:
                    stripped = line.rstrip("\n")

                    # Detect iteration boundaries — update spinner
                    if stripped.startswith("=== iteration") and "===" in stripped[3:]:
                        # Extract iteration info
                        current_iter = stripped.strip("= ")
                        iter_start = time.monotonic()
                        progress.update(
                            task,
                            description=f"[bold cyan]{current_iter}[/bold cyan]",
                        )
                        progress.console.print(
                            f"\n  [dim]┌─[/dim] [bold cyan]{current_iter}[/bold cyan]"
                        )
                        continue

                    if stripped.startswith("=== iteration") and "complete" in stripped:
                        progress.console.print(
                            f"  [dim]└─[/dim] [dim]{stripped.strip('= ')}[/dim]\n"
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
                        if meta.get("status") in ("done", "interrupted", "max_iterations"):
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
                                    task, description="[bold]Ralph exited[/bold]",
                                )
                                break
                    time.sleep(0.1)


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

        console.print(
            f"  {icon} [cyan]{plan}[/cyan]  "
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


if __name__ == "__main__":
    main()
