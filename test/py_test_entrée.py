from erlang.tasks import entrypoint


@entrypoint
async def résumé(payload: bytes) -> bytes:
    return payload
