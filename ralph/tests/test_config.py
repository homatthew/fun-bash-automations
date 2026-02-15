from ralph.config import RALPH_DEFAULT_TOOLS, load_ralphrc


def test_default_tools_contains_core_entries():
    assert "Edit" in RALPH_DEFAULT_TOOLS
    assert "Bash(git add:*)" in RALPH_DEFAULT_TOOLS


def test_load_ralphrc_returns_defaults_when_no_file(tmp_path):
    result = load_ralphrc(tmp_path / ".ralphrc")
    assert result == {"tools": None, "max_iter": None}


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
