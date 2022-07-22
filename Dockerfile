# syntax=docker/dockerfile:1.3
# [Choice] Ruby version (use -bullseye variants on local arm64/Apple Silicon): 3, 3.0, 2, 2.7, 2.6, 3-bullseye, 3.0-bullseye, 2-bullseye, 2.7-bullseye, 2.6-bullseye, 3-buster, 3.0-buster, 2-buster, 2.7-buster, 2.6-buster
ARG VARIANT=2
FROM mcr.microsoft.com/vscode/devcontainers/ruby:${VARIANT} AS base

# [Choice] Node.js version: none, lts/*, 16, 14, 12, 10
ARG NODE_VERSION="14"
RUN if [ "${NODE_VERSION}" != "none" ]; then su vscode -c "umask 0002 && . /usr/local/share/nvm/nvm.sh && nvm install ${NODE_VERSION} 2>&1"; fi

# [Optional] Uncomment this section to install additional OS packages.
RUN apt-get update && export DEBIAN_FRONTEND=noninteractive && \
  apt-get -y install --no-install-recommends \
  libvips \
  postgresql-client && \
  rm -rf /var/lib/apt/lists/* && \
  rm -rf /usr/share/locale/


# [Optional] Uncomment this line to install additional gems.
# COPY Gemfile* ./
# RUN bundle install && \
#   bundle package && \
#   find /usr/local/bundle/ -name "*.c" -delete && \
#   find /usr/local/bundle/ -name "*.o" -delete && \
#   # allow all users to update gems
#   cd /usr/local/bundle && chmod -R 777 . 

# [Optional] Uncomment this line to install global node packages.
# RUN su vscode -c "source /usr/local/share/nvm/nvm.sh && npm install -g <your-package-here>" 2>&1

FROM base as static
ENV BUNDLE_PATH='/app/vendor/bundle' \
  BUNDLE_BIN='/app/vendor/bundle/bin'
WORKDIR /app
RUN chown vscode:vscode /app
USER vscode

# dependencies
COPY --chown=vscode:vscode Gemfile* package.json ./
# js packages less likely to change than gems
# yarn packages get installed with asset:precompile
# RUN yarn install && \
#  yarn cache clean
RUN bundle install && \
  bundle package && \
  find /app/vendor/bundle/ -name "*.c" -delete && \
  find /app/vendor/bundle/ -name "*.o" -delete 

# copy backend into app
COPY --chown=vscode:vscode . .

RUN bundle exec rails assets:precompile && \
  yarn cache clean && \
  rm -rf node_modules && \
  # script to clean up the container a little
  set -e; \
  rm -rf admin;

# prep the bootsnap cache just for the hell of it
RUN bundle exec bootsnap precompile --gemfile app/ lib/

# copy over backend and admin
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]


FROM base as devcontainer

# [Optional] Uncomment this section to install additional OS packages.
# RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
#   && apt-get -y install --no-install-recommends inotify-tools

# Set up devcontainer
COPY .devcontainer/devcommands.sh ./scripts/devcommands.sh
RUN ["chmod", "+x", "./scripts/devcommands.sh"]
ENTRYPOINT ["./scripts/devcommands.sh"]
USER vscode

FROM base as prod-build

# prod env vars
ENV APP_HOME='/app' \
  BUNDLE_WITHOUT='development:test' \
  BUNDLE_PATH='/app/vendor/bundle' \
  BUNDLE_BIN='/app/vendor/bundle/bin' \
  BUNDLE_DEPLOYMENT=1 \
  NODE_ENV=production \
  RAILS_ENV=production \
  RACK_ENV=production \
  RAILS_SERVE_STATIC_FILES=true \
  RAILS_LOG_TO_STDOUT=true \
  LANG=C.UTF-8 \
  SECRET_KEY_BASE=fake 

WORKDIR /app
# copy over dep files from context
COPY Gemfile* package.json ./

# should this match the BUNDLE_PATH?
COPY --from=static --chown=rails:rails /app/vendor /app/vendor 
COPY --from=base --chown=rails:rails /usr/local/bundle /usr/local/bundle  

# install deps
# RUN bundle install
# && yarn install --check-files

# install gems
RUN bundle install && \
  rm -rf /usr/local/bundle/cache/*.gem && \
  find /usr/local/bundle/ -name "*.c" -delete && \
  find /usr/local/bundle/ -name "*.o" -delete

COPY . .

RUN cp -r admin/app/assets/* app/assets/

# precompile assets -- need to figure out min files needed to run this
RUN bundle exec rails assets:precompile && \
  bundle exec rails tmp:clear && \
  yarn cache clean

FROM ruby:${VARIANT} as production

# add group and user
ARG USER=rails
ARG GROUP=rails
ARG UID=1000
ARG GID=1000
ARG NODE_VERSION="14"
RUN addgroup --system --gid ${GID} ${GROUP} && adduser --system --uid ${UID} --ingroup ${GROUP} ${USER}

# install node
RUN curl -sL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -\
  && apt-get update -qq && apt-get install -qq --no-install-recommends \
  nodejs libvips postgresql-client libjemalloc2 \
  && apt-get upgrade -qq \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/* \ 
  && npm install -g yarn

# prod runtime env vars
ENV APP_HOME='/app' \
  BUNDLE_WITHOUT='development:test' \
  BUNDLE_PATH='/app/vendor/bundle' \
  BUNDLE_BIN='/app/vendor/bundle/bin' \
  BUNDLE_DEPLOYMENT=1 \
  NODE_ENV=production \
  RAILS_ENV=production \
  RACK_ENV=production \
  RAILS_SERVE_STATIC_FILES=true \
  RAILS_LOG_TO_STDOUT=true \
  LANG=C.UTF-8 \
  SECRET_KEY_BASE=fake \
  LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2

# copy over built gems and project
COPY --from=prod-build --chown=rails:rails /app /app
# COPY --from=prod-build /usr/local/bundle /usr/local/bundle

WORKDIR /app

RUN chown rails:rails /app

USER rails
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
