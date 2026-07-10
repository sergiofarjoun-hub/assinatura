FROM node:22-bookworm-slim

# Ferramentas úteis para o agente usar via bash dentro do container
# + chromium para a ferramenta de navegador (playwright-core usa o binário do sistema)
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash git curl ca-certificates python3 unzip jq \
    chromium fonts-liberation \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install --omit=dev
COPY server.js browser.js ./
COPY public ./public

ENV PORT=3010
ENV WORKSPACES_ROOT=/app/workspace
ENV SESSIONS_ROOT=/app/sessions
ENV CHROME_PATH=/usr/bin/chromium
EXPOSE 3010
CMD ["node", "server.js"]
