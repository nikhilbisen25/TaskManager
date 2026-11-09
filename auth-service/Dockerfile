# ---- build stage: install deps into a venv ----
FROM python:3.12-slim AS build
WORKDIR /app
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ---- runtime stage: slim image, non-root ----
FROM python:3.12-slim
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8001
WORKDIR /app
COPY --from=build /opt/venv /opt/venv
COPY alembic.ini .
COPY alembic ./alembic
COPY app ./app
RUN useradd --system --uid 10001 appuser
USER appuser
EXPOSE 8001
HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --retries=5 \
  CMD python -c "import urllib.request,os; urllib.request.urlopen(f'http://localhost:{os.environ[\"PORT\"]}/api/auth/health', timeout=2)"
# Run DB migrations, then start the API.
CMD ["sh", "-c", "alembic upgrade head && exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT} --proxy-headers --forwarded-allow-ips='*'"]
