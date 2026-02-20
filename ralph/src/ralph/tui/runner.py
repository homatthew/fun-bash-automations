"""LoopRunner screen — streaming iteration loop with live output.

Supports both prd.json-driven (story-by-story) and legacy (flat plan) modes.
"""

import json
import time
from datetime import datetime
from pathlib import Path

from textual import on, work
from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical
from textual.message import Message
from textual.screen import ModalScreen, Screen
from textual.widgets import Button, Footer, Input, Label, Markdown, RichLog, Static

from ralph.config import RALPH_DEFAULT_TOOLS, load_ralphrc
from ralph.engine import (
    RALPH_DIR_NAME,
    EngineConfig,
    Event,
    IterationEvent,
    check_resume,
    ensure_prd,
)
from ralph.engine import run_loop as engine_run_loop
from ralph.engine import run_prd_loop as engine_run_prd_loop
from ralph.prompt import load_prd
from ralph.tui.widgets import SplitHandle


def format_elapsed(seconds: int) -> str:
    """Format seconds into human-readable elapsed time."""
    if seconds < 3600:
        return f"{seconds // 60}m {seconds % 60:02d}s"
    h = seconds // 3600
    m = (seconds % 3600) // 60
    s = seconds % 60
    return f"{h}h {m:02d}m {s:02d}s"


class OutputLine(Message):
    """A line of output from Claude."""

    def __init__(self, text: str) -> None:
        self.text = text
        super().__init__()


class ToolActivity(Message):
    """A tool call from Claude (for the activity panel)."""

    def __init__(self, tool: str, summary: str) -> None:
        self.tool = tool
        self.summary = summary
        super().__init__()


class IterationBoundary(Message):
    """Marks the start or end of an iteration."""

    def __init__(
        self, iteration: int, max_iter: int, event: str,
        elapsed: int = 0, story_id: str = "",
    ) -> None:
        self.iteration = iteration
        self.max_iter = max_iter
        self.event = event
        self.elapsed = elapsed
        self.story_id = story_id
        super().__init__()


class PromptSent(Message):
    """Carries the prompt text sent to Claude for I/O transparency."""

    def __init__(self, text: str, story_id: str = "") -> None:
        self.text = text
        self.story_id = story_id
        super().__init__()


class LoopFinished(Message):
    """The entire loop has completed."""

    def __init__(self, reason: str, iterations: int, elapsed: int) -> None:
        self.reason = reason
        self.iterations = iterations
        self.elapsed = elapsed
        super().__init__()


