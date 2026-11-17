import erlang


class FactoryActor:
    async def dispatch(self, payload: bytes) -> bytes:
        return payload


def factory() -> FactoryActor:
    erlang.call("review_factory_wait")
    return FactoryActor()
