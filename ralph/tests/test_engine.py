"""Tests for the shared iteration engine."""

import json
from pathlib import Path

from ralph.engine import PLANS_DIR, RALPH_DIR_NAME, SANDBOX_SETTINGS


def test_plans_dir_is_home_claude_plans():
    assert PLANS_DIR == Path.home() / ".claude" / "plans"


def test_ralph_dir_name():
    assert RALPH_DIR_NAME == ".ralph"


def test_sandbox_settings_is_valid_json():
    parsed = json.loads(SANDBOX_SETTINGS)
    assert parsed["sandbox"]["enabled"] is True
    assert parsed["sandbox"]["autoAllowBashIfSandboxed"] is True
