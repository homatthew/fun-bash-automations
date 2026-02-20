"""ralph run — core iteration loop."""

import signal
import sys
import time
from datetime import datetime
from pathlib import Path

import typer
from rich.prompt import IntPrompt

from ralph import ui
from ralph.config import RALPH_DEFAULT_TOOLS, load_ralphrc
from ralph.engine import (
    PLANS_DIR,
    RALPH_DIR_NAME,
    EngineConfig,
    Event,
    IterationEvent,
    check_resume,
    ensure_prd,
)
from ralph.engine import run_loop as engine_run_loop
from ralph.engine import run_prd_loop as engine_run_prd_loop

_interrupted = False


def _sigint_handler(signum, frame):
    global _interrupted
    _interrupted = True
    ui.warn("Interrupt received — finishing current iteration…")


def _pick_plan() -> Path:
    """Interactive plan picker — shows basenames, returns full path."""
    if not PLANS_DIR.is_dir():
        ui.error(f"No plans directory at {PLANS_DIR}/")
        raise typer.Exit(1)

    plans = sorted(PLANS_DIR.glob("*.md"), key=lambda p: p.stat().st_mtime, reverse=True)
    if not plans:
        ui.error(f"No .md files in {PLANS_DIR}/")
        raise typer.Exit(1)

    ui.console.print("\n[bold]Select a plan (newest first):[/bold]\n")
    for i, p in enumerate(plans, 1):
        ui.console.print(f"  [cyan]{i}[/cyan]  {p.name}")
    ui.console.print()

    choice = IntPrompt.ask("Plan number", default=1)
    if choice < 1 or choice > len(plans):
        ui.error(f"Invalid choice: {choice}")
        raise typer.Exit(1)

    return plans[choice - 1]


def _headless_event_handler(ev: IterationEvent) -> None:
    """Map engine events to Rich console output."""
    if ev.kind == Event.ITERATION_START:
        ui.iter_header(ev.iteration, ev.max_iter, datetime.now().strftime("%H:%M:%S"))
        if ev.story_id:
            ui.console.print(f"  Story: [cyan]{ev.story_id}[/cyan]")
    elif ev.kind == Event.OUTPUT_LINE:
        sys.stdout.write(ev.line)
        sys.stdout.flush()
    elif ev.kind == Event.ITERATION_END:
        ui.header(f"Iteration {ev.iteration}/{ev.max_iter} complete ({ev.elapsed}s)")


