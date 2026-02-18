""".ralphrc loading and defaults."""

import re
from pathlib import Path

RALPH_DEFAULT_TOOLS = (
    "Edit Read Write Glob Grep "
    "Bash(git:*) "
    "Bash(npm:*) Bash(npx:*) Bash(pytest:*) Bash(python:*) "
    "Bash(ruff:*) Bash(make:*) Bash(cargo:*) Bash(tox:*)"
)

_ALLOWED_LINE = re.compile(r"^\s*(#|$|RALPH_TOOLS=|RALPH_MAX_ITER=|RALPH_MIN_ITER=|RALPH_SANDBOX=)")


def load_ralphrc(path: Path | None = None) -> dict:
    """Load .ralphrc from the given path (or cwd/.ralphrc).

    Returns dict with 'tools' and 'max_iter' keys (None if unset).
    Raises ValueError if .ralphrc contains disallowed lines.
    """
    rc = path or Path.cwd() / ".ralphrc"
    result: dict = {"tools": None, "max_iter": None, "min_iter": None, "sandbox": None}

    if not rc.is_file():
        return result

    bad_lines: list[tuple[int, str]] = []
    for lineno, line in enumerate(rc.read_text().splitlines(), 1):
        if not _ALLOWED_LINE.match(line):
            bad_lines.append((lineno, line))

    if bad_lines:
        detail = "\n".join(f"  line {n}: {text}" for n, text in bad_lines)
        raise ValueError(
            f".ralphrc contains disallowed lines. "
            f"Only RALPH_TOOLS, RALPH_MAX_ITER, RALPH_MIN_ITER, "
            f"and RALPH_SANDBOX are permitted.\n{detail}"
        )

    for line in rc.read_text().splitlines():
        line = line.strip()
        if line.startswith("RALPH_TOOLS="):
            result["tools"] = line.split("=", 1)[1].strip('"').strip("'")
        elif line.startswith("RALPH_MAX_ITER="):
            try:
                result["max_iter"] = int(line.split("=", 1)[1].strip())
            except ValueError:
                pass
        elif line.startswith("RALPH_MIN_ITER="):
            try:
                result["min_iter"] = int(line.split("=", 1)[1].strip())
            except ValueError:
                pass
        elif line.startswith("RALPH_SANDBOX="):
            val = line.split("=", 1)[1].strip('"').strip("'").lower()
            result["sandbox"] = val in ("true", "1", "yes")

    return result
