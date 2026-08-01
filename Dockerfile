# Toolchain versions are deliberate; update them together with the CI image.
FROM hexpm/elixir:1.16.3-erlang-26.2.5.21-debian-bookworm-20260713-slim@sha256:b63e3236fbf5c806b4143367cd29748556a09268bf62f7d498ce14019a978cad AS build

ENV MIX_ENV=prod
WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential git \
    && rm -rf /var/lib/apt/lists/*

RUN mix local.hex 2.5.1 --force \
    && mix local.rebar rebar3 https://github.com/erlang/rebar3/releases/download/3.25.1/rebar3 \
      --sha512 69073f6ad163f74971545015238614c327893960c1b3f26df5377df135c773a0716b48b65c2a48cef878f185dd92805abc69894adfa3fd27a90c62a64ba371e2 \
      --force
COPY mix.exs mix.lock .formatter.exs ./
RUN mix deps.get --only prod --locked && mix deps.compile

COPY config ./config
COPY lib ./lib
COPY priv ./priv
COPY docker-entrypoint.sh ./docker-entrypoint.sh
RUN mix compile --warnings-as-errors && mix release

FROM debian:bookworm-20240701-slim@sha256:f528891ab1aa484bf7233dbcc84f3c806c3e427571d75510a9d74bb5ec535b33 AS runtime

ENV LANG=C.UTF-8 \
    PHX_SERVER=true \
    HOME=/app
WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl libstdc++6 openssl \
    && rm -rf /var/lib/apt/lists/* \
    && addgroup --system app \
    && adduser --system --ingroup app app

COPY --from=build --chown=app:app /app/_build/prod/rel/floor_control ./
COPY --from=build --chown=app:app /app/docker-entrypoint.sh ./docker-entrypoint.sh
USER app

EXPOSE 4000
HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --retries=5 \
  CMD ["sh", "-c", "port=\"${PORT:-4000}\"; curl --fail --silent \"http://127.0.0.1:${port}/ready\" || exit 1"]

ENTRYPOINT ["/app/docker-entrypoint.sh"]
