# syntax=docker/dockerfile:1
# check=error=true

# The `boba-api` image (DESIGN.md §14.1). One image, two workloads: `web` runs
# puma and `worker` runs sidekiq, differing only in command (§14.2).
#
# Stages:
#   base         shared runtime packages
#   build-deps   + toolchain for native gems
#   development  all gems incl. dev/test; used by compose (§12 step 0)
#   build        production gems + bootsnap precompile, thrown away
#   production   slim, non-root — the default target, and what k8s runs

# Keep in sync with .ruby-version (read by mise locally and setup-ruby in CI).
ARG RUBY_VERSION=3.4.10
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

WORKDIR /rails

RUN apt-get update -qq && \
    # procps supplies pgrep, which `worker`'s liveness probe calls
    # (k8s/base/worker.yaml). Without it every check exits 127 and the kubelet
    # restarts sidekiq roughly every two minutes, forever.
    apt-get install --no-install-recommends -y curl libjemalloc2 postgresql-client procps && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV BUNDLE_PATH="/usr/local/bundle" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"


FROM base AS build-deps

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives


# Development runs as root, unlike production. Bind-mounted source on macOS maps
# host ownership into the container, and a non-root uid then can't write tmp/,
# log/, or Gemfile.lock. The non-root requirement in §14.1 is about the image we
# deploy; this stage is never deployed.
FROM build-deps AS development

ENV RAILS_ENV="development"

# The gemspec has to land before `bundle install`, because `deficit_scheduler`
# is a path gem (ADR-0033) and bundler resolves it by reading that file — with
# only the Gemfile copied it fails outright with "the path ... does not exist".
# Just the gemspec, not the whole gem: it is written to evaluate without its own
# sources present (no `git ls-files`, no version file), so the layer cache still
# breaks on dependency changes rather than on every edit to the scheduler.
COPY Gemfile Gemfile.lock ./
COPY gems/deficit_scheduler/deficit_scheduler.gemspec gems/deficit_scheduler/
RUN bundle install

EXPOSE 3000
ENTRYPOINT ["/rails/bin/docker-entrypoint"]
CMD ["./bin/rails", "server", "-b", "0.0.0.0"]


FROM build-deps AS build

ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_WITHOUT="development:test"

# Same reason as the development stage above — and stricter here, because
# BUNDLE_DEPLOYMENT=1 freezes the lockfile, so a path gem bundler cannot read is
# a hard failure rather than a re-resolve.
COPY Gemfile Gemfile.lock ./
COPY gems/deficit_scheduler/deficit_scheduler.gemspec gems/deficit_scheduler/
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile -j 1 --gemfile

COPY . .

# `gems/` included so the scheduler gem is precompiled too — it is a path gem,
# so the --gemfile pass above ran before its sources were in the image (ADR-0033).
RUN bundle exec bootsnap precompile -j 1 app/ lib/ gems/


FROM base AS production

ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_WITHOUT="development:test"

RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# The entrypoint does NOT migrate — that is the `migrate` Job's task (§14.2).
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

EXPOSE 3000
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
