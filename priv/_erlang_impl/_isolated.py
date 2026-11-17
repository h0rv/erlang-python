"""Compatibility exports for the isolated child runtime."""

from _erlang_isolated._isolated import Runtime, install_erlang_module

__all__ = ['Runtime', 'install_erlang_module']
