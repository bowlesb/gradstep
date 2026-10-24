# syntax=docker/dockerfile:1.7
# Gradstep paper pipeline worker (Cloud Run). Built from a context prepared by
# scripts/deploy-pipeline-worker.py: this directory plus supabase/functions/_shared.
FROM node:24-slim
# ffmpeg/ffprobe encode and verify podcast audio (mono AAC, chapters); see podcast-encode.ts.
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY package.json package-lock.json ./
# onnxruntime-node (the interest index's gte-small, CPU only): no CUDA download, and only the linux-x64 binaries are kept.
RUN ONNXRUNTIME_NODE_INSTALL=skip npm ci --omit=dev --no-audit --no-fund && npm cache clean --force \
 && cd node_modules/onnxruntime-node/bin/napi-v6 && rm -rf darwin win32 linux/arm64 && test -f linux/x64/onnxruntime_binding.node
# gte-small fp32 ONNX (Xenova/gte-small@5927d17 = thenlper/gte-small@17e1f347, MIT), pinned by SHA-256 at build time.
# The running worker never downloads a model (docs/architecture/INTEREST_INDEX.md §1).
ADD --checksum=sha256:398a29991324e0b383afa13375d681ced3079c83e097fb1ebd9290d7498523b3 \
  https://huggingface.co/Xenova/gte-small/resolve/5927d1727bb12db490052a1b33265ad78058de08/onnx/model.onnx \
  ./services/pipeline-worker/model/gte-small.onnx
COPY model/vocab.txt ./services/pipeline-worker/model/vocab.txt
COPY supabase/functions/_shared ./supabase/functions/_shared
COPY server.ts run.ts podcast-run.ts podcast-encode.ts interest-run.ts interest-embed.ts ./services/pipeline-worker/
RUN chmod a+r ./services/pipeline-worker/model/gte-small.onnx
ENV NODE_ENV=production
# ONNX Runtime's documented POSIX telemetry opt-out (read once at runtime initialization): no 1DS uploader, no events,
# no device id. interest-embed.ts refuses to load the runtime without it (docs/architecture/INTEREST_INDEX.md §1).
ENV ORT_DISABLE_TELEMETRY=1
USER node
EXPOSE 8080
CMD ["node", "services/pipeline-worker/server.ts"]
