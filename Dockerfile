# syntax=docker/dockerfile:1

# ---- Stage 1: install gems ----
FROM ruby:4.0-slim AS build

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_PATH=/usr/local/bundle

# Bundler reads the gemspec, which reads version.rb. Copying only these
# keeps this slow step cached.
COPY Gemfile Gemfile.lock rate_guard.gemspec ./
COPY lib/rate_guard/version.rb ./lib/rate_guard/
RUN bundle install --jobs 4 \
 && rm -rf /usr/local/bundle/cache

# ---- Stage 2: runtime image, no compilers or tests ----
FROM ruby:4.0-slim

WORKDIR /app
ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_PATH=/usr/local/bundle \
    RACK_ENV=production

COPY --from=build /usr/local/bundle /usr/local/bundle
# bundle exec reads the gemspec at boot too.
COPY Gemfile Gemfile.lock rate_guard.gemspec config.ru ./
COPY app ./app
COPY lib ./lib

# Let the non-root user read (not change) the code.
RUN chmod -R a+rX /app \
 && useradd --system --uid 1000 --home-dir /app app
USER app

EXPOSE 8080
CMD ["bundle", "exec", "puma", "--bind", "tcp://0.0.0.0:8080", "--log-requests", "config.ru"]
