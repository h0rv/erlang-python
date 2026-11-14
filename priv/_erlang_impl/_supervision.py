from dataclasses import dataclass
from enum import StrEnum

import erlang


class ChildState(StrEnum):
    RUNNING = "running"
    STOPPED = "stopped"
    RESTARTING = "restarting"


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
        return await erlang.async_call("_supervision", *args)
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

    async def start_supervisor(
        self, child_id: bytes, strategy: str, intensity: int, period: int
    ) -> NativeSupervisor:
        process = await _operation(
            b"start_supervisor", self.process, child_id, strategy.encode(), intensity, period
        )
        return NativeSupervisor(process)

    async def start_child(
        self,
        child_id: bytes,
        module: str,
        function: str,
        args: tuple[object, ...],
        restart: str,
        shutdown_ms: int,
    ) -> ChildSnapshot:
        process = await _operation(
            b"start",
            self.process,
            child_id,
            module.encode(),
            function.encode(),
            list(args),
            restart.encode(),
            shutdown_ms,
        )
        return _started(child_id, process)

    async def children(self) -> tuple[ChildSnapshot, ...]:
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
        await _operation(b"stop", self.process, child_id)

    async def restart_child(self, child_id: bytes) -> ChildSnapshot:
        process = await _operation(b"restart", self.process, child_id)
        return _started(child_id, process)

    async def delete_child(self, child_id: bytes) -> None:
        await _operation(b"delete", self.process, child_id)
