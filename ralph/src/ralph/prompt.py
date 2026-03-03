"""Prompt builder, prd.json schema, and plan conversion."""

from __future__ import annotations

import json
import re
import subprocess
from dataclasses import asdict, dataclass, field
from pathlib import Path

# ---------------------------------------------------------------------------
# prd.json schema
# ---------------------------------------------------------------------------


@dataclass
class UserStory:
    id: str  # "US-001"
    title: str
    description: str  # "As a ..., I want ..., so that ..."
    acceptance_criteria: list[str] = field(default_factory=list)
    priority: int = 0
    passes: bool = False
    notes: str = ""


@dataclass
class PrdDocument:
    project: str
    branch_name: str
    description: str
    user_stories: list[UserStory] = field(default_factory=list)
    plan_context: str = ""


def load_prd(path: Path) -> PrdDocument:
    """Load a prd.json file into a PrdDocument."""
    data = json.loads(path.read_text())
    stories = [
        UserStory(**s) for s in data.get("user_stories", [])
    ]
    return PrdDocument(
        project=data.get("project", ""),
        branch_name=data.get("branch_name", ""),
        description=data.get("description", ""),
        user_stories=stories,
        plan_context=data.get("plan_context", ""),
    )


def save_prd(path: Path, prd: PrdDocument) -> None:
    """Atomically write a PrdDocument to prd.json."""
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(asdict(prd), indent=2) + "\n")
    tmp.rename(path)


# ---------------------------------------------------------------------------
# Markdown plan -> prd.json converter
# ---------------------------------------------------------------------------

_CONVERTER_PROMPT = """\
Convert the following Markdown plan into a JSON object matching this schema:

```json
{
  "project": "<project name from the plan title>",
  "branch_name": "<slugified-project-name>",
  "description": "<brief description from Context section>",
  "plan_context": "<project-wide instructions not specific to any step>",
  "user_stories": [
    {
      "id": "US-001",
      "title": "<step title>",
      "description": "<step description as user story>",
      "acceptance_criteria": ["criterion 1", "criterion 2", "Tests pass"],
      "priority": 1,
      "passes": false,
      "notes": ""
    }
  ]
}
```

Rules:
- Each `### Step N:` section becomes one user story.
- Step title -> story title.
- Step content -> description + acceptance criteria.
- Verification commands (bash commands for build/test/lint) -> acceptance criteria.\
  Include the EXACT commands, not summaries. E.g., "Run: ./gradlew build" not "Build passes".
- Self-review gate items -> acceptance criteria. Preserve each bullet as a separate criterion.
- Context checkpoint instructions -> notes field.
- Always add "Tests pass" as the final criterion if not already present.
- Priority = step order (1-based).
- All stories start with passes: false and empty notes.
- plan_context: Capture project-wide instructions that aren't step-specific \
(technology constraints, patterns to follow, testing requirements). \
Include "Original Design Intent" section verbatim if present. 2-4 sentences.
- Output ONLY valid JSON. No commentary, no markdown fences.

Plan:
"""


def convert_plan_to_prd(plan_file: Path) -> str:
    """Convert a markdown plan to prd.json content via Claude.

    Returns the JSON string. Raises RuntimeError on failure.
    """
    plan_text = plan_file.read_text()
    prompt = _CONVERTER_PROMPT + plan_text

    result = subprocess.run(
        ["claude", "-p", "--dangerously-skip-permissions"],
        input=prompt,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"Claude converter failed (exit {result.returncode}): "
            f"{result.stderr[:200]}"
        )

    output = result.stdout.strip()
    # Strip markdown fences if Claude wrapped them anyway
    if output.startswith("```"):
        lines = output.splitlines()
        lines = lines[1:]  # drop opening fence
        if lines and lines[-1].strip() == "```":
            lines = lines[:-1]
        output = "\n".join(lines)

    # Validate it's valid JSON
    json.loads(output)
    return output


# ---------------------------------------------------------------------------
# Per-story prompt builder
# ---------------------------------------------------------------------------


