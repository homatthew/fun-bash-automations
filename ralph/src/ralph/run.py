"""ralph run — core iteration loop."""

import json
import os
import signal
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

import typer
from rich.prompt import IntPrompt

from ralph import ui
from ralph.config import RALPH_DEFAULT_TOOLS, load_ralphrc
from ralph.prompt import build_prompt

PLANS_DIR = Path.home() / ".claude" / "plans"
SANDBOX_SETTINGS = json.dumps({"sandbox": {"enabled": True, "autoAllowBashIfSandboxed": True}})

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


def _write_meta(meta_path: Path, data: dict) -> None:
    """Atomic write of meta.json (write tmp, rename)."""
    tmp = meta_path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    tmp.rename(meta_path)


def run(
    plan: Path | None = typer.Argument(
        None, help="Path to plan .md file (omit for interactive picker)"
    ),
    max_iter: int = typer.Option(10, "--max", "-n", help="Max iterations"),
    tools: str | None = typer.Option(None, "--tools", "-t", help="Tool scope override"),
    no_tui: bool = typer.Option(False, "--no-tui", help="Disable TUI, use headless mode"),
    no_sandbox: bool = typer.Option(False, "--no-sandbox", help="Disable sandbox enforcement"),
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

    if not no_tui:
        from ralph.tui.app import RalphApp

        app = RalphApp(plan=plan, max_iter=max_iter, tools=tools, sandbox=sandbox_enabled)
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

    plan_name = plan.name

    effective_tools = tools or rc["tools"] or RALPH_DEFAULT_TOOLS
    effective_max = max_iter if max_iter != 10 else (rc["max_iter"] or 10)

    # Set up .ralph/ directory
    log_dir = Path.cwd() / ".ralph"
    log_dir.mkdir(exist_ok=True)
    status_file = log_dir / "status.md"
    meta_path = log_dir / "meta.json"
    directives_file = log_dir / "directives.md"

    meta = {
        "plan": str(plan),
        "pid": os.getpid(),
        "start_time": datetime.now().isoformat(),
        "max_iter": effective_max,
        "status": "running",
        "current_iter": 0,
    }
    _write_meta(meta_path, meta)

    # Header
    ui.header(
        f"Ralph Wiggum Loop\n"
        f"Plan:       {plan_name}\n"
        f"Max iter:   {effective_max}\n"
        f"Sandbox:    {'on' if sandbox_enabled else 'OFF'}\n"
        f"Tools:      {effective_tools[:60]}…\n"
        f"Logs:       {log_dir}/"
    )

    # Install signal handler
    prev_handler = signal.signal(signal.SIGINT, _sigint_handler)
    start_time = time.time()

    try:
        for i in range(1, effective_max + 1):
            if _interrupted:
                break

            meta["current_iter"] = i
            _write_meta(meta_path, meta)

            iter_start = time.time()
            log_file = log_dir / f"iteration-{i}.log"

            # Check for directives
            prompt_extra = ""
            if directives_file.is_file():
                directive_content = directives_file.read_text().strip()
                if directive_content:
                    prompt_extra = f"\n## Operator directive (priority)\n{directive_content}\n"
                    # Archive the directive
                    archive = log_dir / f"directive-consumed-{i}.md"
                    directives_file.rename(archive)

            # Build prompt
            prompt_content = build_prompt(str(plan), status_file)
            if prompt_extra:
                prompt_content = prompt_content + "\n" + prompt_extra

            ui.iter_header(i, effective_max, datetime.now().strftime("%H:%M:%S"))

            # Run claude, stream to both terminal and log file
            cmd = ["claude", "--print", "--allowedTools", effective_tools]
            if sandbox_enabled:
                cmd.extend(["--settings", SANDBOX_SETTINGS])
            with open(log_file, "w") as lf:
                proc = subprocess.Popen(
                    cmd,
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                )
                proc.stdin.write(prompt_content)
                proc.stdin.close()

                for line in proc.stdout:
                    sys.stdout.write(line)
                    sys.stdout.flush()
                    lf.write(line)

                exit_code = proc.wait()

            iter_elapsed = int(time.time() - iter_start)
            ui.header(f"Iteration {i}/{effective_max} complete ({iter_elapsed}s)")

            # Check for completion signal
            log_text = log_file.read_text()
            if "RALPH_DONE" in log_text:
                elapsed = int(time.time() - start_time)
                meta["status"] = "done"
                _write_meta(meta_path, meta)
                ui.success(
                    f"Ralph complete after {i} iteration(s) ({elapsed}s)\nLogs in {log_dir}/"
                )
                _print_status_summary(status_file)
                return

            # Warn on non-zero exit
            if exit_code != 0:
                ui.warn(f"claude exited with code {exit_code} on iteration {i}\nSee {log_file}")

    finally:
        signal.signal(signal.SIGINT, prev_handler)

    # Reached max iterations or interrupted
    elapsed = int(time.time() - start_time)
    if _interrupted:
        meta["status"] = "interrupted"
        _write_meta(meta_path, meta)
        ui.warn(
            f"Ralph interrupted at iteration {meta['current_iter']} ({elapsed}s)\n"
            f"Logs in {log_dir}/"
        )
    else:
        meta["status"] = "max_iterations"
        _write_meta(meta_path, meta)
        ui.error(f"Ralph hit max iterations ({effective_max}) after {elapsed}s\nLogs in {log_dir}/")

    _print_status_summary(status_file)


def _print_status_summary(status_file: Path) -> None:
    """Print status.md contents if present."""
    if status_file.is_file():
        content = status_file.read_text().strip()
        if content:
            ui.console.print("\n[bold]Last known progress:[/bold]")
            ui.console.print(content)
            ui.console.print()
