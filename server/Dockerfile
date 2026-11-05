FROM node:24-slim
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY src ./src
ENV NODE_ENV=production DATA_DIR=/data PORT=3000
# Папка данных должна принадлежать node до объявления тома: иначе служба не создаст базу.
RUN mkdir -p /data && chown node:node /data
VOLUME /data
EXPOSE 3000
USER node
CMD ["node", "src/index.ts"]
