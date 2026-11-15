from collections import deque
from dataclasses import dataclass, replace
from enum import Enum, auto


class Phase(Enum):
    NEW = auto()
    QUEUED = auto()
    RUNNING = auto()
    ENDED = auto()


@dataclass(frozen=True)
class Work:
    phase: Phase = Phase.NEW
    abandoned: bool = False
    charged: bool = False


@dataclass(frozen=True)
class Gate:
    work: tuple[Work, Work] = (Work(), Work())
    closed: bool = False
    count: int = 0
    size: int = 0


def advance(gate: Gate, index: int, event: str, capacity: int, max_bytes: int) -> Gate:
    work = gate.work[index]
    size = index + 1
    count_delta = 0
    if event == "submit":
        if gate.closed or work.phase is not Phase.NEW:
            return gate
        if gate.count == capacity or size > max_bytes - gate.size:
            return gate
        work = replace(work, phase=Phase.QUEUED, charged=True)
        count_delta = 1
    elif event == "start" and work.phase is Phase.QUEUED:
        work = replace(work, phase=Phase.RUNNING)
    elif (event == "complete" and work.phase is Phase.RUNNING) or (
        event == "start_failure" and work.phase is Phase.QUEUED
    ):
        work = replace(work, phase=Phase.ENDED, charged=False)
        count_delta = -1
    elif event == "abandon":
        work = replace(work, abandoned=True)
    elif event == "close":
        return replace(gate, closed=True)
    elif event == "enqueue_failure":
        return gate
    entries = (work, gate.work[1]) if index == 0 else (gate.work[0], work)
    return replace(
        gate, work=entries, count=gate.count + count_delta, size=gate.size + count_delta * size
    )


def check(capacity: int, max_bytes: int) -> int:
    initial = Gate()
    seen = {initial}
    pending = deque([initial])
    while pending:
        gate = pending.popleft()
        assert gate.count == sum(work.charged for work in gate.work)
        assert gate.size == sum(index + 1 for index, work in enumerate(gate.work) if work.charged)
        assert 0 <= gate.count <= capacity
        assert 0 <= gate.size <= max_bytes
        for work in gate.work:
            assert work.charged == (work.phase in (Phase.QUEUED, Phase.RUNNING))
        for index in range(2):
            for event in (
                "submit",
                "start",
                "complete",
                "start_failure",
                "abandon",
                "close",
                "enqueue_failure",
            ):
                following = advance(gate, index, event, capacity, max_bytes)
                if gate.closed:
                    assert following.closed
                    if event == "submit":
                        assert following == gate
                if event == "abandon":
                    assert following.count == gate.count and following.size == gate.size
                if following not in seen:
                    seen.add(following)
                    pending.append(following)
    assert any(gate.closed and gate.count > 0 for gate in seen)
    assert any(gate.count == 0 and any(w.phase is Phase.ENDED for w in gate.work) for gate in seen)
    return len(seen)


if __name__ == "__main__":
    total = sum(check(capacity, size) for capacity in (1, 2) for size in (1, 2, 3))
    print("Checked {} reachable admission states".format(total))
