#!/bin/bash
# Queue all PDFs from the mounted /input/ folder for ingestion.
# Usage: ./ingest-local.sh
#
# This calls the ingest API with action "ingest-local", which scans
# /app/input/ inside the container for PDF files and queues them all.

PORT=${1:-3321}

echo "Queuing local PDFs for ingestion on port $PORT..."
curl -s -X POST "http://localhost:$PORT/api/ingest" \
  -H "Content-Type: application/json" \
  -d '{"action": "ingest-local"}' | python3 -m json.tool 2>/dev/null || \
curl -s -X POST "http://localhost:$PORT/api/ingest" \
  -H "Content-Type: application/json" \
  -d '{"action": "ingest-local"}'

echo ""
echo "Done. Papers will appear in the Library and process in the background."
echo "Check status: curl http://localhost:$PORT/api/ingest"
