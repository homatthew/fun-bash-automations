"""Core iteration engine — shared constants, helpers, and loop logic."""

import json
from pathlib import Path

# --- Shared constants ---
PLANS_DIR = Path.home() / ".claude" / "plans"
RALPH_DIR_NAME = ".ralph"
SANDBOX_SETTINGS = json.dumps({"sandbox": {"enabled": True, "autoAllowBashIfSandboxed": True}})
