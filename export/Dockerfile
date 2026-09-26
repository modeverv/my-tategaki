# Native arm64/amd64 manifest, verified 2026-09-27. Refresh pins deliberately.
FROM node:22-bookworm-slim@sha256:43ac6c60b8f89723f746e8a92ce91abd5017e627ce1ddfe4238355d3a30b772c AS runtime
ENV DEBIAN_FRONTEND=noninteractive PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    CHROME_BIN=/usr/bin/chromium PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium \
    PUPPETEER_SKIP_DOWNLOAD=true HOME=/tmp/home
RUN rm /etc/apt/sources.list.d/debian.sources && \
    printf 'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20260926T000000Z bookworm main\ndeb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/20260926T000000Z bookworm-security main\n' > /etc/apt/sources.list && \
    apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl unzip python3 python3-jsonschema python3-fonttools \
      emacs-nox pandoc chromium fonts-noto-cjk fonts-noto-color-emoji \
      fontconfig poppler-utils default-jre-headless tini && \
    mkdir -p /opt/tategaki/licenses && \
    dpkg-query -W > /opt/tategaki/debian-packages.lock && \
    cp /usr/share/doc/fonts-noto-cjk/copyright /opt/tategaki/licenses/fonts-noto-cjk.txt && \
    cp /usr/share/doc/fonts-noto-color-emoji/copyright /opt/tategaki/licenses/fonts-noto-color-emoji.txt && \
    rm -rf /var/lib/apt/lists/*
RUN curl -fL --retry 3 https://github.com/w3c/epubcheck/releases/download/v5.4.0/epubcheck-5.4.0.zip -o /tmp/epubcheck.zip && \
    echo '33350c61038e71dfb3d45a76aed04bf5481e6d5500cb780f6e98db8bbd15a28c  /tmp/epubcheck.zip' | sha256sum -c - && \
    unzip -q /tmp/epubcheck.zip -d /opt && mv /opt/epubcheck-5.4.0 /opt/epubcheck && \
    printf '#!/bin/sh\nexec java -jar /opt/epubcheck/epubcheck.jar "$@"\n' > /usr/local/bin/epubcheck && \
    chmod +x /usr/local/bin/epubcheck && rm /tmp/epubcheck.zip
WORKDIR /opt/vivliostyle
COPY export/package.json export/package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && \
    ln -s /opt/vivliostyle/node_modules/.bin/vivliostyle /usr/local/bin/vivliostyle
ENV PYTHONPATH=/app/export
WORKDIR /app
COPY *.el ./
COPY export ./export
COPY test/export ./test/export
ENTRYPOINT ["/usr/bin/tini", "--", "python3", "-m", "tategaki_export"]
