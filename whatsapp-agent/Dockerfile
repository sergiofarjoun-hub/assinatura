FROM node:20-slim

# git é necessário porque uma dependência do Baileys (libsignal) é baixada via git.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
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
