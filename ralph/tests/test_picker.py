import time

from ralph.tui.picker import relative_time


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
