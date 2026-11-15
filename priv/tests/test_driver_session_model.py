"""Two driver attempts, one retained wrapper, and finite startup/failure traces.

A driver may acknowledge or finalize only while holding its exact session.
A rejected claimant has no publication or cleanup side effects. A startup
failure rolls back before release. Stop retains the wrapper's resource claim.
"""

from collections import deque
from dataclasses import dataclass, replace
from typing import Literal

type Phase = Literal[
    "ready",
    "claimed",
    "published",
    "running",
    "cleanup",
    "rolled_back",
    "done",
    "rejected",
]


@dataclass(frozen=True)
class State:
    session: int = 0
    phases: tuple[Phase, Phase] = ("ready", "ready")
    acknowledgements: frozenset[int] = frozenset()
    cleanups: frozenset[int] = frozenset()
    wrapper_claimed: bool = True


def phase(state: State, index: int, value: Phase) -> State:
    phases = (value, state.phases[1]) if index == 0 else (state.phases[0], value)
    return replace(state, phases=phases)


def release(state: State, token: int) -> State:
    return replace(state, session=0) if state.session == token else state


def successors(state: State) -> list[State]:
    result: list[State] = []
    for index, current in enumerate(state.phases):
        token = index + 1
        match current:
            case "ready":
                result.append(
                    phase(replace(state, session=token), index, "claimed")
                    if state.session == 0
                    else phase(state, index, "rejected")
                )
            case "claimed":
                result.extend(
                    (
                        phase(state, index, "published"),
                        phase(state, index, "rolled_back"),
                    )
                )
            case "published":
                result.append(
                    phase(
                        replace(
                            state, acknowledgements=state.acknowledgements | {token}
                        ),
                        index,
                        "running",
                    )
                )
                result.append(phase(state, index, "rolled_back"))
            case "running":
                result.append(
                    phase(
                        replace(state, cleanups=state.cleanups | {token}),
                        index,
                        "cleanup",
                    )
                )
            case "cleanup" | "rolled_back":
                result.append(phase(release(state, token), index, "done"))
            case "done" | "rejected":
                pass
    return result


def test_exclusive_driver_session_interleavings() -> None:
    pending = deque([State()])
    seen = {State()}
    witnessed_rejection = False
    witnessed_rollback_then_other_start = False
    while pending:
        state = pending.popleft()
        assert state.wrapper_claimed
        active = [
            index + 1
            for index, item in enumerate(state.phases)
            if item in ("claimed", "published", "running", "cleanup", "rolled_back")
        ]
        assert active == ([] if state.session == 0 else [state.session])
        assert state.cleanups <= state.acknowledgements
        for index, item in enumerate(state.phases):
            token = index + 1
            if item == "rejected":
                witnessed_rejection = True
                assert token not in state.acknowledgements | state.cleanups
            if state.session != token:
                assert release(state, token) == state
        witnessed_rollback_then_other_start |= any(
            state.phases[index] == "done"
            and index + 1 not in state.acknowledgements
            and state.phases[1 - index] == "running"
            for index in range(2)
        )
        for following in successors(state):
            if following not in seen:
                seen.add(following)
                pending.append(following)
    assert witnessed_rejection
    assert witnessed_rollback_then_other_start
    assert len(seen) > 50
