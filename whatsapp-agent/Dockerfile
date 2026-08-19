FROM node:20-slim

# git: dependência do Baileys (libsignal) é baixada via git.
# python3/make/g++: fallback de compilação do better-sqlite3 (caso não haja
# binário pré-compilado para a plataforma). Normalmente o prebuilt basta.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates python3 make g++ \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force

COPY src ./src
COPY conhecimento.md ./

ENV NODE_ENV=production
# sessão do WhatsApp + histórico ficam em /app/data (montar volume!)
VOLUME ["/app/data"]

CMD ["node", "src/index.js"]
