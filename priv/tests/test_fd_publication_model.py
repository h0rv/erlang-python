from collections import deque
from dataclasses import dataclass, replace
from typing import Literal


type Phase = Literal[
    "before_native",
    "native_unpublished",
    "key_published",
    "callback_published",
    "published",
    "publication_failed",
    "rollback_failed",
    "restored",
    "closed",
]


@dataclass(frozen=True)
class Publication:
    reading: bool
    shared: bool
    phase: Phase = "before_native"
    slot_owned: bool = False
    stack_key: bool = False
    # Registry-owned lease requiring a caller key. Accepted pending STOP
    # transfers its remaining lifetime to ERTS, as checked by the lease model.
    native_live: bool = False
    mapped: bool = False
    callback_record: bool = False
    native_updated: bool = False
    other_watcher: bool = False
    close_requested: bool = False
    socket_open: bool = True
    bad_callback: bool = False
    uncertain: bool = False


def transitions(state: Publication, *, fixed: bool) -> tuple[Publication, ...]:
    result: list[Publication] = []
    match state.phase:
        case "before_native":
            # Fixed code owns the slot before CALL and stores the returned key
            # directly in its existing slot. Native e133 allocates its key and
            # every fallible constructor result before establishing selection.
            result.append(
                replace(
                    state,
                    phase="native_unpublished",
                    native_live=True,
                    stack_key=True,
                    native_updated=state.shared and not fixed,
                )
            )
        case "native_unpublished":
            result.append(replace(state, phase="key_published", mapped=True))
            result.append(replace(state, phase="publication_failed", stack_key=False))
        case "key_published":
            result.append(
                replace(state, phase="callback_published", callback_record=True)
            )
            result.append(replace(state, phase="publication_failed", stack_key=False))
        case "callback_published":
            result.append(
                replace(
                    state,
                    phase="published",
                    slot_owned=False,
                    stack_key=False,
                    native_updated=state.shared,
                )
            )
            result.append(replace(state, phase="publication_failed", stack_key=False))
            if state.shared and fixed:
                # Native update may partially take effect after all Python
                # allocations; uncertainty retains the shared slot, not STOP.
                result.append(
                    replace(
                        state,
                        phase="rollback_failed",
                        stack_key=False,
                        native_updated=True,
                    )
                )
        case "publication_failed":
            if state.shared and fixed:
                result.append(
                    replace(
                        state, phase="restored", slot_owned=False, callback_record=False
                    )
                )
                # A synthetic write-then-raise mapping can also reject restore.
                result.append(replace(state, phase="rollback_failed"))
            elif state.slot_owned:
                result.append(
                    replace(
                        state,
                        phase="closed",
                        slot_owned=False,
                        native_live=False,
                        mapped=False,
                        callback_record=False,
                    )
                )
                result.append(replace(state, phase="rollback_failed"))
        case "rollback_failed":
            pass
        case "published" | "restored" | "closed":
            pass

    if state.phase != "closed":
        discoverable = state.slot_owned or state.mapped
        result.append(
            replace(
                state,
                phase="closed"
                if discoverable or not state.native_live
                else state.phase,
                close_requested=True,
                native_live=state.native_live and not discoverable,
                mapped=False,
                slot_owned=False,
                stack_key=False,
                callback_record=False,
                other_watcher=False,
                socket_open=False,
            )
        )
        if discoverable and state.native_live:
            result.append(
                replace(
                    state,
                    phase="rollback_failed",
                    close_requested=True,
                    stack_key=False,
                    uncertain=True,
                )
            )
    # Already-queued readiness cannot execute during a pending publication or
    # failed rollback. Unique FD callback identity is checked by the old model.
    if state.callback_record and (
        not fixed or (not state.slot_owned and not state.uncertain)
    ):
        result.append(
            replace(
                state,
                bad_callback=state.bad_callback
                or state.phase != "published"
                or not state.native_live,
            )
        )
    return tuple(result)


def explore(*, fixed: bool, reading: bool, shared: bool) -> set[Publication]:
    initial = Publication(
        reading=reading,
        shared=shared,
        slot_owned=fixed,
        native_live=shared,
        mapped=shared,
        other_watcher=shared,
    )
    pending = deque([(initial, 0)])
    seen = {initial}
    while pending:
        state, depth = pending.popleft()
        if depth == 12:
            continue
        for successor in transitions(state, fixed=fixed):
            if successor not in seen:
                seen.add(successor)
                pending.append((successor, depth + 1))
    return seen


def test_old_reader_and_writer_can_leave_selected_unpublished_orphans() -> None:
    for reading in (True, False):
        states = explore(fixed=False, reading=reading, shared=False)
        assert any(
            state.native_live
            and not state.mapped
            and not state.slot_owned
            and not state.stack_key
            for state in states
        )


def test_fixed_publication_and_failed_rollback_keep_every_selected_key_owned() -> None:
    checked = 0
    for reading in (True, False):
        for shared in (True, False):
            states = explore(fixed=True, reading=reading, shared=shared)
            checked += len(states)
            assert any(state.phase == "published" for state in states)
            assert any(state.phase == "rollback_failed" for state in states)
            assert any(
                state.phase == "closed" and not state.native_live for state in states
            )
            for state in states:
                assert not state.native_live or state.slot_owned or state.mapped
                assert not state.bad_callback
                if state.native_live and state.close_requested:
                    assert state.slot_owned or state.mapped
                    assert state.socket_open
                if state.phase == "restored":
                    assert state.shared and state.other_watcher and state.native_live
                    assert not state.native_updated
                if state.shared and not state.close_requested:
                    assert state.other_watcher and state.native_live
    print(
        "publication-model states",
        checked,
        "depth",
        12,
        "directions",
        2,
        "shared-owner",
        1,
        "native-leases",
        1,
    )