class LoopRunner(Screen):
    """Runs the Ralph iteration loop with live streaming output."""

    BINDINGS = [
        ("d", "inject_directive", "Directive"),
        ("b", "back_to_picker", "Back"),
        ("q", "quit_loop", "Quit"),
    ]

    def __init__(
        self,
        plan: Path,
        max_iter: int = 10,
        min_iter: int = 0,
        tools: str | None = None,
        sandbox: bool = True,
        auto_approve: bool = False,
        git_checkpoint: bool = False,
    ) -> None:
        super().__init__()
        self.plan = plan
        self.max_iter = max_iter
        self.min_iter = min_iter
        self.tools_override = tools
        self.sandbox = sandbox
        self.auto_approve = auto_approve
        self.git_checkpoint = git_checkpoint
        self._start_time = 0.0
        self._current_iter = 0
        self._interrupted = False
        self._finished = False
        self._line_count = 0
        self._current_story_id = ""
        self._prd_mode = False

    def compose(self) -> ComposeResult:
        yield Static(id="header-bar")
        with Horizontal(id="runner-body"):
            with Vertical(id="runner-log"):
                yield Label("Live Output", classes="panel-title")
                yield RichLog(
                    id="output-pane",
                    markup=True,
                    wrap=True,
                    auto_scroll=True,
                )
            yield SplitHandle(
                "runner-log", "runner-side",
                left_min=40, right_min=24, id="runner-split",
            )
            with Vertical(id="runner-side"):
                yield Label("Stories", classes="panel-title")
                yield RichLog(
                    id="stories-content",
                    markup=True,
                    wrap=True,
                    max_lines=50,
                )
                yield Label("Activity", classes="panel-title")
                yield RichLog(
                    id="activity-content",
                    markup=True,
                    wrap=True,
                    max_lines=50,
                )
                yield Label("Controls", classes="panel-title")
                yield Markdown(id="controls-content")
        yield Footer()

    def on_mount(self) -> None:
        self._start_time = time.time()
        self._update_header()
        self._update_controls()
        self._refresh_stories()
        self.set_interval(1.0, self._tick)
        self.set_interval(3.0, self._refresh_stories)

        # Check for resume
        ralph_dir = Path.cwd() / RALPH_DIR_NAME
        existing = check_resume(ralph_dir, self.plan)
        if existing:
            resume_iter = existing.get("current_iter", 0)
            prev_status = existing.get("status", "unknown")
            self.app.push_screen(
                ResumeModal(resume_iter, prev_status),
                callback=self._on_resume_decision,
            )
        else:
            self._start_fresh()

    def _start_fresh(self) -> None:
        """Start a fresh run, with PRD review gate if applicable."""
        ralph_dir = Path.cwd() / RALPH_DIR_NAME
        prd_existed = (ralph_dir / "prd.json").is_file()
        if not prd_existed:
            # Fresh conversion needed — ensure_prd will convert
            self._ensure_prd(ralph_dir)
        prd_path = ralph_dir / "prd.json"
        # Show review modal for fresh conversions (not auto-approved)
        if prd_path.is_file() and not prd_existed and not self.auto_approve:
            self.app.push_screen(
                PrdReviewModal(prd_path),
                callback=self._on_prd_review,
            )
        else:
            self.run_loop()

    def _on_prd_review(self, approved: bool | None) -> None:
        if approved:
            self.run_loop()
        else:
            ralph_dir = Path.cwd() / RALPH_DIR_NAME
            prd_path = ralph_dir / "prd.json"
            prd_path.unlink(missing_ok=True)
            self.dismiss(None)

    def _on_resume_decision(self, resume: bool | None) -> None:
        if resume:
            ralph_dir = Path.cwd() / RALPH_DIR_NAME
            existing = check_resume(ralph_dir, self.plan)
            start = existing.get("current_iter", 1) if existing else 1
            self.run_loop(start_iter=start)
        else:
            self.run_loop()

    def _tick(self) -> None:
        self._update_header()

    def _update_header(self) -> None:
        elapsed = (
            int(time.time() - self._start_time) if self._start_time else 0
        )
        status_icon = "\u2022" if not self._interrupted else "!"
        sandbox_str = "on" if self.sandbox else "OFF"

        story_str = ""
        if self._prd_mode and self._current_story_id:
            story_str = f"    Story: {self._current_story_id}"

        self.query_one("#header-bar", Static).update(
            f"  Plan: {self.plan.name}{story_str}    "
            f"Iter: {self._current_iter}/{self.max_iter}    "
            f"Lines: {self._line_count}    "
            f"Sandbox: {sandbox_str}    "
            f"Elapsed: {format_elapsed(elapsed)}  {status_icon}"
        )

    def _refresh_stories(self) -> None:
        """Re-read .ralph/prd.json and update the stories panel."""
        prd_path = Path.cwd() / RALPH_DIR_NAME / "prd.json"
        stories_log = self.query_one("#stories-content", RichLog)
        if not prd_path.is_file():
            # Fall back to status.md for legacy mode
            status_file = Path.cwd() / RALPH_DIR_NAME / "status.md"
            if status_file.is_file():
                content = status_file.read_text().strip()
                if content:
                    stories_log.clear()
                    for line in content.splitlines():
                        stories_log.write(line)
            else:
                stories_log.clear()
                stories_log.write("[dim]Waiting for progress...[/dim]")
            return

        try:
            prd = load_prd(prd_path)
        except (json.JSONDecodeError, OSError):
            return

        stories_log.clear()
        for s in sorted(prd.user_stories, key=lambda x: x.priority):
            if s.passes:
                icon = "[green]V[/green]"
            elif s.id == self._current_story_id:
                icon = "[bold yellow]>[/bold yellow]"
            else:
                icon = " "
            current = (
                " [bold yellow]<- current[/bold yellow]"
                if s.id == self._current_story_id else ""
            )
            stories_log.write(f"{icon} {s.id}: {s.title}{current}")

    def _update_controls(self) -> None:
        controls = (
            "**d** Inject directive  \n"
            "**b** Back to plans  \n"
            "**q** Quit  \n"
        )
        self.query_one("#controls-content", Markdown).update(controls)

    def _ensure_prd(self, ralph_dir: Path) -> bool:
        """Ensure prd.json exists. Convert from plan if needed.

        Returns True if prd.json is available, False otherwise.
        """
        return ensure_prd(ralph_dir, self.plan)

    def _handle_engine_event(self, ev: IterationEvent) -> None:
        """Map engine events to Textual messages."""
        if ev.kind == Event.ITERATION_START:
            self._current_iter = ev.iteration
            self._current_story_id = ev.story_id
            self.post_message(
                IterationBoundary(
                    ev.iteration, ev.max_iter, "start",
                    story_id=ev.story_id,
                )
            )
        elif ev.kind == Event.PROMPT_BUILT:
            self.post_message(PromptSent(
                ev.prompt, story_id=ev.story_id,
            ))
        elif ev.kind == Event.OUTPUT_LINE:
            self._line_count += 1
            self.post_message(OutputLine(ev.line))
        elif ev.kind == Event.TOOL_USE:
            self.post_message(
                ToolActivity(ev.tool_name, ev.tool_input)
            )
        elif ev.kind == Event.ITERATION_END:
            self.post_message(
                IterationBoundary(
                    ev.iteration, ev.max_iter, "end", ev.elapsed,
                )
            )

    @work(thread=True)
    def run_loop(self, start_iter: int = 1) -> None:
        """Run the iteration loop in a background thread."""
        try:
            rc = load_ralphrc()
        except ValueError:
            self.post_message(LoopFinished("config_error", 0, 0))
            return

        effective_tools = (
            self.tools_override or rc["tools"] or RALPH_DEFAULT_TOOLS
        )
        effective_min = (
            self.min_iter if self.min_iter != 0
            else (rc.get("min_iter") or 0)
        )
        effective_max_step = rc.get("max_step_turns") or 25

        config = EngineConfig(
            plan=self.plan,
            max_iter=self.max_iter,
            min_iter=effective_min,
            tools=effective_tools,
            sandbox=self.sandbox,
            max_step_turns=effective_max_step,
            git_checkpoint=self.git_checkpoint,
        )

        # Try prd.json mode first
        ralph_dir = Path.cwd() / RALPH_DIR_NAME
        if self._ensure_prd(ralph_dir):
            self._prd_mode = True
            reason = engine_run_prd_loop(
                config,
                on_event=self._handle_engine_event,
                is_interrupted=lambda: self._interrupted,
                start_iter=start_iter,
            )
        else:
            # Fall back to legacy mode
            self._prd_mode = False
            reason = engine_run_loop(
                config,
                on_event=self._handle_engine_event,
                is_interrupted=lambda: self._interrupted,
                start_iter=start_iter,
            )

        elapsed = int(time.time() - self._start_time)
        self.post_message(LoopFinished(reason, self._current_iter, elapsed))

    @on(PromptSent)
    def on_prompt_sent(self, message: PromptSent) -> None:
        log = self.query_one("#output-pane", RichLog)
        story_info = ""
        if message.story_id:
            story_info = f" {message.story_id}"
        lines = message.text.splitlines()
        log.write(
            f"[dim]Story{story_info} — prompt sent "
            f"({len(lines)} lines)[/dim]"
        )
        log.write("")

    @on(OutputLine)
    def on_output_line(self, message: OutputLine) -> None:
        self.query_one("#output-pane", RichLog).write(
            message.text.rstrip("\n")
        )

    @on(ToolActivity)
    def on_tool_activity(self, message: ToolActivity) -> None:
        activity = self.query_one("#activity-content", RichLog)
        ts = datetime.now().strftime("%H:%M:%S")
        activity.write(
            f"[dim]{ts}[/dim] [bold]{message.tool}[/bold]: "
            f"{message.summary}"
        )

    @on(IterationBoundary)
    def on_iteration_boundary(self, message: IterationBoundary) -> None:
        log = self.query_one("#output-pane", RichLog)
        if message.event == "start":
            ts = datetime.now().strftime("%H:%M:%S")
            story_str = ""
            if message.story_id:
                story_str = f" [{message.story_id}]"
            log.write(
                f"── Iteration {message.iteration}/{message.max_iter}"
                f"{story_str} ── {ts} ──"
            )
        else:
            log.write(
                f"── Iteration {message.iteration} complete"
                f" ({message.elapsed}s) ──\n"
            )

    @on(LoopFinished)
    def on_loop_finished(self, message: LoopFinished) -> None:
        self._finished = True
        log = self.query_one("#output-pane", RichLog)
        elapsed_str = format_elapsed(message.elapsed)
        if message.reason == "done":
            log.write(
                f"\nV Ralph complete after {message.iterations}"
                f" iteration(s) ({elapsed_str})"
            )
        elif message.reason == "interrupted":
            log.write(
                f"\n! Ralph interrupted at iteration"
                f" {message.iterations} ({elapsed_str})"
            )
        else:
            log.write(
                f"\nX Ralph hit max iterations ({message.iterations})"
                f" after {elapsed_str}"
            )
        log.write(
            "\nPress **b** to pick another plan,"
            " **q** to quit."
        )

    def action_inject_directive(self) -> None:
        self.app.push_screen(DirectiveInput())

    def action_back_to_picker(self) -> None:
        if self._finished:
            self.dismiss(None)

    def action_quit_loop(self) -> None:
        if self._finished:
            self.app.exit()
        else:
            self._interrupted = True


