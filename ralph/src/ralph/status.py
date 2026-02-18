"""ralph status — session state viewer."""

import json
import os
from pathlib import Path

import typer

from ralph import ui
from ralph.engine import RALPH_DIR_NAME


def _is_running(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


def status() -> None:
    """Show current Ralph session state."""
    ralph_dir = Path.cwd() / RALPH_DIR_NAME
    meta_path = ralph_dir / "meta.json"

    if not meta_path.is_file():
        ui.error("No Ralph session found in .ralph/")
        raise typer.Exit(1)

    meta = json.loads(meta_path.read_text())

    pid = meta.get("pid", 0)
    running = _is_running(pid) if pid else False
    recorded_status = meta.get("status", "unknown")

    # Reconcile: if meta says "running" but PID is dead, it crashed
    if recorded_status == "running" and not running:
        display_status = "crashed (PID gone)"
    elif recorded_status == "running" and running:
        display_status = "running"
    else:
        display_status = recorded_status

    plan = meta.get("plan", "unknown")
    current_iter = meta.get("current_iter", "?")
    max_iter = meta.get("max_iter", "?")
    start_time = meta.get("start_time", "unknown")

    info = (
        f"Status:     {display_status}\n"
        f"Plan:       {Path(plan).name}\n"
        f"Iteration:  {current_iter}/{max_iter}\n"
        f"PID:        {pid} ({'alive' if running else 'dead'})\n"
        f"Started:    {start_time}"
    )
    ui.header(info)

    # Show status.md progress
    status_file = ralph_dir / "status.md"
    if status_file.is_file():
        content = status_file.read_text().strip()
        if content:
            ui.console.print("\n[bold]Progress:[/bold]")
            ui.console.print(content)
            ui.console.print()

    # Show pending directives
    directives = ralph_dir / "directives.md"
    if directives.is_file():
        content = directives.read_text().strip()
        if content:
            ui.console.print("[bold yellow]Pending directive:[/bold yellow]")
            ui.console.print(content)
            ui.console.print()
