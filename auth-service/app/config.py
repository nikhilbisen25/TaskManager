from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """All configuration comes from environment variables (12-factor)."""

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    database_url: str = "postgresql+psycopg://auth:auth_local_pw@localhost:5432/authdb"
    # Shared with task-service, which verifies tokens with the same secret (HS256).
    jwt_secret: str = Field(min_length=32)
    jwt_algorithm: str = "HS256"
    jwt_expire_minutes: int = 60


@lru_cache
def get_settings() -> Settings:
    return Settings()
