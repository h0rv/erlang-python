import erlang

_held: object = None


def remember(pid: object) -> None:
    global _held
    _held = pid


def recall(pid: erlang.Pid, other: object) -> object:
    if not isinstance(_held, erlang.Pid):
        raise TypeError("Expected a retained erlang.Pid")
    if _held != pid or _held == other or hash(_held) != hash(pid):
        raise ValueError("PID identity changed")
    if {_held: 42}[pid] != 42 or len({_held, pid}) != 1:
        raise ValueError("PID hashing changed")
    if not repr(_held).startswith("<erlang.Pid "):
        raise ValueError("Invalid PID repr")
    return _held


def send_retained(message: object) -> None:
    erlang.send(_held, message)


def send_named(name: str, node: str, message: object) -> None:
    erlang.send((erlang.atom(name), erlang.atom(node)), message)


def invalid_destinations() -> bool:
    for destination in [None, 42, (), ("name", "node"), (erlang.atom("name"), 1)]:
        try:
            erlang.send(destination, "invalid")
        except TypeError:
            continue
        return False
    return True
