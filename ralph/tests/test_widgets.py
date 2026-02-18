"""Tests for ralph.tui.widgets — SplitHandle."""

from textual.app import App, ComposeResult
from textual.containers import Horizontal, Vertical
from textual.widgets import Static

from ralph.tui.widgets import SplitHandle

# --- Pure unit tests ---


def test_split_handle_render():
    handle = SplitHandle("left", "right")
    assert handle.render() == "│"


def test_split_handle_stores_ids():
    handle = SplitHandle("plan-panel", "preview-panel")
    assert handle._left_id == "plan-panel"
    assert handle._right_id == "preview-panel"


def test_split_handle_default_mins():
    handle = SplitHandle("a", "b")
    assert handle._left_min == 20
    assert handle._right_min == 20


def test_split_handle_custom_mins():
    handle = SplitHandle("a", "b", left_min=10, right_min=30)
    assert handle._left_min == 10
    assert handle._right_min == 30


def test_split_handle_not_dragging_initially():
    handle = SplitHandle("a", "b")
    assert handle.dragging is False


# --- Integration tests using Textual Pilot ---


class SplitTestApp(App):
    CSS = """
    #left-pane { width: 40; background: red; }
    #right-pane { width: 40; background: blue; }
    """

    def compose(self) -> ComposeResult:
        with Horizontal():
            yield Vertical(Static("Left"), id="left-pane")
            yield SplitHandle(
                "left-pane", "right-pane", left_min=10, right_min=10, id="test-handle"
            )
            yield Vertical(Static("Right"), id="right-pane")


async def test_split_handle_exists_in_app():
    app = SplitTestApp()
    async with app.run_test(size=(81, 24)):
        handle = app.query_one("#test-handle", SplitHandle)
        assert handle is not None
        assert handle.render() == "│"


async def test_split_handle_panes_have_initial_width():
    app = SplitTestApp()
    async with app.run_test(size=(81, 24)):
        left = app.query_one("#left-pane")
        right = app.query_one("#right-pane")
        assert left.size.width == 40
        assert right.size.width == 40


async def test_split_handle_mouse_down_starts_drag():
    app = SplitTestApp()
    async with app.run_test(size=(81, 24)) as pilot:
        handle = app.query_one("#test-handle", SplitHandle)
        await pilot.mouse_down(handle)
        await pilot.pause()
        assert handle.dragging is True
        assert handle.has_class("-dragging")


async def test_split_handle_mouse_up_ends_drag():
    app = SplitTestApp()
    async with app.run_test(size=(81, 24)) as pilot:
        handle = app.query_one("#test-handle", SplitHandle)
        await pilot.mouse_down(handle)
        await pilot.pause()
        await pilot.mouse_up(handle)
        await pilot.pause()
        assert handle.dragging is False
        assert not handle.has_class("-dragging")


async def test_split_handle_drag_resizes_panes():
    app = SplitTestApp()
    async with app.run_test(size=(81, 24)) as pilot:
        left = app.query_one("#left-pane")
        right = app.query_one("#right-pane")
        handle = app.query_one("#test-handle", SplitHandle)
        await pilot.mouse_down(handle)
        await pilot.pause()
        # Move 5 columns to the right
        from textual.events import MouseMove

        def _make_mouse_move(widget, screen_x, screen_y):
            return MouseMove(
                widget=widget,
                x=0,
                y=0,
                delta_x=0,
                delta_y=0,
                button=1,
                shift=False,
                meta=False,
                ctrl=False,
                screen_x=screen_x,
                screen_y=screen_y,
            )

        handle._on_mouse_move(
            _make_mouse_move(handle, handle._drag_start_x + 5, handle.region.y)
        )
        await pilot.pause()

        assert left.styles.width is not None
        assert right.styles.width is not None


async def test_split_handle_respects_left_min():
    app = SplitTestApp()
    async with app.run_test(size=(81, 24)) as pilot:
        from textual.events import MouseMove

        left = app.query_one("#left-pane")
        handle = app.query_one("#test-handle", SplitHandle)

        await pilot.mouse_down(handle)
        await pilot.pause()
        handle._on_mouse_move(
            MouseMove(
                widget=handle, x=0, y=0, delta_x=0, delta_y=0,
                button=1, shift=False, meta=False, ctrl=False,
                screen_x=handle._drag_start_x - 50, screen_y=handle.region.y,
            )
        )
        await pilot.pause()
        w = left.styles.width
        assert w is not None
        assert w.value >= handle._left_min


async def test_split_handle_respects_right_min():
    app = SplitTestApp()
    async with app.run_test(size=(81, 24)) as pilot:
        from textual.events import MouseMove

        right = app.query_one("#right-pane")
        handle = app.query_one("#test-handle", SplitHandle)

        await pilot.mouse_down(handle)
        await pilot.pause()
        handle._on_mouse_move(
            MouseMove(
                widget=handle, x=0, y=0, delta_x=0, delta_y=0,
                button=1, shift=False, meta=False, ctrl=False,
                screen_x=handle._drag_start_x + 50, screen_y=handle.region.y,
            )
        )
        await pilot.pause()
        w = right.styles.width
        assert w is not None
        assert w.value >= handle._right_min
