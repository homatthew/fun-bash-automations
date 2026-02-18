import time
from pathlib import Path

from ralph.tui.picker import (
    MAX_VISIBLE_PLANS,
    _slug_from_filename,
    plan_heading,
    relative_time,
)


def test_relative_time_seconds():
    now = time.time()
    assert relative_time(now - 30) == "30s"


def test_relative_time_minutes():
    now = time.time()
    assert relative_time(now - 120) == "2m"


def test_relative_time_hours():
    now = time.time()
    assert relative_time(now - 7200) == "2h"


def test_relative_time_days():
    now = time.time()
    assert relative_time(now - 86400 * 3) == "3d"


# --- plan_heading tests ---


def test_plan_heading_found(tmp_path: Path):
    f = tmp_path / "plan.md"
    f.write_text("# My Great Plan\n\nSome body text.\n")
    assert plan_heading(f) == "My Great Plan"


def test_plan_heading_blank_lines_before(tmp_path: Path):
    f = tmp_path / "plan.md"
    f.write_text("\n\n# Delayed Heading\nBody.\n")
    assert plan_heading(f) == "Delayed Heading"


def test_plan_heading_no_heading(tmp_path: Path):
    f = tmp_path / "plan.md"
    f.write_text("Just body text with no heading.\n")
    assert plan_heading(f) is None


def test_plan_heading_missing_file(tmp_path: Path):
    f = tmp_path / "nonexistent.md"
    assert plan_heading(f) is None


def test_plan_heading_empty_file(tmp_path: Path):
    f = tmp_path / "empty.md"
    f.write_text("")
    assert plan_heading(f) is None


# --- _slug_from_filename tests ---


def test_slug_from_filename_standard():
    assert _slug_from_filename(Path("20250215-143022-add-user-auth.md")) == "Add User Auth"


def test_slug_from_filename_no_timestamp():
    assert _slug_from_filename(Path("plan.md")) == "Plan"


def test_slug_from_filename_short():
    assert _slug_from_filename(Path("short-name.md")) == "Short Name"


def test_slug_from_filename_long_slug():
    assert (
        _slug_from_filename(Path("20250215-143022-fix-auth-token-refresh.md"))
        == "Fix Auth Token Refresh"
    )


def test_slug_from_filename_empty_slug():
    assert _slug_from_filename(Path("20250215-143022-.md")) == ""


# --- MAX_VISIBLE_PLANS constant ---


def test_max_visible_plans_is_five():
    assert MAX_VISIBLE_PLANS == 5
