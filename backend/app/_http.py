"""Shared HTTP client helper for outbound provider calls.

TTS/STT providers historically opened a fresh ``httpx.AsyncClient`` per
request, paying a new TLS handshake + connection setup on every synth/transcribe
call. When the app wires a long-lived client (created in the FastAPI lifespan —
see ``create_app``) and injects it, providers reuse its keep-alive pool instead,
shaving the handshake off each call and cutting connection churn.

The per-call fallback (``shared=None``) keeps direct construction working with
no shared client — e.g. unit tests that instantiate a provider on its own.
"""
from __future__ import annotations

import contextlib
from collections.abc import AsyncIterator

import httpx


@contextlib.asynccontextmanager
async def acquire_client(
    shared: httpx.AsyncClient | None, *, timeout: float
) -> AsyncIterator[httpx.AsyncClient]:
    """Yield a usable ``httpx.AsyncClient``.

    Reuses ``shared`` (the lifespan-managed, connection-pooling client) when
    present; otherwise opens a short-lived client scoped to the call. Callers
    should still pass ``timeout=`` on the actual request so the shared-client
    path stays bounded too — the shared client carries no default timeout.
    """
    if shared is not None:
        yield shared
    else:
        async with httpx.AsyncClient(timeout=timeout) as client:
            yield client
