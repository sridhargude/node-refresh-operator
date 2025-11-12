# Dockerfile for Node Refresh Operator
FROM python:3.11-slim

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy operator code
COPY node_refresh_controller.py .

# Create non-root user
RUN useradd -m -u 1000 -g operator operator && \
    chown -R operator:operator /app

USER operator

# Health check endpoint (optional - requires adding HTTP server to operator)
EXPOSE 8080

CMD ["python", "-u", "node_refresh_controller.py"]
