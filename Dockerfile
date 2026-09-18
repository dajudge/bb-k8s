# syntax=docker/dockerfile:1.7

FROM node:24.21.0-bookworm-slim@sha256:2fe369e969550cde8e867afc3fe370b260140cab4a23d467074295b42163d553 AS dependencies

WORKDIR /opt/bb-k8s

# npm is a bb runtime dependency used for plugin installation. npm 11.19.0
# still bundles older copies of these libraries, so replace them in bb's exact
# nested npm tree until npm publishes a fully remediated 11.x bundle.
COPY image/package.json image/package-lock.json ./

RUN npm ci \
      --omit=dev \
      --strict-allow-scripts \
    && npm install \
      --prefix /opt/npm-patches \
      --no-save \
      --ignore-scripts \
      brace-expansion@5.0.12 \
      ip-address@10.7.2 \
      tar@7.5.22 \
      undici@6.28.1 \
    && cp -a /opt/npm-patches/node_modules/brace-expansion /opt/bb-k8s/node_modules/bb-app/node_modules/npm/node_modules/ \
    && cp -a /opt/npm-patches/node_modules/ip-address /opt/bb-k8s/node_modules/bb-app/node_modules/npm/node_modules/ \
    && cp -a /opt/npm-patches/node_modules/tar /opt/bb-k8s/node_modules/bb-app/node_modules/npm/node_modules/ \
    && cp -a /opt/npm-patches/node_modules/undici /opt/bb-k8s/node_modules/bb-app/node_modules/npm/node_modules/ \
    && rm -rf /opt/npm-patches \
    && npm cache clean --force

FROM node:24.21.0-bookworm-slim@sha256:2fe369e969550cde8e867afc3fe370b260140cab4a23d467074295b42163d553 AS runtime

ARG TARGETARCH
ARG VCS_REF=unknown
ARG VERSION=dev

LABEL org.opencontainers.image.title="bb-k8s" \
      org.opencontainers.image.description="bb server and Codex-enabled primary host runtime for Kubernetes" \
      org.opencontainers.image.source="https://github.com/dajudge/bb-k8s" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.licenses="MIT"

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
      ca-certificates \
      git \
      openssh-client \
      tini \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 bb \
    && useradd --uid 10001 --gid 10001 --create-home --shell /bin/bash bb \
    && install --directory --owner bb --group bb \
      /opt/bb-k8s \
      /var/lib/bb \
      /var/lib/codex \
      /workspace

COPY --from=dependencies --chown=bb:bb /opt/bb-k8s/node_modules /opt/bb-k8s/node_modules
COPY --chown=root:root image/start-primary-host.sh image/check-url.sh /usr/local/bin/

RUN chmod 0755 /usr/local/bin/start-primary-host.sh /usr/local/bin/check-url.sh \
    && rm -rf /usr/local/lib/node_modules/npm \
    && ln -sf /opt/bb-k8s/node_modules/bb-app/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -sf /opt/bb-k8s/node_modules/bb-app/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
    && ln -s /opt/bb-k8s/node_modules/.bin/bb-app /usr/local/bin/bb-app \
    && ln -s /opt/bb-k8s/node_modules/.bin/bb /usr/local/bin/bb \
    && ln -s /opt/bb-k8s/node_modules/.bin/bb-server /usr/local/bin/bb-server \
    && ln -s /opt/bb-k8s/node_modules/.bin/bb-host-daemon /usr/local/bin/bb-host-daemon \
    && ln -s /opt/bb-k8s/node_modules/.bin/codex /usr/local/bin/codex

ENV BB_DATA_DIR=/var/lib/bb \
    CODEX_HOME=/var/lib/codex \
    HOME=/home/bb \
    NODE_ENV=production

USER 10001:10001
WORKDIR /workspace

EXPOSE 38886

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["bb-app", "--help"]
