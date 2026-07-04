# Use Python slim image (wget is pre-installed)
FROM python:3.12-slim

# Copy requirements and install dependencies
COPY requirements.txt /app/requirements.txt
WORKDIR /app
RUN pip install --no-cache-dir -r requirements.txt

# Copy the server code
COPY server.py /app/server.py

# Expose the HTTP port
EXPOSE 8888

# Start the server with uvicorn for async performance
CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8888", "--log-level", "info"]