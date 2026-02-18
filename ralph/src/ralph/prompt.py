"""Prompt builder with status.md + directives context."""

import re
from pathlib import Path


def build_prompt(plan_file: str, status_file: Path | None = None) -> str:
    """Build the prompt for a Claude --print invocation.

    Args:
        plan_file: Path to the plan .md file.
        status_file: Path to .ralph/status.md (inter-iteration context).
    """
    parts = [
        f"## Task\n"
        f"Execute the implementation plan in {plan_file}\n\n"
        f"Read the plan file first, then work through it step by step.\n",
        "## Completion criteria\n"
        "- All steps in the plan are implemented\n"
        "- All tests pass\n"
        "- Each step has its own commit with a descriptive message\n"
        "- Code compiles/lints cleanly\n",
        "## Rules\n"
        "- Work through the plan one step at a time, in order\n"
        "- After completing each step, run the relevant tests\n"
        "- Commit after each passing step\n"
        "- If tests fail, fix the issue before moving to the next step\n"
        "- Do NOT skip steps or reorder them unless a step is explicitly marked optional\n"
        "- Do NOT modify files outside the project directory\n"
        "- When ALL steps are complete and all tests pass, output the exact text: RALPH_DONE\n",
        "## Progress tracking\n"
        "After each step you complete, update the file .ralph/status.md "
        "using this exact format:\n\n"
        "```\n"
        "- [x] Step 1: brief description (DONE)\n"
        "- [x] Step 2: brief description (DONE)\n"
        "- [ ] Step 3: brief description (IN PROGRESS)\n"
        "- [ ] Step 4: brief description\n"
        "\n"
        "Current: Step 3\n"
        "Notes: any blockers or decisions\n"
        "```\n\n"
        "Use `- [x]` for completed steps and `- [ ]` for pending steps.\n"
        "This format allows progress to be parsed programmatically.\n"
        "This file persists across iterations so the next iteration "
        "knows where you left off.\n",
    ]

    # Append previous progress if status.md exists
    if status_file and status_file.is_file():
        content = status_file.read_text().strip()
        if content:
            parts.append(
                f"## Previous progress\n"
                f"The following is from a prior iteration's status file:\n\n"
                f"{content}\n"
            )
    else:
        parts.append("## Previous progress\nFresh start — no prior iterations.\n")

    return "\n".join(parts)


def parse_progress(status_text: str) -> tuple[int, int]:
    """Parse checkbox progress from status.md content.

    Returns (completed, total) count. Returns (0, 0) if no checkboxes found.
    """
    done = len(re.findall(r"- \[x\]", status_text, re.IGNORECASE))
    pending = len(re.findall(r"- \[ \]", status_text))
    return (done, pending + done)
