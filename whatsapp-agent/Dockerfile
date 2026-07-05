FROM node:20-slim

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force

COPY src ./src

ENV NODE_ENV=production
# sessão do WhatsApp + histórico ficam em /app/data (montar volume!)
VOLUME ["/app/data"]

CMD ["node", "src/index.js"]
