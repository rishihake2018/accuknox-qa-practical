FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/usr/games:${PATH}"

RUN apt-get update \
    && apt-get install --no-install-recommends -y \
        bash \
        ca-certificates \
        cowsay \
        curl \
        fortune-mod \
        fortunes-min \
        socat \
        sed \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 10001 wisecow \
    && useradd --system --uid 10001 --gid wisecow --home-dir /nonexistent --shell /usr/sbin/nologin wisecow

WORKDIR /app
COPY --chown=10001:10001 wisecow.sh /app/wisecow.sh

USER 10001:10001
EXPOSE 4499

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl --fail --silent http://127.0.0.1:4499/ || exit 1

CMD ["/bin/bash", "/app/wisecow.sh"]
