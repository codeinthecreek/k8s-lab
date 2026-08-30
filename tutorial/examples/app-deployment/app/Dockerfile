# Upstream: docker.io/library/python (python:3.13-slim). Minimal stdlib-only
# HTTP service, no pip install layer needed.
FROM python:3.13-slim
COPY app.py /app.py
EXPOSE 8080
CMD ["python3", "/app.py"]
