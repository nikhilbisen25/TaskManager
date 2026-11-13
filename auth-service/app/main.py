import logging

from fastapi import FastAPI

from app.routers import auth

# App log lines ("app.auth - Login ok user=...") go to stdout next to uvicorn's access log.
logging.basicConfig(level=logging.INFO, format="%(levelname)s:     %(name)s - %(message)s")


class _SkipHealthChecks(logging.Filter):
    """Docker/compose hit /health every 10 s; hide those so real requests stay readable."""

    def filter(self, record: logging.LogRecord) -> bool:
        return "/api/auth/health" not in record.getMessage()


logging.getLogger("uvicorn.access").addFilter(_SkipHealthChecks())

# Docs live under /api/auth so they also work behind the nginx / CloudFront /api routing.
app = FastAPI(
    title="Auth Service",
    version="1.0.0",
    docs_url="/api/auth/docs",
    openapi_url="/api/auth/openapi.json",
    redoc_url=None,
)
app.include_router(auth.router)
