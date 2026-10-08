# Gradstep paper pipeline worker (Cloud Run). Built from a context prepared by
# scripts/deploy-pipeline-worker.py: this directory plus supabase/functions/_shared.
FROM node:24-slim
# ffmpeg/ffprobe encode and verify podcast audio (mono AAC, chapters); see podcast-encode.ts.
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force
COPY supabase/functions/_shared ./supabase/functions/_shared
COPY server.ts run.ts podcast-run.ts podcast-encode.ts ./services/pipeline-worker/
ENV NODE_ENV=production
USER node
EXPOSE 8080
CMD ["node", "services/pipeline-worker/server.ts"]
