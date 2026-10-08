FROM node:24.18.0-bookworm-slim@sha256:d45d78e7929b46875bbd4e29bea672d5bc48186c6c3588306521c815e78352d6
ENV NODE_ENV=production
WORKDIR /app
COPY services/store-verifier/package.json services/store-verifier/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force
COPY supabase/functions/_shared/app-store.ts supabase/functions/_shared/store-purchases.ts supabase/functions/_shared/store-verifier-protocol.ts ./supabase/functions/_shared/
COPY services/store-verifier/server.ts services/store-verifier/protocol.ts services/store-verifier/thread-runner.ts services/store-verifier/worker.ts services/store-verifier/sdk-patch.ts ./services/store-verifier/
RUN node services/store-verifier/sdk-patch.ts --apply
USER node
EXPOSE 8080
CMD ["node", "services/store-verifier/server.ts"]
