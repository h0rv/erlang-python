"""Compatibility exports for the isolated ETF codec."""

from _erlang_isolated._etf import (
    Atom,
    DecodeError,
    Pid,
    Port,
    Ref,
    decode,
    encode,
    register_encoder,
)

__all__ = [
    'Atom',
    'DecodeError',
    'Pid',
    'Port',
    'Ref',
    'decode',
    'encode',
    'register_encoder',
]
