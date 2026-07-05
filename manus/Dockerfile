FROM node:22-bookworm-slim

# Ferramentas úteis para o agente usar via bash dentro do container
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash git curl ca-certificates python3 unzip jq \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install --omit=dev
COPY server.js ./
COPY public ./public

ENV PORT=3010
ENV WORKSPACES_ROOT=/app/workspace
EXPOSE 3010
CMD ["node", "server.js"]
