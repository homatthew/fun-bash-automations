"""ralph init — project setup (.ralphrc)."""

from pathlib import Path

import typer

from ralph import ui

_GRADLE_TOOLS = (
    "Edit Read Write Glob Grep "
    "Bash(git add:*) Bash(git commit:*) Bash(git status:*) "
    "Bash(git diff:*) Bash(git log:*) Bash(./gradlew:*) Bash(newt:*)"
)
_GRADLE_RC = f"""\
# Ralph config for Gradle/Java project
RALPH_TOOLS="{_GRADLE_TOOLS}"
RALPH_MAX_ITER=15
RALPH_SANDBOX=true
"""

_NODE_TOOLS = (
    "Edit Read Write Glob Grep "
    "Bash(git add:*) Bash(git commit:*) Bash(git status:*) "
    "Bash(git diff:*) Bash(git log:*) Bash(npm test:*) "
    "Bash(npm run build:*) Bash(npm run lint:*)"
)
_NODE_RC = f"""\
# Ralph config for Node.js project
RALPH_TOOLS="{_NODE_TOOLS}"
RALPH_MAX_ITER=10
RALPH_SANDBOX=true
"""

_PYTHON_TOOLS = (
    "Edit Read Write Glob Grep "
    "Bash(git add:*) Bash(git commit:*) Bash(git status:*) "
    "Bash(git diff:*) Bash(git log:*) Bash(pytest:*) Bash(newt:*) Bash(tox:*)"
)
_PYTHON_RC = f"""\
# Ralph config for Python project
RALPH_TOOLS="{_PYTHON_TOOLS}"
RALPH_MAX_ITER=10
RALPH_SANDBOX=true
"""

_GITIGNORE_ENTRIES = [".ralphrc", ".ralph/"]


def init() -> None:
    """Initialize the current project for Ralph (creates .ralphrc)."""
    cwd = Path.cwd()
    rc_path = cwd / ".ralphrc"

    if rc_path.exists():
        ui.error(".ralphrc already exists. Edit it directly.")
        raise typer.Exit(1)

    # Detect project type
    content: str | None = None
    project_type: str | None = None

    if any((cwd / f).exists() for f in ("build.gradle", "build.gradle.kts", "gradlew")):
        content = _GRADLE_RC
        project_type = "Gradle/Java"
    elif (cwd / "package.json").exists():
        content = _NODE_RC
        project_type = "Node.js"
    elif any((cwd / f).exists() for f in ("pyproject.toml", "setup.py", "tox.ini")):
        content = _PYTHON_RC
        project_type = "Python"

    if content is None:
        ui.error(
            "No project type detected "
            "(looked for build.gradle, package.json, pyproject.toml, etc.).\n"
            "Create .ralphrc manually or use global defaults."
        )
        raise typer.Exit(1)

    rc_path.write_text(content)
    ui.success(f"Created .ralphrc (detected {project_type} project)")

    # Suggest .gitignore additions
    gitignore = cwd / ".gitignore"
    missing: list[str] = []
    existing = gitignore.read_text() if gitignore.is_file() else ""
    for entry in _GITIGNORE_ENTRIES:
        if entry not in existing:
            missing.append(entry)

    if missing:
        ui.console.print(
            "\n[yellow]Suggestion:[/yellow] Add to .gitignore:\n"
            + "\n".join(f"  {e}" for e in missing)
        )

    ui.console.print(
        "\nNext: use plan mode to create a plan, then run [bold]ralph[/bold] to execute it."
    )
