import uuid
from datetime import datetime

from pydantic import BaseModel, ConfigDict, EmailStr, Field, field_validator


class RegisterRequest(BaseModel):
    email: EmailStr
    # bcrypt only uses the first 72 bytes, so cap the length explicitly.
    password: str = Field(min_length=8, max_length=72)
    full_name: str | None = Field(default=None, max_length=100)

    @field_validator("email")
    @classmethod
    def normalise_email(cls, v: str) -> str:
        return v.lower()


class LoginRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=1, max_length=72)

    @field_validator("email")
    @classmethod
    def normalise_email(cls, v: str) -> str:
        return v.lower()


class UserResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    email: EmailStr
    full_name: str | None
    created_at: datetime


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in: int  # seconds
