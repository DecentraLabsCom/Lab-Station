"""Entry point: ``python -m app`` starts the FMU Executor service."""

import uvicorn
from .config import BIND_HOST, BIND_PORT

uvicorn.run("app.main:app", host=BIND_HOST, port=BIND_PORT, log_level="info")
