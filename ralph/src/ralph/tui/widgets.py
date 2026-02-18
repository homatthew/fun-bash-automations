"""Reusable TUI widgets for Ralph."""

from __future__ import annotations

from textual.events import MouseDown, MouseMove, MouseUp
from textual.widget import Widget


class SplitHandle(Widget):
    """Draggable 1-column vertical handle between two sibling panes."""

    DEFAULT_CSS = """
    SplitHandle {
        width: 1;
        height: 1fr;
        background: #263140;
    }
    SplitHandle:hover {
        background: #3a4a5c;
    }
    SplitHandle.-dragging {
        background: #9fe8d2;
    }
    """

    def __init__(
        self,
        left_id: str,
        right_id: str,
        *,
        left_min: int = 20,
        right_min: int = 20,
        id: str | None = None,
    ) -> None:
        super().__init__(id=id)
        self._left_id = left_id
        self._right_id = right_id
        self._left_min = left_min
        self._right_min = right_min
        self.dragging = False
        self._drag_start_x = 0
        self._start_left_w = 0
        self._start_right_w = 0

    def render(self) -> str:
        return "│"

    def _on_mouse_down(self, event: MouseDown) -> None:
        self.capture_mouse()
        self.dragging = True
        self.add_class("-dragging")
        self._drag_start_x = event.screen_x
        left = self.screen.query_one(f"#{self._left_id}")
        right = self.screen.query_one(f"#{self._right_id}")
        self._start_left_w = left.size.width
        self._start_right_w = right.size.width
        event.stop()

    def _on_mouse_move(self, event: MouseMove) -> None:
        if not self.dragging:
            return
        delta = event.screen_x - self._drag_start_x
        new_left = self._start_left_w + delta
        new_right = self._start_right_w - delta
        if new_left < self._left_min:
            new_left = self._left_min
            new_right = self._start_left_w + self._start_right_w - new_left
        if new_right < self._right_min:
            new_right = self._right_min
            new_left = self._start_left_w + self._start_right_w - new_right
        left = self.screen.query_one(f"#{self._left_id}")
        right = self.screen.query_one(f"#{self._right_id}")
        left.styles.width = new_left
        right.styles.width = new_right
        event.stop()

    def _on_mouse_up(self, event: MouseUp) -> None:
        if self.dragging:
            self.dragging = False
            self.remove_class("-dragging")
            self.release_mouse()
            event.stop()
