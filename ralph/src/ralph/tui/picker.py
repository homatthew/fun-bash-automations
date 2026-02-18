"""PlanPicker screen — plan selection, ideation, and monitoring."""

from __future__ import annotations

import re
import subprocess
import time
from datetime import datetime
from pathlib import Path

from textual import on, work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.message import Message
from textual.screen import ModalScreen
from textual.widgets import (
    Button,
    Footer,
    Input,
    Label,
    ListItem,
    ListView,
    Markdown,
    RichLog,
    Static,
)

from ralph.engine import PLANS_DIR, RALPH_DIR_NAME

IDEA_PROMPT = (
    "You are Ralph's plan generator.\n"
    "Create a concise, actionable plan in Markdown for the following goal.\n"
    "Rules:\n"
    "- Start with a single H1 title (\"# ...\").\n"
    "- Use short sections and bullet lists.\n"
    "- Output only Markdown. No preamble or commentary.\n"
    "\n"
    "Goal:\n"
)
MAX_TAIL_LINES = 240


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


def plan_heading(path: Path) -> str | None:
    """Return the first ``# heading`` from a plan file, or *None*."""
    try:
        with path.open() as f:
            for line in f:
                stripped = line.strip()
                if stripped.startswith("# "):
                    return stripped[2:].strip()
                if stripped:
                    return None  # non-blank, non-heading line → give up
        return None
    except OSError:
        return None


def _slugify(text: str) -> str:
    """Create a filename-friendly slug from text."""
    cleaned = re.sub(r"[^A-Za-z0-9]+", "-", text.strip().lower()).strip("-")
    return cleaned[:48] if cleaned else "plan"


class IdeationFinished(Message):
    """Signals that ideation has completed."""

    def __init__(self, path: Path | None, error: str | None) -> None:
        self.path = path
        self.error = error
        super().__init__()


class PlanItem(ListItem):
    """A single plan entry in the list."""

    def __init__(self, path: Path) -> None:
        self.plan_path = path
        super().__init__()

    def compose(self) -> ComposeResult:
        age = relative_time(self.plan_path.stat().st_mtime)
        heading = plan_heading(self.plan_path)
        if heading:
            yield Label(
                f"{self.plan_path.name}  [dim]{age}[/dim]\n  [italic]{heading}[/italic]",
                markup=True,
            )
        else:
            yield Label(f"{self.plan_path.name}  [dim]{age}[/dim]", markup=True)


class NewPlanItem(ListItem):
    """Pseudo-item that launches interactive Claude to create a new plan."""

    def compose(self) -> ComposeResult:
        yield Label("[bold green]+ New plan...[/bold green]", markup=True)


