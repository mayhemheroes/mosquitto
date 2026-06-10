# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) — builds ON TOP of the org C/C++ base image
# (ghcr.io/mayhemheroes/base). The base provides debian + clang/llvm + libFuzzer/afl++ + the
# identities + the build-contract ENV; this only adds the per-commit mosquitto build.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t mosquitto-commit:test .

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); never bake it as ENV — an empty value
# breaks clang. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# Declare it WITHOUT a default so an unset arg lets the base ENV flow through; --build-arg overrides.
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# mosquitto build/test deps (mirrors OSS-Fuzz fuzzing/scripts/oss-fuzz-dependencies.sh):
#  - cmake/make/pkg-config/git/libtool-bin: build cJSON + mosquitto
#  - libssl-dev: TLS/PSK code linked into the broker archive (-lssl -lcrypto)
#  - libargon2-dev: broker password hashing (-largon2)
#  - liblzma-dev, zlib1g-dev, xz-utils: transitive broker deps
#  - libsqlite3-dev: pulled by mosquitto's make include path (persistence headers)
#  - libcunit1-dev: the libcommon unit-test suite that mayhem/test.sh runs
USER root
RUN apt-get update && apt-get install -yq --no-install-recommends \
      cmake make pkg-config git libtool-bin \
      libssl-dev libargon2-dev liblzma-dev zlib1g-dev xz-utils libsqlite3-dev \
      libcunit1-dev \
    && rm -rf /var/lib/apt/lists/*

# Build the broker's direct dependency cJSON as a static lib and install it to /usr/local (needs
# root). Mirrors OSS-Fuzz fuzzing/scripts/oss-fuzz-build.sh — built here so build.sh can run as the
# unprivileged `mayhem` user.
RUN git clone --depth 1 https://github.com/ralight/cJSON /opt/cJSON \
    && cd /opt/cJSON \
    && cmake -DBUILD_SHARED_LIBS=OFF -DCMAKE_C_FLAGS=-fPIC -DENABLE_CJSON_TEST=OFF . \
    && make -j"$(nproc)" \
    && make install \
    && ldconfig
USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history)
# is copied to /mayhem as the build root; build.sh builds in place.
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run mosquitto's libcommon unit suite at build time (a failing suite fails the image build).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
