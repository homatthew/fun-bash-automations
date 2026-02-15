"""ralph logs — iteration log browser."""

from datetime import datetime
from pathlib import Path

import typer

from ralph import ui


def logs(
    iteration: int | None = typer.Argument(None, help="Iteration number to view"),
    last: bool = typer.Option(False, "--last", "-l", help="Show most recent iteration log"),
) -> None:
    """Browse Ralph iteration logs."""
    ralph_dir = Path.cwd() / ".ralph"

    if not ralph_dir.is_dir():
        ui.error("No .ralph/ directory found.")
        raise typer.Exit(1)

    log_files = sorted(ralph_dir.glob("iteration-*.log"))
    if not log_files:
        ui.error("No iteration logs found in .ralph/")
        raise typer.Exit(1)

    # Show specific iteration
    if iteration is not None:
        target = ralph_dir / f"iteration-{iteration}.log"
        if not target.is_file():
            ui.error(f"No log for iteration {iteration}")
            raise typer.Exit(1)
        ui.console.print(target.read_text())
        return

    # Show most recent
    if last:
        ui.console.print(log_files[-1].read_text())
        return

    # List available logs
    ui.console.print("\n[bold]Available iteration logs:[/bold]\n")
    for lf in log_files:
        mtime = datetime.fromtimestamp(lf.stat().st_mtime)
        size_kb = lf.stat().st_size / 1024
        ui.console.print(f"  {lf.name:<22}  {mtime:%Y-%m-%d %H:%M:%S}  ({size_kb:.1f} KB)")
    ui.console.print("\nUse [cyan]ralph logs <N>[/cyan] to view a specific iteration.")
