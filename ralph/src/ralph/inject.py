"""ralph inject — mid-run directive writer."""

from pathlib import Path

import typer

from ralph import ui
from ralph.engine import RALPH_DIR_NAME


def inject(
    message: str | None = typer.Argument(None, help="Directive text (reads from stdin if omitted)"),
) -> None:
    """Queue a directive for the next Ralph iteration."""
    directives = Path.cwd() / RALPH_DIR_NAME / "directives.md"

    if message is None:
        ui.console.print("Enter directive (Ctrl-D to finish):")
        import sys

        message = sys.stdin.read().strip()

    if not message:
        ui.error("Empty directive — nothing written.")
        raise typer.Exit(1)

    directives.parent.mkdir(exist_ok=True)
    directives.write_text(message + "\n")
    ui.success("Directive queued for next iteration.")
