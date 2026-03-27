FROM node:24-alpine
WORKDIR /app
COPY app/package.json ./package.json
COPY app/server.js ./server.js
EXPOSE 8080
CMD ["node", "server.js"]
