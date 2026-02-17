"""PlanPicker screen — fuzzy-filter plan list with markdown preview."""

import time
from pathlib import Path

from textual import on
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import Footer, Input, Label, ListItem, ListView, Markdown

PLANS_DIR = Path.home() / ".claude" / "plans"


def relative_time(mtime: float) -> str:
    """Human-friendly relative time from an mtime timestamp."""
    delta = int(time.time() - mtime)
    if delta < 60:
        return f"{delta}s"
    if delta < 3600:
        return f"{delta // 60}m"
    if delta < 86400:
        return f"{delta // 3600}h"
    return f"{delta // 86400}d"


class PlanItem(ListItem):
    """A single plan entry in the list."""

    def __init__(self, path: Path) -> None:
        self.plan_path = path
        super().__init__()

    def compose(self) -> ComposeResult:
        age = relative_time(self.plan_path.stat().st_mtime)
        yield Label(f"{self.plan_path.name}  [dim]{age}[/dim]", markup=True)


class PlanPicker(ModalScreen[Path | None]):
    """Full-screen plan picker with fuzzy filter and markdown preview."""

    BINDINGS = [
        Binding("escape", "cancel", "Quit", show=True),
        Binding("slash", "focus_filter", "/Filter", show=True),
        Binding("enter", "select_plan", "Select", show=True),
    ]

    def __init__(self) -> None:
        super().__init__()
        self._all_plans: list[Path] = []

    def compose(self) -> ComposeResult:
        with Horizontal(id="picker-body"):
            with Vertical(id="picker-left"):
                yield Input(placeholder="Filter...", id="filter-input")
                yield ListView(id="plan-list")
            yield Markdown(id="preview-pane")
        yield Footer()

    def on_mount(self) -> None:
        self._all_plans = sorted(
            PLANS_DIR.glob("*.md"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        self._rebuild_list("")
        self.query_one("#filter-input", Input).display = False

    def _rebuild_list(self, filter_text: str) -> None:
        """Rebuild the plan list, filtering by substring match."""
        plan_list = self.query_one("#plan-list", ListView)
        plan_list.clear()
        needle = filter_text.lower()
        for p in self._all_plans:
            if needle in p.name.lower():
                plan_list.append(PlanItem(p))
        if plan_list.children:
            plan_list.index = 0
            self._update_preview()

    @on(Input.Changed, "#filter-input")
    def on_filter_changed(self, event: Input.Changed) -> None:
        self._rebuild_list(event.value)

    @on(ListView.Highlighted)
    def on_plan_highlighted(self, event: ListView.Highlighted) -> None:
        self._update_preview()

    def _update_preview(self) -> None:
        """Update the preview pane with the highlighted plan's content."""
        plan_list = self.query_one("#plan-list", ListView)
        if plan_list.highlighted_child is None:
            return
        item = plan_list.highlighted_child
        if isinstance(item, PlanItem):
            content = item.plan_path.read_text()
            lines = content.splitlines()[:80]
            self.query_one("#preview-pane", Markdown).update("\n".join(lines))

    def action_focus_filter(self) -> None:
        filter_input = self.query_one("#filter-input", Input)
        filter_input.display = True
        filter_input.focus()

    def action_cancel(self) -> None:
        filter_input = self.query_one("#filter-input", Input)
        if filter_input.display and filter_input.has_focus:
            filter_input.value = ""
            filter_input.display = False
            self.query_one("#plan-list", ListView).focus()
            self._rebuild_list("")
        else:
            self.dismiss(None)

    def action_select_plan(self) -> None:
        plan_list = self.query_one("#plan-list", ListView)
        if plan_list.highlighted_child and isinstance(plan_list.highlighted_child, PlanItem):
            self.dismiss(plan_list.highlighted_child.plan_path)
