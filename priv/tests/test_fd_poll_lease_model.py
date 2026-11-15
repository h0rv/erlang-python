from collections import deque
from dataclasses import dataclass, replace
from typing import Literal


type Phase = Literal[
    "open", "issuing", "scheduled", "failed", "allocation_failed", "closed"
]


@dataclass(frozen=True)
class Lease:
    generation: int
    poll_fd: int
    phase: Phase = "open"
    callbacks: int = 0
    closes: int = 0


@dataclass(frozen=True)
class State:
    leases: tuple[Lease, ...] = (Lease(0, 1),)
    mapping: int | None = 0
    owner_open: bool = True
    events: frozenset[int] = frozenset()
    uncertain: bool = False
    unsafe_close: bool = False
    lost_retry: bool = False
    wrong_callback: bool = False


def successors(
    state: State, *, isolated: bool, retain_failure: bool
) -> tuple[State, ...]:
    result: list[State] = []

    def changed(lease: Lease) -> State:
        leases = tuple(
            lease if old.generation == lease.generation else old for old in state.leases
        )
        return replace(state, leases=leases)

    for lease in state.leases:
        generation = lease.generation
        if lease.phase == "open" and state.mapping == generation:
            result.append(replace(state, events=state.events | {generation}))
            result.append(changed(replace(lease, phase="issuing")))
            failed = changed(replace(lease, phase="allocation_failed"))
            result.append(
                replace(
                    failed,
                    uncertain=True,
                    lost_retry=not retain_failure,
                    mapping=generation if retain_failure else None,
                    owner_open=state.owner_open if retain_failure else False,
                )
            )
        if lease.phase == "issuing":
            for phase in ("scheduled", "closed"):
                completed = phase == "closed"
                updated = changed(
                    replace(
                        lease,
                        phase=phase,
                        callbacks=int(completed),
                        closes=int(completed and isolated),
                    )
                )
                result.append(replace(updated, mapping=None, uncertain=False))
            failed = changed(replace(lease, phase="failed"))
            result.append(
                replace(
                    failed,
                    uncertain=True,
                    lost_retry=not retain_failure,
                    mapping=generation if retain_failure else None,
                    owner_open=state.owner_open if retain_failure else False,
                )
            )
            # Concurrent unsubmitted STOP is an error, not an acknowledgement.
            result.append(
                replace(
                    state,
                    uncertain=True,
                    lost_retry=not retain_failure,
                    mapping=generation if retain_failure else None,
                    owner_open=state.owner_open if retain_failure else False,
                )
            )
        if (
            lease.phase in ("failed", "allocation_failed")
            and state.mapping == generation
        ):
            result.append(
                replace(changed(replace(lease, phase="issuing")), uncertain=False)
            )
        if lease.phase == "scheduled":
            result.append(
                changed(
                    replace(lease, phase="closed", callbacks=1, closes=int(isolated))
                )
            )

    # Named caller assumption: every direction is unregistered before the
    # borrowed owner closes. Neither close nor registration waits for STOP.
    if state.mapping is None and state.owner_open:
        pending = any(lease.phase != "closed" for lease in state.leases)
        result.append(
            replace(
                state,
                owner_open=False,
                unsafe_close=state.unsafe_close or (pending and not isolated),
            )
        )
    if state.mapping is None and len(state.leases) < 2:
        generation = len(state.leases)
        occupied = {lease.poll_fd for lease in state.leases if lease.phase != "closed"}
        poll_fd = next(fd for fd in (1, 2) if fd not in occupied) if isolated else 0
        result.append(
            replace(
                state,
                leases=(*state.leases, Lease(generation, poll_fd)),
                mapping=generation,
                owner_open=True,
                uncertain=False,
            )
        )
    for event in state.events:
        # A native event and an already-queued Python FD handle both recheck
        # identity. The old wrapper-local ID can alias a replacement wrapper.
        routes = state.mapping is not None and not state.uncertain
        same_id = state.mapping == event if isolated else True
        wrong = routes and same_id and state.mapping != event
        result.append(
            replace(
                state,
                events=state.events - {event},
                wrong_callback=state.wrong_callback or wrong,
            )
        )
    return tuple(result)


def explore(*, isolated: bool, retain_failure: bool) -> set[State]:
    initial = State(leases=(Lease(0, 1 if isolated else 0),))
    pending = deque([(initial, 0)])
    seen = {initial}
    while pending:
        state, depth = pending.popleft()
        if depth == 16:
            continue
        for successor in successors(
            state, isolated=isolated, retain_failure=retain_failure
        ):
            if successor not in seen:
                seen.add(successor)
                pending.append((successor, depth + 1))
    return seen


def test_original_borrowed_selection_has_close_and_stale_event_counterexamples() -> (
    None
):
    states = explore(isolated=False, retain_failure=True)
    assert any(state.unsafe_close for state in states)
    assert any(state.wrong_callback for state in states)


def test_lease_alone_does_not_fix_discarded_retry_ownership() -> None:
    states = explore(isolated=True, retain_failure=False)
    assert any(state.lost_retry for state in states)


def test_two_generations_two_leases_sixteen_transitions_preserve_ownership() -> None:
    states = explore(isolated=True, retain_failure=True)
    assert any(
        len(state.leases) == 2 and state.leases[0].phase == "scheduled"
        for state in states
    )
    assert any(
        not state.owner_open and state.leases[0].phase == "scheduled"
        for state in states
    )
    assert any(state.uncertain for state in states)
    assert any(
        all(lease.phase == "closed" for lease in state.leases) for state in states
    )
    for state in states:
        assert (
            not state.unsafe_close and not state.lost_retry and not state.wrong_callback
        )
        assert len(state.leases) <= 2
        live = [lease.poll_fd for lease in state.leases if lease.phase != "closed"]
        assert len(live) == len(set(live))
        for lease in state.leases:
            assert lease.poll_fd != 0
            assert lease.closes == lease.callbacks <= 1
            assert lease.closes == int(lease.phase == "closed")
        if state.uncertain:
            assert state.mapping is not None and state.owner_open
    print("borrowed-model states", len(states), "depth", 16, "leases", 2)
