from sqlalchemy.orm import DeclarativeBase


class Base(DeclarativeBase):
    """Kept separate from db.py so Alembic can import models without settings/engine."""
