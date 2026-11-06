FROM node:24-slim
# curl нужен проверке здоровья Coolify (в лёгком образе его нет: без него Coolify считает запуск неудачным и откатывает).
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY src ./src
COPY public ./public
ENV NODE_ENV=production DATA_DIR=/data PORT=3000
# Папка данных должна принадлежать node до объявления тома: иначе служба не создаст базу.
RUN mkdir -p /data && chown node:node /data
VOLUME /data
EXPOSE 3000
USER node
CMD ["node", "src/index.ts"]
