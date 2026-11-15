import asyncio
from dataclasses import dataclass, field


@dataclass
class Inspection:
    loops: dict[str, asyncio.AbstractEventLoop] = field(default_factory=dict)


inspection = Inspection()


async def remember(name: str) -> int:
    loop = asyncio.get_running_loop()
    inspection.loops[name] = loop
    return id(loop)


async def different(name: str) -> bool:
    return asyncio.get_running_loop() is not inspection.loops[name]


async def echo(reference: object) -> object:
    return reference


def closed(name: str) -> bool:
    return inspection.loops[name].is_closed()
