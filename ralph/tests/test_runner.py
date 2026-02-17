from ralph.tui.runner import format_elapsed


def test_format_elapsed_seconds():
    assert format_elapsed(45) == "0m 45s"


def test_format_elapsed_minutes():
    assert format_elapsed(125) == "2m 05s"


def test_format_elapsed_hours():
    assert format_elapsed(3661) == "1h 01m 01s"
