from collections.abc import Callable
from enum import StrEnum
from typing import NamedTuple


class FdCallback(NamedTuple):
    callback: Callable[..., object]
    args: tuple[object, ...]
    key: int


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
