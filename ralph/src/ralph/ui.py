"""Rich console output helpers — replaces _ralph_say / gum."""

from rich.console import Console
from rich.panel import Panel

console = Console()


def header(text: str) -> None:
    console.print(Panel(text, border_style="white"))


def success(text: str) -> None:
    console.print(Panel(text, border_style="green"))


def warn(text: str) -> None:
    console.print(Panel(text, border_style="yellow"))


def error(text: str) -> None:
    console.print(Panel(text, border_style="red"))


def iter_header(i: int, max_iter: int, time_str: str) -> None:
    console.print(f"[blue]--- iteration {i}/{max_iter} ({time_str}) ---[/blue]")
