import jwt

from app.config import get_settings

USER = {"email": "Alice@Example.com", "password": "s3cret-pass", "full_name": "Alice"}


def register(client, **overrides):
    return client.post("/api/auth/register", json={**USER, **overrides})


def login(client, email=USER["email"], password=USER["password"]):
    return client.post("/api/auth/login", json={"email": email, "password": password})


def test_register_creates_user_and_hides_password(client):
    res = register(client)
    assert res.status_code == 201
    body = res.json()
    assert body["email"] == "alice@example.com"  # normalised to lower case
    assert body["full_name"] == "Alice"
    assert "id" in body
    assert "password" not in body and "password_hash" not in body


def test_register_duplicate_email_returns_409(client):
    assert register(client).status_code == 201
    res = register(client, email="alice@example.com")
    assert res.status_code == 409


def test_register_rejects_short_password_and_bad_email(client):
    assert register(client, password="short").status_code == 422
    assert register(client, email="not-an-email").status_code == 422


def test_login_returns_jwt_with_expected_claims(client):
    user_id = register(client).json()["id"]
    res = login(client)
    assert res.status_code == 200
    body = res.json()
    assert body["token_type"] == "bearer"
    assert body["expires_in"] == get_settings().jwt_expire_minutes * 60

    claims = jwt.decode(body["access_token"], get_settings().jwt_secret, algorithms=["HS256"])
    assert claims["sub"] == user_id
    assert claims["email"] == "alice@example.com"
    assert "exp" in claims


def test_login_wrong_password_and_unknown_email_return_401(client):
    register(client)
    assert login(client, password="wrong-password").status_code == 401
    assert login(client, email="nobody@example.com").status_code == 401


def test_me_requires_valid_token(client):
    register(client)
    token = login(client).json()["access_token"]

    assert client.get("/api/auth/me").status_code == 401
    assert client.get("/api/auth/me", headers={"Authorization": "Bearer junk"}).status_code == 401

    res = client.get("/api/auth/me", headers={"Authorization": f"Bearer {token}"})
    assert res.status_code == 200
    assert res.json()["email"] == "alice@example.com"


def test_health(client):
    res = client.get("/api/auth/health")
    assert res.status_code == 200
    assert res.json() == {"status": "UP"}
