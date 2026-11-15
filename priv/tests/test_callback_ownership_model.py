"""Finite model of two loop resources, two reply IDs and one owner replacement.

Safety: a reply can be taken only by its immutable resource/owner registration.
Driver stop retains ownership. Foreign claims and stale releases cannot alter it.
Progress assumption: a stopped owner may resume; writers eventually return and
running drivers eventually dispatch ready entries. No controller pump is needed.
This enumerates the design, not the C implementation or unbounded liveness.
"""

from collections import deque
from dataclasses import dataclass, replace
from typing import Literal

type ReplyState = Literal["reserved", "ready", "taken", "abandoned"]


@dataclass(frozen=True)
class State:
    owners: tuple[int, int] = (1, 2)
    running: tuple[bool, bool] = (False, True)
    replies: tuple[ReplyState, ReplyState] = ("reserved", "reserved")
    written: frozenset[int] = frozenset()
    queued: frozenset[int] = frozenset()
    delivered: frozenset[int] = frozenset()


def changed[T](pair: tuple[T, T], index: int, value: T) -> tuple[T, T]:
    return (value, pair[1]) if index == 0 else (pair[0], value)


def release(state: State, index: int, claimant: int) -> State:
    if state.owners[index] != claimant or state.running[index]:
        return state
    return replace(
        state,
        owners=changed(state.owners, index, 0),
        replies=changed(state.replies, index, "abandoned"),
    )


def claim(state: State, index: int, claimant: int) -> State:
    if state.owners[index] != 0:
        return state
    return replace(state, owners=changed(state.owners, index, claimant))


def successors(state: State) -> list[State]:
    following: list[State] = []
    for index in range(2):
        registration = index + 1
        owner = state.owners[index]
        if owner != 0:
            following.append(
                replace(
                    state,
                    running=changed(state.running, index, not state.running[index]),
                )
            )
            following.append(release(state, index, owner))
        else:
            following.append(claim(state, index, registration + 2))
        status = state.replies[index]
        if registration not in state.written:
            written = state.written | {registration}
            if status == "reserved":
                following.append(
                    replace(
                        state,
                        written=written,
                        replies=changed(state.replies, index, "ready"),
                        queued=state.queued | {registration},
                    )
                )
            else:
                # Cancellation before a late writer: drop the response, no replay.
                following.append(replace(state, written=written))
        if status in ("reserved", "ready"):
            following.append(
                replace(state, replies=changed(state.replies, index, "abandoned"))
            )
        if registration in state.queued:
            queued = state.queued - {registration}
            if owner == registration and state.running[index] and status == "ready":
                following.append(
                    replace(
                        state,
                        queued=queued,
                        replies=changed(state.replies, index, "taken"),
                        delivered=state.delivered | {registration},
                    )
                )
            elif status == "abandoned":
                following.append(replace(state, queued=queued))
    return following


def test_native_reply_interleavings() -> None:
    initial = State()
    seen = {initial}
    pending = deque([initial])
    witnessed_delivery = False
    witnessed_late_response = False
    while pending:
        state = pending.popleft()
        following_states = successors(state)
        assert len(state.queued) <= 2
        assert sum(status == "reserved" for status in state.replies) <= 2
        assert state.delivered <= state.written
        for index in range(2):
            owner = state.owners[index]
            if owner:
                assert claim(state, index, 99) == state
                assert release(state, index, 99) == state
            if state.running[index]:
                assert owner != 0
                assert release(state, index, owner) == state
            registration = index + 1
            if registration in state.delivered:
                assert state.replies[index] in ("taken", "abandoned")
            if (
                owner == registration
                and state.running[index]
                and state.replies[index] == "ready"
            ):
                # No wait edge to a controller loop or another reply owner.
                assert any(
                    registration in following.delivered
                    for following in following_states
                )
        witnessed_delivery |= state.delivered == {1, 2}
        witnessed_late_response |= any(
            state.owners[index] == index + 3 and index + 1 in state.queued
            for index in range(2)
        )
        for following in following_states:
            if following not in seen:
                seen.add(following)
                pending.append(following)
    assert witnessed_delivery
    assert witnessed_late_response
    assert len(seen) > 100
