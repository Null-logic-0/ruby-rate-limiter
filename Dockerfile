# syntax=docker/dockerfile:1

# ---- Stage 1: install gems, compiling native extensions (Puma's parser) ----
FROM ruby:4.0-slim AS build

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_PATH=/usr/local/bundle

COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4 \
 && rm -rf /usr/local/bundle/cache

# ---- Stage 2: the runtime image, without compilers or test code ----
FROM ruby:4.0-slim

WORKDIR /app
ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_PATH=/usr/local/bundle \
    RACK_ENV=production

COPY --from=build /usr/local/bundle /usr/local/bundle
COPY Gemfile Gemfile.lock config.ru ./
COPY app ./app
COPY lib ./lib

# COPY keeps the permissions the files have on your machine, where they may be
# readable only by you. Make the code readable (not writable) by everyone, so
# the unprivileged user below can load it but never change it.
RUN chmod -R a+rX /app \
 && useradd --system --uid 1000 --home-dir /app app
USER app

EXPOSE 8080
CMD ["bundle", "exec", "puma", "--bind", "tcp://0.0.0.0:8080", "--log-requests", "config.ru"]