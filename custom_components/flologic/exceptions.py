"""Exceptions for the FloLogic integration."""

from __future__ import annotations


class FloLogicError(Exception):
    """Base FloLogic error."""


class FloLogicAuthError(FloLogicError):
    """FloLogic authentication failed."""


class FloLogicTimeoutError(FloLogicError):
    """FloLogic cloud did not send the expected event."""
