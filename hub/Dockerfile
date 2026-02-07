# ── Stage 1: Build ──────────────────────────────────────────
FROM elixir:1.18-otp-27-alpine AS build

RUN apk add --no-cache build-base git

WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

ENV MIX_ENV=prod

# Install deps first (layer cache)
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config
COPY config/config.exs config/runtime.exs config/
RUN mix deps.compile

# Compile app
COPY lib lib
COPY priv priv
RUN mix compile

# Build release
RUN mix release

# ── Stage 2: Runtime ────────────────────────────────────────
FROM alpine:3.20 AS runtime

RUN apk add --no-cache libstdc++ openssl ncurses-libs

WORKDIR /app

# Copy release from build stage
COPY --from=build /app/_build/prod/rel/hub ./

# Create non-root user
RUN addgroup -S hub && adduser -S hub -G hub
RUN chown -R hub:hub /app
USER hub

ENV HOME=/app
ENV MIX_ENV=prod
ENV PORT=4000

# Clustering: BEAM distribution
# Set NODE_NAME and RELEASE_DISTRIBUTION in compose/k8s
ENV RELEASE_DISTRIBUTION=name
ENV RELEASE_NODE=hub@127.0.0.1

EXPOSE 4000
EXPOSE 4369
EXPOSE 9100-9200

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:4000/api/health || exit 1

CMD ["bin/hub", "start"]
