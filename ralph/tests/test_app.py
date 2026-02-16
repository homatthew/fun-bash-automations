from ralph.tui.app import RalphApp


def test_ralph_app_instantiates():
    app = RalphApp()
    assert app is not None
    assert app.title == "Ralph Wiggum"
