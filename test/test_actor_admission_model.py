from collections import deque
from dataclasses import dataclass, replace
from enum import Enum, auto


class Phase(Enum):
    NEW = auto()
    RESERVED = auto()
    ENQUEUED = auto()
    RUNNING = auto()
    ABORTED = auto()
    COMPLETE = auto()
    UNCERTAIN = auto()


@dataclass(frozen=True, slots=True)
class Ticket:
    phase: Phase = Phase.NEW
    charged: bool = False
    executed: bool = False


@dataclass(frozen=True, slots=True)
class State:
    tickets: tuple[Ticket, Ticket] = (Ticket(), Ticket())
    closed: bool = False


SIZES = (1, 2)
CAPACITY = 2
MAX_BYTES = 2


def invariant(state: State) -> bool:
    count = sum(ticket.charged for ticket in state.tickets)
    size = sum(
        size
        for ticket, size in zip(state.tickets, SIZES, strict=True)
        if ticket.charged
    )
    return (
        count <= CAPACITY
        and size <= MAX_BYTES
        and sum(ticket.phase is Phase.RUNNING for ticket in state.tickets) <= 1
        and all(
            (
                ticket.charged
                == (
                    ticket.phase
                    in (Phase.RESERVED, Phase.ENQUEUED, Phase.RUNNING, Phase.UNCERTAIN)
                )
            )
            and (ticket.phase is not Phase.ABORTED or not ticket.executed)
            for ticket in state.tickets
        )
    )


def successors(state: State, *, buggy_cancel: bool = False) -> set[State]:
    result = {state, replace(state, closed=True)}
    count = sum(ticket.charged for ticket in state.tickets)
    size = sum(
        size
        for ticket, size in zip(state.tickets, SIZES, strict=True)
        if ticket.charged
    )
    busy = any(ticket.phase is Phase.RUNNING for ticket in state.tickets)
    for index, ticket in enumerate(state.tickets):
        next_tickets: set[Ticket] = {ticket}
        match ticket.phase:
            case Phase.NEW:
                if (
                    not state.closed
                    and count < CAPACITY
                    and size + SIZES[index] <= MAX_BYTES
                ):
                    next_tickets.add(Ticket(Phase.RESERVED, True))
            case Phase.RESERVED:
                next_tickets.add(Ticket(Phase.ABORTED))
                if not state.closed:
                    next_tickets.add(Ticket(Phase.ENQUEUED, True))
            case Phase.ENQUEUED:
                # Overflow or proven send failure: no future dispatch exists.
                next_tickets.add(Ticket(Phase.ABORTED))
                if not state.closed and not busy:
                    next_tickets.add(Ticket(Phase.RUNNING, True, True))
                if buggy_cancel:
                    next_tickets.add(replace(ticket, charged=False))
            case Phase.RUNNING:
                next_tickets.add(Ticket(Phase.COMPLETE, False, True))
            case Phase.ABORTED | Phase.COMPLETE | Phase.UNCERTAIN:
                pass
        for updated in next_tickets:
            pair = (
                (updated, state.tickets[1])
                if index == 0
                else (state.tickets[0], updated)
            )
            result.add(State(pair, state.closed))
        if ticket.phase in (Phase.ENQUEUED, Phase.RUNNING):
            # Lost completion closes admission and keeps the charged credit.
            unknown = replace(ticket, phase=Phase.UNCERTAIN)
            pair = (
                (unknown, state.tickets[1])
                if index == 0
                else (state.tickets[0], unknown)
            )
            result.add(State(pair, True))
    return result


def explore(*, buggy_cancel: bool = False) -> tuple[set[State], bool]:
    seen = {State()}
    pending = deque(seen)
    while pending:
        state = pending.popleft()
        if not invariant(state):
            return seen, False
        for candidate in successors(state, buggy_cancel=buggy_cancel):
            if candidate not in seen:
                seen.add(candidate)
                pending.append(candidate)
    return seen, True


def test_admission_state_graph() -> None:
    states, safe = explore()
    assert safe
    assert any(
        any(ticket.phase is Phase.COMPLETE for ticket in state.tickets)
        for state in states
    )
    assert any(
        any(ticket.phase is Phase.UNCERTAIN for ticket in state.tickets)
        for state in states
    )
    assert not explore(buggy_cancel=True)[1]
    print(
        "Admission state graph checked:",
        len(states),
        "states; negative control rejected",
    )


@dataclass(frozen=True, slots=True)
class GenerationState:
    actor_dead: bool = False
    context_dead: bool = False
    old_running: bool = True
    restarted: bool = False


def generation_graph(*, buggy_restart: bool = False) -> bool:
    initial = GenerationState()
    seen = {initial}
    pending = deque(seen)
    while pending:
        state = pending.popleft()
        if state.restarted and state.old_running:
            return False
        choices = {
            state,
            replace(state, actor_dead=True),
            replace(state, context_dead=True, actor_dead=True),
            replace(state, old_running=False),
        }
        if (
            state.actor_dead
            and state.context_dead
            and (buggy_restart or not state.old_running)
        ):
            choices.add(replace(state, restarted=True))
        for candidate in choices - seen:
            seen.add(candidate)
            pending.append(candidate)
    assert any(state.restarted for state in seen)
    return True


def test_generation_state_graph() -> None:
    assert generation_graph()
    assert not generation_graph(buggy_restart=True)
    print("Generation state graph checked; context-DOWN-only restart rejected")


if __name__ == "__main__":
    test_admission_state_graph()
    test_generation_state_graph()