class PrdReviewModal(ModalScreen[bool]):
    """Show PRD stories for human review before execution."""

    BINDINGS = [("escape", "cancel", "Cancel")]

    def __init__(self, prd_path: Path) -> None:
        super().__init__()
        self._prd_path = prd_path

    def compose(self) -> ComposeResult:
        prd = load_prd(self._prd_path)
        lines = [f"# {prd.project}\n", f"{prd.description}\n"]
        for s in sorted(prd.user_stories, key=lambda x: x.priority):
            lines.append(f"## {s.id}: {s.title}\n")
            lines.append(f"{s.description}\n")
            if s.acceptance_criteria:
                lines.append("**Acceptance criteria:**\n")
                for c in s.acceptance_criteria:
                    lines.append(f"- {c}\n")
            lines.append("")
        md_text = "\n".join(lines)

        with Vertical(id="confirm-dialog"):
            yield Label("Review PRD", classes="dialog-title")
            yield Markdown(md_text, id="prd-review-content")
            with Horizontal(id="confirm-buttons"):
                yield Button(
                    "Approve", id="confirm-run", variant="primary",
                )
                yield Button(
                    "Reject", id="confirm-cancel", variant="error",
                )

    @on(Button.Pressed)
    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "confirm-run")

    def action_cancel(self) -> None:
        self.dismiss(False)


