"""Entrypoint: `python -m app` or `uv run python -m app`."""
from __future__ import annotations

import uvicorn

from .config import get_settings
from .main import assert_safe_bind


def main() -> None:
    settings = get_settings()
    # Refuse to bind beyond loopback without an auth token (fail closed).
    assert_safe_bind(settings)

    # Enable HTTPS when both cert and key are configured. Tailscale-issued
    # certs (`tailscale cert <name>.ts.net`) are real Let's Encrypt certs that
    # iOS trusts without extra setup — that's the recommended path.
    https_kwargs: dict[str, str] = {}
    if settings.ssl_certfile and settings.ssl_keyfile:
        https_kwargs = {
            "ssl_certfile": settings.ssl_certfile,
            "ssl_keyfile": settings.ssl_keyfile,
        }
        scheme = "https"
    else:
        scheme = "http"

    print(f"Hermes Voice backend listening on {scheme}://{settings.host}:{settings.port}")
    uvicorn.run(
        "app.main:app",
        host=settings.host,
        port=settings.port,
        reload=False,
        log_level="info",
        **https_kwargs,
    )


if __name__ == "__main__":
    main()