class PlanPicker(ModalScreen[Path | None]):
    """Full-screen plan picker with ideation and monitoring."""

    BINDINGS = [
        Binding("escape", "cancel", "Quit", show=True),
        Binding("slash", "focus_filter", "/Filter", show=True),
        Binding("n", "new_plan", "New plan", show=True),
        Binding("i", "focus_idea", "Ideate", show=True),
    ]

    def __init__(self) -> None:
        super().__init__()
        self._all_plans: list[Path] = []
        self._tail_path: Path | None = None
        self._tail_pos: int = 0
        self._ideating = False
        self._confirming = False
        self._pending_plan: Path | None = None

    def compose(self) -> ComposeResult:
        with Horizontal(id="studio-body"):
            with Vertical(id="plan-panel"):
                yield Static("Plans", classes="panel-title")
                yield Input(placeholder="Filter plans…", id="filter-input")
                yield ListView(id="plan-list")
                yield Static("Select a plan to confirm run.", id="plan-hint")
            with Vertical(id="preview-panel"):
                yield Static("Plan Preview", classes="panel-title")
                yield Markdown(id="preview-pane")
            with Vertical(id="ops-panel"):
                yield Static("Ideate", classes="panel-title")
                yield Markdown(
                    "Enter an idea and press Enter to draft a plan.\n"
                    "Press [bold]n[/bold] to open interactive Claude.",
                    id="ideate-hints",
                )
                yield Input(placeholder="Describe your goal…", id="idea-input")
                yield Static("", id="ideate-status")
                yield Static("Live Monitor", classes="panel-title")
                yield Markdown(id="status-pane")
                yield RichLog(
                    id="tail-pane",
                    markup=True,
                    wrap=True,
                    auto_scroll=True,
                    max_lines=MAX_TAIL_LINES,
                )
        yield Footer()

    def on_mount(self) -> None:
        self._scan_plans()
        self._rebuild_list("")
        self._refresh_status()
        self._refresh_tail()
        self.set_interval(2.0, self._refresh_status)
        self.set_interval(1.0, self._refresh_tail)

    def _scan_plans(self) -> None:
        self._all_plans = sorted(
            PLANS_DIR.glob("*.md"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )

    def _rebuild_list(self, filter_text: str) -> None:
        """Rebuild the plan list, filtering by substring match."""
        plan_list = self.query_one("#plan-list", ListView)
        plan_list.clear()
        needle = filter_text.lower()
        if not needle:
            plan_list.append(NewPlanItem())
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
        preview = self.query_one("#preview-pane", Markdown)
        if isinstance(item, NewPlanItem):
            preview.update("*Launch interactive Claude to create a new plan.*")
        elif isinstance(item, PlanItem):
            content = item.plan_path.read_text()
            lines = content.splitlines()[:80]
            preview.update("\n".join(lines))

    def action_focus_filter(self) -> None:
        filter_input = self.query_one("#filter-input", Input)
        filter_input.focus()

    def action_focus_idea(self) -> None:
        self.query_one("#idea-input", Input).focus()

    def action_new_plan(self) -> None:
        self._create_new_plan()

    def action_cancel(self) -> None:
        filter_input = self.query_one("#filter-input", Input)
        if filter_input.has_focus and filter_input.value:
            filter_input.value = ""
            self.query_one("#plan-list", ListView).focus()
            self._rebuild_list("")
            return
        self.dismiss(None)

    @on(ListView.Selected)
    def on_plan_selected(self, event: ListView.Selected) -> None:
        item = event.item
        if isinstance(item, NewPlanItem):
            self._create_new_plan()
        elif isinstance(item, PlanItem):
            if self._confirming:
                return
            self._confirming = True
            self._pending_plan = item.plan_path
            self.app.push_screen(ConfirmRun(item.plan_path), callback=self._on_confirm_run)

    def _on_confirm_run(self, result: bool | None) -> None:
        self._confirming = False
        plan = self._pending_plan
        self._pending_plan = None
        if result and plan is not None:
            self.dismiss(plan)

    def _create_new_plan(self) -> None:
        """Suspend the TUI and hand the terminal to interactive Claude."""
        status = self.query_one("#ideate-status", Static)
        status.update("Opening Claude…")
        with self.app.suspend():
            subprocess.run(["claude"], check=False)
        # Re-scan plans directory for any newly created plans
        self._scan_plans()
        self._rebuild_list("")
        status.update("Ready for a new idea.")

    @on(Input.Submitted, "#idea-input")
    def on_idea_submitted(self, event: Input.Submitted) -> None:
        idea = event.value.strip()
        if not idea or self._ideating:
            return
        self._ideating = True
        self.query_one("#idea-input", Input).disabled = True
        self.query_one("#ideate-status", Static).update("Generating plan with Claude…")
        self.ideate_plan(idea)

    @work(thread=True)
    def ideate_plan(self, idea: str) -> None:
        path: Path | None = None
        error: str | None = None
        prompt = IDEA_PROMPT + idea
        try:
            result = subprocess.run(
                ["claude", "--print"],
                input=prompt,
                text=True,
                capture_output=True,
                check=False,
            )
            if result.returncode != 0:
                error = f"Claude exited with code {result.returncode}"
            else:
                content = result.stdout.strip()
                path = self._write_ideated_plan(idea, content)
        except FileNotFoundError:
            error = "Claude CLI not found."
        except OSError as exc:
            error = f"Failed to run Claude: {exc}"
        self.post_message(IdeationFinished(path, error))

    def _write_ideated_plan(self, idea: str, content: str) -> Path:
        PLANS_DIR.mkdir(parents=True, exist_ok=True)
        cleaned = content.strip()
        if not cleaned:
            cleaned = (
                f"# {idea}\n\n"
                "- Define success criteria\n"
                "- Break the work into steps\n"
                "- Validate the outcome\n"
            )
        if not cleaned.lstrip().startswith("# "):
            cleaned = f"# {idea}\n\n{cleaned}"
        heading = cleaned.splitlines()[0].lstrip("# ").strip()
        slug = _slugify(heading or idea)
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        path = PLANS_DIR / f"{stamp}-{slug}.md"
        path.write_text(cleaned.rstrip() + "\n")
        return path

    @on(IdeationFinished)
    def on_ideation_finished(self, message: IdeationFinished) -> None:
        self._ideating = False
        idea_input = self.query_one("#idea-input", Input)
        idea_input.disabled = False
        idea_input.value = ""
        status = self.query_one("#ideate-status", Static)
        if message.error:
            status.update(f"[bold red]{message.error}[/bold red]")
            return
        if message.path:
            status.update(f"Created {message.path.name}")
        else:
            status.update("No plan created.")
        self._scan_plans()
        self._rebuild_list("")

    def _refresh_status(self) -> None:
        ralph_dir = Path.cwd() / RALPH_DIR_NAME
        status_file = ralph_dir / "status.md"
        md_widget = self.query_one("#status-pane", Markdown)
        if status_file.is_file():
            content = status_file.read_text().strip()
            if content:
                md_widget.update(content)
            else:
                md_widget.update("*Waiting for status updates…*")
        else:
            md_widget.update("*No status file yet.*")

    def _refresh_tail(self) -> None:
        ralph_dir = Path.cwd() / RALPH_DIR_NAME
        tail = self.query_one("#tail-pane", RichLog)
        if not ralph_dir.is_dir():
            if self._tail_path is not None:
                tail.clear()
                tail.write("[dim]No run logs yet.[/dim]")
                self._tail_path = None
            return
        logs = sorted(
            ralph_dir.glob("iteration-*.log"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        if not logs:
            if self._tail_path is not None:
                tail.clear()
                tail.write("[dim]No run logs yet.[/dim]")
                self._tail_path = None
            return
        latest = logs[0]
        if latest != self._tail_path:
            self._tail_path = latest
            self._tail_pos = 0
            tail.clear()
            tail.write(f"[dim]Tailing {latest.name}[/dim]")
        try:
            with latest.open() as handle:
                handle.seek(self._tail_pos)
                chunk = handle.read()
                if chunk:
                    for line in chunk.splitlines():
                        tail.write(line)
                    self._tail_pos = handle.tell()
        except OSError:
            tail.write("[red]Failed to read log file.[/red]")


class ConfirmRun(ModalScreen[bool]):
    """Confirmation modal before starting a plan run."""

    BINDINGS = [("escape", "cancel", "Cancel")]

    def __init__(self, plan: Path) -> None:
        super().__init__()
        self._plan = plan

    def compose(self) -> ComposeResult:
        with Vertical(id="confirm-dialog"):
            yield Static("Run Plan?", classes="dialog-title")
            heading = plan_heading(self._plan)
            if heading:
                yield Label(f"{self._plan.name}\n{heading}", id="confirm-detail")
            else:
                yield Label(self._plan.name, id="confirm-detail")
            with Horizontal(id="confirm-buttons"):
                yield Button("Run", id="confirm-run", variant="primary")
                yield Button("Cancel", id="confirm-cancel", variant="default")

    @on(Button.Pressed)
    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "confirm-run":
            self.dismiss(True)
        else:
            self.dismiss(False)

    def action_cancel(self) -> None:
        self.dismiss(False)