def build_story_prompt(
    prd: PrdDocument,
    story: UserStory,
    status_file: Path | None = None,
) -> str:
    """Build a focused prompt for a single user story.

    This replaces the old build_prompt() for prd.json-driven execution.
    """
    total = len(prd.user_stories)
    stories_sorted = sorted(prd.user_stories, key=lambda s: s.priority)

    # Build story overview with pass/fail markers
    overview_lines = []
    for s in stories_sorted:
        if s.passes:
            marker = "done"
        elif s.id == story.id:
            marker = "current"
        else:
            marker = "pending"
        icon = {"done": "V", "current": ">", "pending": " "}[marker]
        suffix = " <- YOU ARE HERE" if marker == "current" else ""
        overview_lines.append(f"- {icon} {s.id}: {s.title}{suffix}")

    overview = "\n".join(overview_lines)

    # Acceptance criteria as checklist
    criteria = "\n".join(f"- [ ] {c}" for c in story.acceptance_criteria)

    # Previous progress on this story
    progress = ""
    if story.notes:
        progress = story.notes
    elif status_file and status_file.is_file():
        content = status_file.read_text().strip()
        if content:
            progress = content
    if not progress:
        progress = "Fresh start — no prior work on this story."

    # Use error-specific header when notes contain error markers
    has_errors = (
        "## Errors detected" in progress
        or "## Last traceback" in progress
    )
    progress_header = (
        "## What went wrong last time (fix these issues)"
        if has_errors
        else "## Previous progress on this story"
    )

    plan_ctx = ""
    if prd.plan_context:
        plan_ctx = (
            f"## Project context\n"
            f"{prd.plan_context}\n\n"
        )

    return (
        f"## Context\n"
        f"Project: {prd.project} | Story: {story.id} "
        f"({story.priority}/{total})\n\n"
        f"{plan_ctx}"
        f"## Story overview\n"
        f"{overview}\n\n"
        f"## Your task\n"
        f"**{story.title}**\n"
        f"{story.description}\n\n"
        f"## Acceptance criteria (you MUST verify each one)\n"
        f"{criteria}\n\n"
        f"{progress_header}\n"
        f"{progress}\n\n"
        f"## Rules\n"
        f"- Execute ONLY this story. Do NOT work on other stories.\n"
        f"- Verify EACH acceptance criterion before completing.\n"
        f"- Commit changes with a descriptive message.\n"
        f"- If you cannot finish, update .ralph/status.md with what "
        f"you accomplished.\n"
        f"- Do NOT run git push to main or master branches.\n"
        f"- After verifying all criteria, run a final lint/format pass "
        f"(ruff check, ruff format --check, or the project's linter). "
        f"Fix any issues before declaring done.\n"
        f"- If the project has a code-review or simplify skill, "
        f"use it on changed files before declaring done.\n"
        f"- For stacked PRs: use `git rebase <parent-branch>` "
        f"to keep branches in sync.\n"
        f"- For stacked PRs: use `gh pr create --base <parent-branch>` "
        f"not `--base main`.\n"
        f"- When ALL criteria are verified, output the exact text: "
        f"RALPH_STORY_DONE\n"
    )


# ---------------------------------------------------------------------------
# Legacy prompt builder (kept for headless mode backward compatibility)
# ---------------------------------------------------------------------------


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
        "- Do NOT skip steps or reorder them unless a step is explicitly "
        "marked optional\n"
        "- Do NOT modify files outside the project directory\n"
        "- Do NOT run git push to main or master branches\n"
        "- After verifying all criteria, run a final lint/format pass "
        "(ruff check, ruff format --check, or the project's linter). "
        "Fix any issues before declaring done.\n"
        "- If the project has a code-review or simplify skill, "
        "use it on changed files before declaring done.\n"
        "- For stacked PRs: use `git rebase <parent-branch>` "
        "to keep branches in sync.\n"
        "- For stacked PRs: use `gh pr create --base <parent-branch>` "
        "not `--base main`.\n"
        "- Do NOT output RALPH_DONE until .ralph/status.md shows ALL "
        "steps marked [x]\n"
        "- When ALL steps are marked [x] in status.md and all tests pass, "
        "output the exact text: RALPH_DONE\n",
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
        parts.append(
            "## Previous progress\nFresh start — no prior iterations.\n"
        )

    return "\n".join(parts)


def parse_progress(status_text: str) -> tuple[int, int]:
    """Parse checkbox progress from status.md content.

    Returns (completed, total) count. Returns (0, 0) if no checkboxes found.
    """
    done = len(re.findall(r"- \[x\]", status_text, re.IGNORECASE))
    pending = len(re.findall(r"- \[ \]", status_text))
    return (done, pending + done)
