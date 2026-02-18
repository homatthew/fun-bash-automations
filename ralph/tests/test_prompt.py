"""Tests for prompt builder and progress parsing."""

from ralph.prompt import build_prompt, parse_progress


def test_build_prompt_warns_against_premature_done(tmp_path):
    plan = tmp_path / "plan.md"
    plan.write_text("# Plan\n1. Do stuff\n")
    prompt = build_prompt(str(plan))
    assert "status.md" in prompt
    assert "all steps" in prompt.lower()
    # The prompt must tell Claude to verify status.md before emitting RALPH_DONE
    assert "RALPH_DONE" in prompt


def test_build_prompt_forbids_push_to_main(tmp_path):
    plan = tmp_path / "plan.md"
    plan.write_text("# Plan\n1. Do stuff\n")
    prompt = build_prompt(str(plan))
    assert "git push" in prompt.lower()
    assert "main" in prompt
    assert "master" in prompt


def test_parse_progress_all_done():
    assert parse_progress("- [x] Step 1\n- [x] Step 2\n- [x] Step 3\n") == (3, 3)


def test_parse_progress_mixed():
    assert parse_progress(
        "- [x] Step 1\n- [x] Step 2\n- [ ] Step 3\n- [ ] Step 4\n"
    ) == (2, 4)


def test_parse_progress_none_done():
    assert parse_progress("- [ ] Step 1\n- [ ] Step 2\n") == (0, 2)


def test_parse_progress_no_checkboxes():
    assert parse_progress("Just some random text\n") == (0, 0)


def test_parse_progress_empty():
    assert parse_progress("") == (0, 0)


def test_parse_progress_with_descriptions():
    text = (
        "- [x] Step 1: Created engine module (DONE)\n"
        "- [x] Step 2: Migrated headless mode (DONE)\n"
        "- [ ] Step 3: Migrating TUI (IN PROGRESS)\n"
        "- [ ] Step 4: Update tests\n"
        "\nCurrent: Step 3\n"
    )
    assert parse_progress(text) == (2, 4)


def test_parse_progress_case_insensitive_done():
    assert parse_progress("- [X] Step 1\n- [x] Step 2\n- [ ] Step 3\n") == (2, 3)
