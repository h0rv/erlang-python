"""Compatibility exports for shared memory wrappers."""

from _erlang_isolated._shm import (
    SharedBuffer,
    SharedMemory,
    _cache,
    forget,
    from_term,
    is_shared,
)

__all__ = ['SharedBuffer', 'SharedMemory', '_cache', 'forget', 'from_term', 'is_shared']
