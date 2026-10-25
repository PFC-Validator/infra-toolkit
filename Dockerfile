FROM --platform=$BUILDPLATFORM alpine:3 AS build-env

RUN apk add --update --no-cache \
  automake \
  autoconf \
  bash \
  bison \
  curl \
  eudev-dev \
  flex \
  gcc \
  git \
  libc-dev \
  libtool \
  linux-headers \
  make \
  wget

ARG TARGETARCH
ARG BUILDARCH

RUN LIBDIR=/lib; \
    if [ "${TARGETARCH}" = "arm64" ]; then \
      ARCH=aarch64; \
      if [ "${BUILDARCH}" != "arm64" ]; then \
        wget -c https://musl.cc/aarch64-linux-musl-cross.tgz -O - | tar -xzvv --strip-components 1 -C /usr; \
        LIBDIR=/usr/aarch64-linux-musl/lib; \
        mkdir -p $LIBDIR; \
      fi; \
    elif [ "${TARGETARCH}" = "amd64" ]; then \
      ARCH=x86_64; \
      if [ "${BUILDARCH}" != "amd64" ]; then \
        wget -c https://musl.cc/x86_64-linux-musl-cross.tgz -O - | tar -xzvv --strip-components 1 -C /usr; \
        LIBDIR=/usr/x86_64-linux-musl/lib; \
        mkdir -p $LIBDIR; \
      fi; \
    fi;

# Build minimal busybox
WORKDIR /
# busybox v1.36.1 (GitHub mirror: git.busybox.net is flaky from build envs; mirror lags upstream - bump again when it catches up)
RUN git clone -b 1_36_1 --single-branch --depth 1 https://github.com/mirror/busybox
WORKDIR /busybox
ADD busybox.min.config .config
RUN if [ "${TARGETARCH}" = "arm64" ] && [ "${BUILDARCH}" != "arm64" ]; then \
      export CC=aarch64-linux-musl-gcc; \
    elif [ "${TARGETARCH}" = "amd64" ] && [ "${BUILDARCH}" != "amd64" ]; then \
      export CC=x86_64-linux-musl-gcc; \
    fi; \
    yes "" | make oldconfig; \
    make

# Static jq
WORKDIR /
RUN git clone --recursive -b jq-1.8.2 --single-branch https://github.com/jqlang/jq.git
WORKDIR /jq
RUN autoreconf -fi;\
  ./configure --with-oniguruma=builtin;\
  make LDFLAGS=-all-static

# Build the Go helper binaries from source with a current toolchain.
# The prebuilt upstream binaries carried known Go stdlib CVEs: boxboat's
# envsubst (a8m/envsubst, built with go1.18) and the dasel v1.26.0 release
# binary (go1.21). Both are trivial to build; pinned source tags only.
FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS go-tools
RUN apk add --no-cache git
ARG TARGETARCH
RUN git clone --depth 1 -b v1.4.3 https://github.com/a8m/envsubst /src/envsubst && \
    cd /src/envsubst && \
    CGO_ENABLED=0 GOOS=linux GOARCH=$TARGETARCH go build -o /usr/local/bin/envsubst ./cmd/envsubst && \
    git clone --depth 1 -b v1.26.0 https://github.com/TomWright/dasel /src/dasel && \
    cd /src/dasel && \
    CGO_ENABLED=0 GOOS=linux GOARCH=$TARGETARCH go build -o /usr/local/bin/dasel ./cmd/dasel

# config-merge ships as JS + wrapper scripts; only the directory payload is
# used from here (envsubst now comes from go-tools above).
FROM boxboat/config-merge:0.2.3 as config-merge

FROM alpine:3

RUN apk add --no-cache \
  aria2 \
  curl \
  lz4 \
  nano \
  npm \
  procps \
  rsync \
  tar \
  unzip \
  wget \
  zstd

# Install busybox
COPY --from=build-env /busybox/busybox /busybox/busybox

# Install jq
COPY --from=build-env /jq/jq /usr/local/bin/jq

# Add config-merge
COPY --from=config-merge /usr/local/config-merge /usr/local/config-merge
COPY --from=config-merge /usr/local/bin/config-merge /usr/local/bin/config-merge
COPY --from=go-tools /usr/local/bin/envsubst /usr/local/bin/envsubst

# Add dasel (built from source in go-tools).
COPY --from=go-tools /usr/local/bin/dasel /usr/local/bin/dasel
