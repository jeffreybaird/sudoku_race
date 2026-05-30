# Multi-stage Phoenix release build
# ---------------------------------------------------------------------------
# Stage 1: build dependencies & compile assets
# ---------------------------------------------------------------------------
ARG ELIXIR_VERSION=1.19.5
# OTP 28, pinned to the newest patch that hexpm/elixir publishes for linux/amd64.
# 28.5.0.1 exists only as arm64 right now, so an amd64 CI build (ubuntu-latest)
# fails with "no match for platform in manifest". 28.4.3 is multi-arch
# (amd64 + arm64). Still OTP 28 per the OTP version policy in CLAUDE.md.
ARG OTP_VERSION=28.4.3
ARG DEBIAN_VERSION=bookworm-20260518-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# Install build tools
RUN apt-get update -y && \
    apt-get install -y build-essential git curl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Node.js (for esbuild/tailwind assets)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && mix local.rebar --force

# Set build env
ENV MIX_ENV=prod

# Copy dependency manifests first (better layer caching)
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Copy compile-time config files (runtime.exs is handled at startup)
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# Copy assets and compile them
COPY priv priv
COPY assets assets
RUN mix assets.deploy

# Compile the application
COPY lib lib
RUN mix compile

# Copy remaining config (runtime.exs)
COPY config/runtime.exs config/

# Build release
COPY rel rel
RUN mix release

# ---------------------------------------------------------------------------
# Stage 2: minimal runtime image
# ---------------------------------------------------------------------------
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Set locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

# Copy the release from the builder stage
COPY --from=builder --chown=nobody:root /app/_build/prod/rel/sudoku_race ./

USER nobody

ENV HOME=/app
ENV PHX_SERVER=true

CMD ["bin/sudoku_race", "start"]
