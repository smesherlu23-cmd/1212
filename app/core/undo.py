from __future__ import annotations

from typing import Callable


class UndoStack:
    """LIFO stack of reversible actions.

    Every undoable UI action pushes the closure that reverses it; the
    toast's single "Вернуть"/"Отменить" button always calls undo(), which
    pops and runs whatever is on top. Neither the button nor the stack
    needs to know which action it belongs to, which is what replaces having
    one bespoke ``_restore_x``/``undo_x`` method per action scattered across
    the UI and controllers.
    """

    def __init__(self, limit: int = 20):
        self._limit = limit
        self._stack: list[Callable[[], None]] = []

    def push(self, undo_fn: Callable[[], None]) -> None:
        self._stack.append(undo_fn)
        del self._stack[:-self._limit]

    def undo(self) -> bool:
        if not self._stack:
            return False
        undo_fn = self._stack.pop()
        undo_fn()
        return True

    def clear(self) -> None:
        self._stack.clear()

    def __len__(self) -> int:
        return len(self._stack)
