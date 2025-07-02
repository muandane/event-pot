FROM elixir:1.15-alpine AS builder

WORKDIR /app

# Install build dependencies
RUN apk add --no-cache build-base git

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy mix files
COPY mix.exs mix.lock ./

# Install dependencies
RUN mix deps.get --only prod
RUN mix deps.compile

# Copy source code
COPY . .

# Build release
RUN MIX_ENV=prod mix release

FROM alpine:3.18

RUN apk add --no-cache openssl ncurses-libs libstdc++

WORKDIR /app

# Copy release from builder
COPY --from=builder /app/_build/prod/rel/k8s_event_watcher ./

# Create non-root user
RUN addgroup -g 1001 -S k8s && \
    adduser -S -D -H -u 1001 -h /app -s /sbin/nologin -G k8s -g k8s k8s && \
    chown -R k8s:k8s /app

USER k8s

CMD ["./bin/k8s_event_watcher", "start"]