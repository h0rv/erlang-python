"""Compatibility exports for fd-based asyncio servers."""

from _erlang_isolated._server import adopt, serve, stop_serving

__all__ = ['adopt', 'serve', 'stop_serving']
