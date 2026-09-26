FROM node:24-alpine
WORKDIR /app
COPY package.json package-lock.json server.js ./
RUN npm ci --omit=dev
COPY public ./public
USER node
ENV PORT=3000
EXPOSE 3000
CMD ["node", "server.js"]
