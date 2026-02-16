"""Ralph Wiggum — Textual TUI application."""

from pathlib import Path

from textual.app import App


class RalphApp(App):
    """Main Ralph application — routes between Picker and Runner screens."""

    TITLE = "Ralph Wiggum"
    CSS_PATH = "app.tcss"

    def __init__(
        self,
        plan: Path | None = None,
        max_iter: int = 10,
        tools: str | None = None,
    ):
        super().__init__()
        self.plan_path = plan
        self.max_iter = max_iter
        self.tools_override = tools
