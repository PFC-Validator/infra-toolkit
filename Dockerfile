FROM --platform=$BUILDPLATFORM alpine:3.24 AS build-env

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

# Build the existing helper CLIs against the dependencies locked in tools/go.mod.
FROM --platform=$BUILDPLATFORM golang:1.27.4-alpine AS go-tools
WORKDIR /src
COPY tools/go.mod tools/go.sum ./
RUN go mod download
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=linux GOARCH=$TARGETARCH go build -mod=readonly -o /usr/local/bin/ tool

FROM boxboat/config-merge:0.2.3 AS config-merge

FROM alpine:3.24

RUN apk upgrade --no-cache && apk add --no-cache \
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

# Keep the upstream scripts and install their patched dependencies from the lockfile.
COPY config-merge/package*.json /usr/local/config-merge/
RUN npm ci --prefix /usr/local/config-merge --omit=dev --ignore-scripts --no-audit --no-fund && npm cache clean --force
COPY --from=config-merge /usr/local/config-merge/*.js /usr/local/config-merge/*.sh /usr/local/config-merge/
COPY --from=config-merge /usr/local/bin/config-merge /usr/local/bin/config-merge
COPY --from=go-tools /usr/local/bin/envsubst /usr/local/bin/envsubst

# Add dasel (built from source in go-tools).
COPY --from=go-tools /usr/local/bin/dasel /usr/local/bin/dasel
