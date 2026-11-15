from collections import deque
from dataclasses import dataclass, replace
from typing import Literal, assert_never


type Phase = Literal["open", "issuing", "scheduled", "failed", "closed"]


@dataclass(frozen=True)
class State:
    selected: bool
    phase: Phase = "open"
    active: bool = True
    callbacks: int = 0
    closes: int = 0
    replacement: bool = False
    stop_returned: bool = False


def transitions(state: State) -> tuple[State, ...]:
    match state.phase:
        case "open":
            close = replace(state, phase="issuing", active=False) if state.selected else replace(
                state, phase="closed", active=False, closes=1
            )
            return (replace(state, active=not state.active), close)
        case "issuing":
            # Direct callback before STOP returns, scheduled callback after
            # return, and a failed submission without any safe-close permission.
            return (
                replace(state, phase="closed", callbacks=1, closes=1),
                replace(state, phase="scheduled", stop_returned=True),
                replace(state, phase="failed", stop_returned=True),
            )
        case "scheduled":
            return (replace(state, phase="closed", callbacks=1, closes=1),)
        case "failed":
            return (replace(state, phase="issuing", stop_returned=False),)
        case "closed":
            return (
                replace(state, replacement=True),
                replace(state, stop_returned=True),
            )
        case _:
            assert_never(state.phase)


def test_close_needs_stop_completion_not_cancel_or_delivery() -> None:
    for selected in (False, True):
        initial = State(selected=selected)
        pending = deque([initial])
        seen = {initial}
        while pending:
            state = pending.popleft()
            assert state.closes <= 1
            assert state.callbacks <= 1
            assert state.closes == int(state.phase == "closed")
            assert not state.replacement or state.phase == "closed"
            if selected:
                assert state.closes == state.callbacks
            else:
                assert state.callbacks == 0
            if state.phase != "open":
                assert not state.active
                # Re-arm is rejected; repeated/concurrent close cannot touch
                # a descriptor which the OS has assigned to a replacement.
                assert replace(state, active=False) == state
            if state.phase == "failed":
                assert state.closes == 0 and state.callbacks == 0
            for next_state in transitions(state):
                if next_state not in seen:
                    seen.add(next_state)
                    pending.append(next_state)
        assert any(state.replacement for state in seen)
        if selected:
            assert any(state.phase == "failed" for state in seen)
            assert any(state.phase == "scheduled" for state in seen)
            assert any(state.closes == 1 and not state.stop_returned for state in seen)
