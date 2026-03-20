# Stage 1: Build
ARG ELIXIR_VERSION=1.17.3
ARG OTP_VERSION=27.2.4
ARG ALPINE_VERSION=3.21.3

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-alpine-${ALPINE_VERSION} AS build

RUN apk add --no-cache build-base git

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets

RUN mix compile --force
RUN mix assets.deploy

COPY config/runtime.exs config/
RUN mix release

# Stage 2: Runtime
FROM alpine:${ALPINE_VERSION} AS runtime

RUN apk add --no-cache libstdc++ openssl ncurses-libs

ENV LANG=en_US.UTF-8
ENV MIX_ENV=prod
ENV PHX_SERVER=true
ENV BOOTSTRAP=true

WORKDIR /app

COPY --from=build /app/_build/prod/rel/homelab ./

# Runs as root: this is a Docker management tool that requires socket access.
# The security boundary is the socket mount itself, same as Portainer/Swarmpit.

EXPOSE 4000

ENTRYPOINT ["bin/homelab"]
CMD ["start"]
