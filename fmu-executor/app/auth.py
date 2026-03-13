"""Internal auth: token validation and gateway context checks."""

from __future__ import annotations

import logging
import time

from fastapi import HTTPException, Request

from . import config

logger = logging.getLogger(__name__)


def validate_internal_token(request: Request) -> None:
    """Check X-Internal-Session-Token header matches the configured secret."""
    expected = config.INTERNAL_TOKEN
    if not expected:
        # No token configured – allow (development mode).
        return
    provided = request.headers.get("X-Internal-Session-Token")
    if not provided or provided != expected:
        logger.warning("Rejected request: invalid internal token")
        raise HTTPException(status_code=401, detail="UNAUTHORIZED")


def validate_gateway_context(ctx: dict | None, access_key: str) -> None:
    """Validate that *ctx* is consistent with the requested *access_key*."""
    if ctx is None:
        raise HTTPException(status_code=400, detail="Missing gatewayContext")

    claims = ctx.get("claims") or {}

    # Check accessKey match
    ctx_key = ctx.get("accessKey") or claims.get("accessKey") or claims.get("fmuFileName")
    if ctx_key and ctx_key != access_key:
        raise HTTPException(status_code=403, detail="FORBIDDEN – accessKey mismatch")

    # Check expiry
    exp = claims.get("exp")
    if exp is not None:
        try:
            if float(exp) < time.time():
                raise HTTPException(status_code=403, detail="RESERVATION_NOT_ACTIVE")
        except (ValueError, TypeError):
            pass

    # Check nbf
    nbf = claims.get("nbf")
    if nbf is not None:
        try:
            if float(nbf) > time.time():
                raise HTTPException(status_code=403, detail="RESERVATION_NOT_ACTIVE")
        except (ValueError, TypeError):
            pass


def extract_access_key_from_context(ctx: dict) -> str | None:
    """Return the canonical access key from a gatewayContext."""
    claims = ctx.get("claims") or {}
    return ctx.get("accessKey") or claims.get("accessKey") or claims.get("fmuFileName")
