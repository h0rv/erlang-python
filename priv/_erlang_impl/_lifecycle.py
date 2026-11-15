import asyncio


async def _cancel_tasks(loop: asyncio.AbstractEventLoop) -> list[BaseException]:
    current = asyncio.current_task(loop)
    cancelled: set[asyncio.Task[object]] = set()
    errors: list[BaseException] = []
    while True:
        pending = {task for task in asyncio.all_tasks(loop) if task is not current}
        if not pending:
            # Cancellation callbacks can start successor tasks on the next turn.
            await asyncio.sleep(0)
            if not any(task is not current for task in asyncio.all_tasks(loop)):
                return errors
            continue
        for task in pending - cancelled:
            graph = asyncio.capture_call_graph(task, limit=0)
            if graph is None:
                raise RuntimeError("Cannot inspect a managed shutdown task")
            if any(parent.future in pending for parent in graph.awaited_by):
                continue
            # Cancelling a TaskGroup parent also cancels its children. Repeated
            # cancellation would interrupt their awaited resource finalizers.
            if not task.cancelling():
                task.cancel()
            cancelled.add(task)
        done, _ = await asyncio.wait(pending, return_when=asyncio.FIRST_COMPLETED)
        for task in done:
            if not task.cancelled():
                error = task.exception()
                if error is not None:
                    errors.append(error)


async def shutdown_managed_loop(loop: asyncio.AbstractEventLoop) -> list[BaseException]:
    errors = await _cancel_tasks(loop)
    try:
        await loop.shutdown_asyncgens()
    except BaseExceptionGroup as error:
        errors.append(error)
    errors.extend(await _cancel_tasks(loop))
    await loop.shutdown_default_executor()
    return errors
