from fastapi import FastAPI

from app.routers import auth

# Docs live under /api/auth so they also work behind the nginx / CloudFront /api routing.
app = FastAPI(
    title="Auth Service",
    version="1.0.0",
    docs_url="/api/auth/docs",
    openapi_url="/api/auth/openapi.json",
    redoc_url=None,
)
app.include_router(auth.router)
