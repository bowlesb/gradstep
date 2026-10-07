# Gradstep workflow checks as a Cloud Run job (docs/architecture/WORKFLOW_CHECKS.md).
# Build context: the repository root (scripts/schedule-workflow-checks.py copies only what is needed).
# Secrets arrive as environment variables from Secret Manager; nothing secret is in the image.
FROM node:24-slim
WORKDIR /app
COPY scripts/workflow-checks.mjs scripts/workflow-checks.mjs
# downloads.corpus runs the pipeline's own download code (dependency-free TypeScript; Node 24 strips types).
COPY supabase/functions/_shared/web-source.ts supabase/functions/_shared/web-source.ts
COPY infra/ infra/
ENV WORKFLOW_REPORT_DIR=/tmp/workflow-checks NODE_ENV=production
USER node
ENTRYPOINT ["node", "scripts/workflow-checks.mjs"]
CMD ["--suite=daily", "--trigger=schedule", "--record", "--notify"]
