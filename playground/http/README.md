# HTTP Playground

Manual verification fixtures for Poste's HTTP features. Start the test server,
then run `.http` files against it.

## Structure

```
http/
├── server/                     ← Docker test server (httpbin-like)
│   ├── docker-compose.yml      Start: docker compose -f server/docker-compose.yml up -d
│   ├── server.py               FastAPI server on port 8888
│   ├── Dockerfile
│   └── README.md
│
├── scenarios/                  ← .http files for manual testing
│   ├── test_server.http        Comprehensive endpoint test (50+ requests)
│   ├── variable_resolver_test.http
│   └── variable_resolver_imported.http
│
└── data/                       ← Test data files
    ├── simple.txt
    ├── test_data.txt
    ├── smoke_test.sh
    └── env.json
```

## Quick Start

```bash
# Start the test server
docker compose -f server/docker-compose.yml up -d

# Wait for health
curl -sf http://localhost:8888/health

# Run a test scenario
cargo run -- run --line 6 scenarios/test_server.http

# Stop the server
docker compose -f server/docker-compose.yml down
```
