"""Ralph Wiggum — Textual TUI application."""

from pathlib import Path

from textual.app import App

from ralph.tui.picker import PlanPicker
from ralph.tui.runner import LoopRunner


class RalphApp(App):
    """Main Ralph application — routes between Picker and Runner screens."""

    TITLE = "Ralph Wiggum"
    CSS_PATH = "app.tcss"

    def __init__(
        self,
        plan: Path | None = None,
        max_iter: int = 10,
        min_iter: int = 0,
        tools: str | None = None,
        sandbox: bool = True,
        auto_approve: bool = False,
        git_checkpoint: bool = False,
    ):
        super().__init__()
        self.plan_path = plan
        self.max_iter = max_iter
        self.min_iter = min_iter
        self.tools_override = tools
        self.sandbox = sandbox
        self.auto_approve = auto_approve
        self.git_checkpoint = git_checkpoint

    def on_mount(self) -> None:
        if self.plan_path:
            self.push_screen(
                LoopRunner(
                    self.plan_path,
                    max_iter=self.max_iter,
                    min_iter=self.min_iter,
                    tools=self.tools_override,
                    sandbox=self.sandbox,
                    auto_approve=self.auto_approve,
                    git_checkpoint=self.git_checkpoint,
                ),
                callback=self._on_runner_done,
            )
        else:
            self.push_screen(PlanPicker(), callback=self._on_plan_selected)

    def _on_plan_selected(self, plan: Path | None) -> None:
        if plan is None:
            self.exit()
        else:
            self.push_screen(
                LoopRunner(
                    plan,
                    max_iter=self.max_iter,
                    min_iter=self.min_iter,
                    tools=self.tools_override,
                    sandbox=self.sandbox,
                    auto_approve=self.auto_approve,
                    git_checkpoint=self.git_checkpoint,
                ),
                callback=self._on_runner_done,
            )

    def _on_runner_done(self, result: object) -> None:
        """Runner dismissed — return to the picker."""
        self.push_screen(PlanPicker(), callback=self._on_plan_selected)
