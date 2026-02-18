from ralph.config import RALPH_DEFAULT_TOOLS, load_ralphrc


def test_default_tools_contains_core_entries():
    assert "Edit" in RALPH_DEFAULT_TOOLS
    assert "Bash(git:*)" in RALPH_DEFAULT_TOOLS
    assert "Bash(pytest:*)" in RALPH_DEFAULT_TOOLS


def test_load_ralphrc_returns_defaults_when_no_file(tmp_path):
    result = load_ralphrc(tmp_path / ".ralphrc")
    assert result == {"tools": None, "max_iter": None, "min_iter": None, "sandbox": None}


def test_load_ralphrc_parses_values(tmp_path):
    rc = tmp_path / ".ralphrc"
    rc.write_text('RALPH_TOOLS="Edit Read Write"\nRALPH_MAX_ITER=20\n')
    result = load_ralphrc(rc)
    assert result["tools"] == "Edit Read Write"
    assert result["max_iter"] == 20


def test_load_ralphrc_rejects_disallowed_lines(tmp_path):
    rc = tmp_path / ".ralphrc"
    rc.write_text("rm -rf /\n")
    try:
        load_ralphrc(rc)
        assert False, "Should have raised ValueError"
    except ValueError:
        pass


def test_load_ralphrc_parses_sandbox_true(tmp_path):
    rc = tmp_path / ".ralphrc"
    rc.write_text("RALPH_SANDBOX=true\n")
    result = load_ralphrc(rc)
    assert result["sandbox"] is True


def test_load_ralphrc_parses_sandbox_false(tmp_path):
    rc = tmp_path / ".ralphrc"
    rc.write_text("RALPH_SANDBOX=false\n")
    result = load_ralphrc(rc)
    assert result["sandbox"] is False


def test_load_ralphrc_sandbox_defaults_none(tmp_path):
    rc = tmp_path / ".ralphrc"
    rc.write_text('RALPH_TOOLS="Edit Read"\n')
    result = load_ralphrc(rc)
    assert result["sandbox"] is None


def test_load_ralphrc_parses_min_iter(tmp_path):
    rc = tmp_path / ".ralphrc"
    rc.write_text("RALPH_MIN_ITER=3\n")
    result = load_ralphrc(rc)
    assert result["min_iter"] == 3


def test_load_ralphrc_min_iter_defaults_none(tmp_path):
    rc = tmp_path / ".ralphrc"
    rc.write_text('RALPH_TOOLS="Edit Read"\n')
    result = load_ralphrc(rc)
    assert result["min_iter"] is None
