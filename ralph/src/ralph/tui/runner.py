"""LoopRunner screen — streaming iteration loop with live output."""

import time
from datetime import datetime
from pathlib import Path

from textual import on, work
from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical
from textual.message import Message
from textual.screen import Screen
from textual.widgets import Footer, Input, Label, Markdown, RichLog, Static

from ralph.config import RALPH_DEFAULT_TOOLS, load_ralphrc
from ralph.engine import (
    RALPH_DIR_NAME,
    EngineConfig,
    Event,
    IterationEvent,
)
from ralph.engine import run_loop as engine_run_loop


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


class IterationBoundary(Message):
    """Marks the start or end of an iteration."""

    def __init__(
        self, iteration: int, max_iter: int, event: str, elapsed: int = 0
    ) -> None:
        self.iteration = iteration
        self.max_iter = max_iter
        self.event = event
        self.elapsed = elapsed
        super().__init__()


class PromptSent(Message):
    """Carries the prompt text sent to Claude for I/O transparency."""

    def __init__(self, text: str) -> None:
        self.text = text
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
        tools: str | None = None,
        sandbox: bool = True,
    ) -> None:
        super().__init__()
        self.plan = plan
        self.max_iter = max_iter
        self.tools_override = tools
        self.sandbox = sandbox
        self._start_time = 0.0
        self._current_iter = 0
        self._interrupted = False
        self._finished = False
        self._last_prompt = ""
        self._progress: tuple[int, int] = (0, 0)

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
            with Vertical(id="runner-side"):
                yield Label("Status", classes="panel-title")
                yield Markdown(id="status-content")
                yield Label("Prompt", classes="panel-title")
                yield Markdown(id="prompt-content")
                yield Label("Controls", classes="panel-title")
                yield Markdown(id="controls-content")
        yield Footer()

    def on_mount(self) -> None:
        self._start_time = time.time()
        self._update_header()
        self._update_controls()
        self._refresh_status()
        self.set_interval(1.0, self._tick)
        self.set_interval(3.0, self._refresh_status)
        self.run_loop()

    def _tick(self) -> None:
        self._update_header()

    def _update_header(self) -> None:
        elapsed = int(time.time() - self._start_time) if self._start_time else 0
        status_icon = "\u2022" if not self._interrupted else "!"
        sandbox_str = "on" if self.sandbox else "OFF"

        progress_str = ""
        if self._progress[1] > 0:
            done, total = self._progress
            pct = int(done / total * 100)
            progress_str = f"    Steps: {done}/{total} ({pct}%)"

        self.query_one("#header-bar", Static).update(
            f"  Plan: {self.plan.name}    "
            f"Iter: {self._current_iter}/{self.max_iter}    "
            f"Sandbox: {sandbox_str}    "
            f"Elapsed: {format_elapsed(elapsed)}"
            f"{progress_str}  {status_icon}"
        )

    def _refresh_status(self) -> None:
        """Re-read .ralph/status.md and update the sidebar."""
        from ralph.prompt import parse_progress

        status_file = Path.cwd() / RALPH_DIR_NAME / "status.md"
        md_widget = self.query_one("#status-content", Markdown)
        if status_file.is_file():
            content = status_file.read_text().strip()
            if content:
                md_widget.update(content)
                self._progress = parse_progress(content)
        else:
            md_widget.update("*Waiting for status...*")

    def _update_controls(self) -> None:
        controls = (
            "- [bold]d[/bold] Inject directive\n"
            "- [bold]b[/bold] Back to plans\n"
            "- [bold]q[/bold] Quit\n"
        )
        self.query_one("#controls-content", Markdown).update(controls)

    def _update_prompt_preview(self, text: str) -> None:
        lines = text.splitlines()
        if len(lines) > 120:
            lines = lines[:120] + [
                "", f"... ({len(text.splitlines()) - 120} more lines)"
            ]
        preview = "```markdown\n" + "\n".join(lines) + "\n```"
        self.query_one("#prompt-content", Markdown).update(preview)

    def _handle_engine_event(self, ev: IterationEvent) -> None:
        """Map engine events to Textual messages."""
        if ev.kind == Event.ITERATION_START:
            self._current_iter = ev.iteration
            self.post_message(
                IterationBoundary(ev.iteration, ev.max_iter, "start")
            )
        elif ev.kind == Event.PROMPT_BUILT:
            self.post_message(PromptSent(ev.prompt))
        elif ev.kind == Event.OUTPUT_LINE:
            self.post_message(OutputLine(ev.line))
        elif ev.kind == Event.ITERATION_END:
            self.post_message(
                IterationBoundary(
                    ev.iteration, ev.max_iter, "end", ev.elapsed
                )
            )

    @work(thread=True)
    def run_loop(self) -> None:
        """Run the iteration loop in a background thread."""
        try:
            rc = load_ralphrc()
        except ValueError:
            self.post_message(LoopFinished("config_error", 0, 0))
            return

        effective_tools = self.tools_override or rc["tools"] or RALPH_DEFAULT_TOOLS

        config = EngineConfig(
            plan=self.plan,
            max_iter=self.max_iter,
            tools=effective_tools,
            sandbox=self.sandbox,
        )

        reason = engine_run_loop(
            config,
            on_event=self._handle_engine_event,
            is_interrupted=lambda: self._interrupted,
        )

        elapsed = int(time.time() - self._start_time)
        self.post_message(LoopFinished(reason, self._current_iter, elapsed))

    @on(PromptSent)
    def on_prompt_sent(self, message: PromptSent) -> None:
        log = self.query_one("#output-pane", RichLog)
        for line in message.text.splitlines():
            log.write(f"[dim]{line}[/dim]")
        log.write("")
        self._last_prompt = message.text
        self._update_prompt_preview(message.text)

    @on(OutputLine)
    def on_output_line(self, message: OutputLine) -> None:
        self.query_one("#output-pane", RichLog).write(message.text.rstrip("\n"))

    @on(IterationBoundary)
    def on_iteration_boundary(self, message: IterationBoundary) -> None:
        log = self.query_one("#output-pane", RichLog)
        if message.event == "start":
            ts = datetime.now().strftime("%H:%M:%S")
            log.write(
                f"── Iteration {message.iteration}/{message.max_iter}"
                f" ── {ts} ──"
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
                f"\n✓ Ralph complete after {message.iterations}"
                f" iteration(s) ({elapsed_str})"
            )
        elif message.reason == "interrupted":
            log.write(
                f"\n⚠ Ralph interrupted at iteration"
                f" {message.iterations} ({elapsed_str})"
            )
        else:
            log.write(
                f"\n✗ Ralph hit max iterations ({message.iterations})"
                f" after {elapsed_str}"
            )
        log.write(
            "\nPress [bold]b[/bold] to pick another plan,"
            " [bold]q[/bold] to quit."
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