class ResumeModal(ModalScreen[bool]):
    """Ask whether to resume a previous run."""

    BINDINGS = [("escape", "cancel", "Cancel")]

    def __init__(self, iteration: int, prev_status: str) -> None:
        super().__init__()
        self._iteration = iteration
        self._prev_status = prev_status

    def compose(self) -> ComposeResult:
        with Vertical(id="confirm-dialog"):
            yield Label("Resume Previous Run?", classes="dialog-title")
            yield Label(
                f"Previous run ({self._prev_status}) found at"
                f" iteration {self._iteration}.",
                id="confirm-detail",
            )
            with Horizontal(id="confirm-buttons"):
                yield Button("Resume", id="confirm-run", variant="primary")
                yield Button(
                    "Start Fresh", id="confirm-cancel", variant="default"
                )

    @on(Button.Pressed)
    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "confirm-run")

    def action_cancel(self) -> None:
        self.dismiss(False)


class DirectiveInput(Screen):
    """Minimal input screen for injecting a directive."""

    BINDINGS = [("escape", "cancel", "Cancel")]

    def compose(self) -> ComposeResult:
        yield Input(placeholder="Enter directive...", id="directive-input")

    @on(Input.Submitted, "#directive-input")
    def on_submitted(self, event: Input.Submitted) -> None:
        text = event.value.strip()
        if text:
            directives = Path.cwd() / RALPH_DIR_NAME / "directives.md"
            directives.parent.mkdir(exist_ok=True)
            directives.write_text(text + "\n")
        self.dismiss()

    def action_cancel(self) -> None:
        self.dismiss()