def run(
    plan: Path | None = typer.Argument(
        None, help="Path to plan .md file (omit for interactive picker)"
    ),
    max_iter: int = typer.Option(10, "--max", "-n", help="Max iterations"),
    tools: str | None = typer.Option(None, "--tools", "-t", help="Tool scope override"),
    no_tui: bool = typer.Option(False, "--no-tui", help="Disable TUI, use headless mode"),
    no_sandbox: bool = typer.Option(
        False, "--no-sandbox", help="Disable sandbox enforcement"
    ),
    min_iter: int = typer.Option(
        0, "--min-iter", help="Min iterations before accepting RALPH_DONE"
    ),
    auto_approve: bool = typer.Option(
        False, "--auto-approve", "-y", help="Skip PRD review prompt"
    ),
    git_checkpoint: bool = typer.Option(
        False, "--git-checkpoint", help="Rollback git on failed iterations"
    ),
) -> None:
    """Execute a plan in an autonomous iteration loop."""
    # Load .ralphrc config — CLI args take priority
    try:
        rc = load_ralphrc()
    except ValueError as e:
        ui.error(str(e))
        raise typer.Exit(1)

    # Sandbox: ON by default, --no-sandbox or RALPH_SANDBOX=false disables
    if no_sandbox:
        sandbox_enabled = False
    elif rc["sandbox"] is not None:
        sandbox_enabled = rc["sandbox"]
    else:
        sandbox_enabled = True

    # Auto-approve: OFF by default, --auto-approve or RALPH_AUTO_APPROVE=true enables
    effective_auto_approve = auto_approve or rc.get("auto_approve") or False

    # Git checkpoint: OFF by default, --git-checkpoint or RALPH_GIT_CHECKPOINT=true enables
    effective_git_checkpoint = git_checkpoint or rc.get("git_checkpoint") or False

    if not no_tui:
        from ralph.tui.app import RalphApp

        app = RalphApp(
            plan=plan, max_iter=max_iter, min_iter=min_iter,
            tools=tools, sandbox=sandbox_enabled,
            auto_approve=effective_auto_approve,
            git_checkpoint=effective_git_checkpoint,
        )
        app.run()
        return

    global _interrupted
    _interrupted = False

    # Resolve plan file
    if plan is None:
        plan = _pick_plan()

    if not plan.is_file():
        ui.error(f"Plan not found: {plan}")
        raise typer.Exit(1)

    effective_tools = tools or rc["tools"] or RALPH_DEFAULT_TOOLS
    effective_max = max_iter if max_iter != 10 else (rc["max_iter"] or 10)
    effective_min = min_iter if min_iter != 0 else (rc["min_iter"] or 0)

    # Build engine config
    config = EngineConfig(
        plan=plan,
        max_iter=effective_max,
        min_iter=effective_min,
        tools=effective_tools,
        sandbox=sandbox_enabled,
        git_checkpoint=effective_git_checkpoint,
    )

    log_dir = Path.cwd() / RALPH_DIR_NAME

    # Check for resume
    start_iter = 1
    existing = check_resume(log_dir, plan)
    if existing:
        from rich.prompt import Confirm

        resume_iter = existing.get("current_iter", 0)
        prev_status = existing.get("status", "unknown")
        if Confirm.ask(
            f"Previous run found ({prev_status} at iteration {resume_iter}). Resume?",
            default=True,
        ):
            start_iter = resume_iter

    # Header
    min_iter_str = f"\nMin iter:   {effective_min}" if effective_min > 0 else ""
    ui.header(
        f"Ralph Wiggum Loop\n"
        f"Plan:       {plan.name}\n"
        f"Max iter:   {effective_max}{min_iter_str}\n"
        f"Sandbox:    {'on' if sandbox_enabled else 'OFF'}\n"
        f"Tools:      {effective_tools[:60]}…\n"
        f"Logs:       {log_dir}/"
    )

    # Install signal handler
    prev_handler = signal.signal(signal.SIGINT, _sigint_handler)
    start_time = time.time()

    try:
        ralph_dir = Path.cwd() / RALPH_DIR_NAME
        prd_available = ensure_prd(ralph_dir, plan)

        # Review gate: show PRD summary and ask for approval
        if prd_available and start_iter == 1 and not effective_auto_approve:
            from rich.prompt import Confirm as RichConfirm

            _print_prd_summary(ralph_dir / "prd.json")
            if not RichConfirm.ask("Approve this PRD?", default=True):
                (ralph_dir / "prd.json").unlink(missing_ok=True)
                ui.warn("PRD rejected — exiting.")
                raise typer.Exit(0)

        if prd_available:
            reason = engine_run_prd_loop(
                config,
                on_event=_headless_event_handler,
                is_interrupted=lambda: _interrupted,
                start_iter=start_iter,
            )
        else:
            reason = engine_run_loop(
                config,
                on_event=_headless_event_handler,
                is_interrupted=lambda: _interrupted,
                start_iter=start_iter,
            )
    finally:
        signal.signal(signal.SIGINT, prev_handler)

    # Summary
    elapsed = int(time.time() - start_time)
    status_file = Path.cwd() / RALPH_DIR_NAME / "status.md"
    if reason == "done":
        ui.success(f"Ralph complete ({elapsed}s)\nLogs in .ralph/")
    elif reason == "interrupted":
        ui.warn(f"Ralph interrupted ({elapsed}s)\nLogs in .ralph/")
    else:
        ui.error(
            f"Ralph hit max iterations ({effective_max}) after {elapsed}s\nLogs in .ralph/"
        )
    _print_status_summary(status_file)


def _print_prd_summary(prd_path: Path) -> None:
    """Print a summary of the PRD stories for human review."""
    from ralph.prompt import load_prd

    prd = load_prd(prd_path)
    ui.console.print("\n[bold]PRD Stories:[/bold]\n")
    for s in sorted(prd.user_stories, key=lambda x: x.priority):
        ui.console.print(f"  [cyan]{s.id}[/cyan] {s.title}")
        for c in s.acceptance_criteria:
            ui.console.print(f"    - {c}")
    ui.console.print()


def _print_status_summary(status_file: Path) -> None:
    """Print status.md contents if present."""
    if status_file.is_file():
        content = status_file.read_text().strip()
        if content:
            ui.console.print("\n[bold]Last known progress:[/bold]")
            ui.console.print(content)
            ui.console.print()
