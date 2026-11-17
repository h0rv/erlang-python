from dataclasses import dataclass, field
from enum import StrEnum

import erlang


class ChildState(StrEnum):
    RUNNING = "running"
    STOPPED = "stopped"
    RESTARTING = "restarting"


class CapabilityUnavailable(RuntimeError):
    """Requested native admission is not installed; no work was enqueued."""


def _validate_limits(capacity: int | None, max_bytes: int | None, max_children: int | None) -> None:
    if (capacity is None) != (max_bytes is None):
        raise ValueError("capacity and max_bytes must both be finite or both explicitly None")
    for value in (capacity, max_bytes, max_children):
        if value is not None and (type(value) is not int or value <= 0):
            raise ValueError("limits must be positive integers or explicit None")


def _require_available(
    capacity: int | None, max_bytes: int | None, max_children: int | None
) -> None:
    _validate_limits(capacity, max_bytes, max_children)
    if capacity is not None or max_children is not None:
        raise CapabilityUnavailable("native owned-work and atomic child admission is unavailable")


class SupervisorError(RuntimeError):
    def __init__(self, reason: object) -> None:
        super().__init__(reason)
        self.reason = reason


@dataclass(frozen=True, slots=True)
class ChildSnapshot:
    child_id: bytes
    process: object | None
    state: ChildState


def _started(child_id: bytes, process: object) -> ChildSnapshot:
    if process == "undefined" or process is None:
        return ChildSnapshot(child_id, None, ChildState.STOPPED)
    return ChildSnapshot(child_id, process, ChildState.RUNNING)


async def _callback(*args: object) -> object:
    try:
        return await erlang.async_call(
            "_supervision", b"unbounded", b"unbounded", b"unbounded", *args
        )
    except RuntimeError as error:
        raise SupervisorError(error) from error


async def _operation(*args: object) -> object:
    result = await _callback(*args)
    if not isinstance(result, tuple) or len(result) != 2:
        raise SupervisorError(result)
    status, value = result
    if status != "ok":
        raise SupervisorError(value)
    return value


@dataclass(frozen=True, slots=True)
class NativeSupervisor:
    process: object
    capacity: int | None = field(kw_only=True)
    max_bytes: int | None = field(kw_only=True)
    max_children: int | None = field(kw_only=True)

    def __post_init__(self) -> None:
        _validate_limits(self.capacity, self.max_bytes, self.max_children)

    def _check_control(self) -> None:
        _require_available(self.capacity, self.max_bytes, self.max_children)

    async def start_supervisor(
        self,
        child_id: bytes,
        strategy: str,
        intensity: int,
        period: int,
        *,
        capacity: int | None,
        max_bytes: int | None,
        max_children: int | None,
    ) -> "NativeSupervisor":
        self._check_control()
        _require_available(capacity, max_bytes, max_children)
        process = await _operation(
            b"start_supervisor",
            self.process,
            child_id,
            strategy.encode(),
            intensity,
            period,
            b"unbounded",
            b"unbounded",
            b"unbounded",
        )
        return NativeSupervisor(
            process, capacity=capacity, max_bytes=max_bytes, max_children=max_children
        )

    async def start_child(
        self,
        child_id: bytes,
        module: str,
        function: str,
        args: tuple[object, ...],
        restart: str,
        shutdown_ms: int,
        *,
        capacity: int | None,
        max_bytes: int | None,
    ) -> ChildSnapshot:
        self._check_control()
        _require_available(capacity, max_bytes, None)
        process = await _operation(
            b"start",
            self.process,
            child_id,
            module.encode(),
            function.encode(),
            list(args),
            restart.encode(),
            shutdown_ms,
            b"unbounded",
            b"unbounded",
        )
        return _started(child_id, process)

    async def children(self) -> tuple[ChildSnapshot, ...]:
        self._check_control()
        result = await _callback(b"children", self.process)
        if not isinstance(result, list):
            raise SupervisorError(result)
        children: list[ChildSnapshot] = []
        for row in result:
            if not isinstance(row, tuple) or len(row) != 4:
                raise SupervisorError(row)
            child_id, process, state, _kind = row
            if not isinstance(child_id, bytes) or not isinstance(state, str):
                raise SupervisorError(row)
            child_state = ChildState(state)
            children.append(
                ChildSnapshot(
                    child_id, process if child_state is ChildState.RUNNING else None, child_state
                )
            )
        return tuple(children)

    async def stop_child(self, child_id: bytes) -> None:
        self._check_control()
        await _operation(b"stop", self.process, child_id)

    async def restart_child(self, child_id: bytes) -> ChildSnapshot:
        self._check_control()
        process = await _operation(b"restart", self.process, child_id)
        return _started(child_id, process)

    async def delete_child(self, child_id: bytes) -> None:
        self._check_control()
        await _operation(b"delete", self.process, child_id)
