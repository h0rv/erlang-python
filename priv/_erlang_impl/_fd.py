import socket
from collections.abc import Callable
from dataclasses import dataclass
from enum import StrEnum
from typing import NamedTuple


class FdCallback(NamedTuple):
    callback: Callable[..., object]
    args: tuple[object, ...]
    key: int
    fd: int


type FdWatcher = tuple[Callable[..., object], tuple[object, ...], int]


class FdPublicationPhase(StrEnum):
    PREPARED = "prepared"
    NATIVE_OWNED = "native_owned"
    UPDATING = "updating"
    PUBLICATION_FAILED = "publication_failed"
    UPDATE_FAILED = "update_failed"
    ROLLBACK_FAILED = "rollback_failed"
    RETIRED = "retired"


@dataclass(slots=True)
class FdPublication:
    fd: int
    reading: bool
    entry: FdWatcher
    old_entry: FdWatcher | None
    shared: bool
    key: int = 0  # Native registry reserves zero; PREPARED has no new lease.
    phase: FdPublicationPhase = FdPublicationPhase.PREPARED
    closing_socket: socket.socket | None = None


class FdRetirement(StrEnum):
    POLL_CLOSED = "poll_closed"
    POLL_PENDING = "poll_pending"
    ABSENT = "absent"


class FdRetirementError(RuntimeError):
    def __init__(self, key: int) -> None:
        self.key = key
        super().__init__("FD retirement failed; ownership and retry key retained", key)


def parse_fd_retirement(value: object) -> FdRetirement:
    match value:
        case "poll_closed":
            return FdRetirement.POLL_CLOSED
        case "poll_pending":
            return FdRetirement.POLL_PENDING
        case "absent":
            return FdRetirement.ABSENT
        case _:
            raise ValueError("Invalid native FD retirement outcome")
