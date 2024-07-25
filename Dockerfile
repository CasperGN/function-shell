# syntax=docker/dockerfile:1

# We use the latest Go 1.x version unless asked to use something else.
# The GitHub Actions CI job sets this argument for a consistent Go version.
ARG GO_VERSION=1

# Setup the base environment. The BUILDPLATFORM is set automatically by Docker.
# The --platform=${BUILDPLATFORM} flag tells Docker to build the function using
# the OS and architecture of the host running the build, not the OS and
# architecture that we're building the function for.
FROM --platform=${BUILDPLATFORM} golang:${GO_VERSION} AS build

RUN apt-get update && apt-get install -y coreutils jq unzip zsh
RUN mkdir /scripts && chown 2000:2000 /scripts

# TODO: Install awscli, gcloud
# RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip" && \
#	unzip "/tmp/awscliv2.zip" && \
#	./aws/install

WORKDIR /fn

# Most functions don't want or need CGo support, so we disable it.
ENV CGO_ENABLED=0

# We run go mod download in a separate step so that we can cache its results.
# This lets us avoid re-downloading modules if we don't need to. The type=target
# mount tells Docker to mount the current directory read-only in the WORKDIR.
# The type=cache mount tells Docker to cache the Go modules cache across builds.
RUN --mount=target=. --mount=type=cache,target=/go/pkg/mod go mod download

# The TARGETOS and TARGETARCH args are set by docker. We set GOOS and GOARCH to
# these values to ask Go to compile a binary for these architectures. If
# TARGETOS and TARGETOS are different from BUILDPLATFORM, Go will cross compile
# for us (e.g. compile a linux/amd64 binary on a linux/arm64 build machine).
ARG TARGETOS
ARG TARGETARCH

# Build the function binary. The type=target mount tells Docker to mount the
# current directory read-only in the WORKDIR. The type=cache mount tells Docker
# to cache the Go modules cache across builds.
RUN --mount=target=. \
    --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -o /function .

FROM --platform=${BUILDPLATFORM} mcr.microsoft.com/azure-cli AS whack

ARG TARGETARCH

RUN addgroup -g 2000 whack && adduser whack -u 2000 -g 2000 -S /bin/bash

WORKDIR /tmp

#RUN export ARCH=$(if [$TARGETARCH -eq "arm64"]; then echo "aarch64"; else echo "x86_64"; fi)

RUN if [ "$TARGETARCH" == "arm64" ]; then wget "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -O "awscliv2.zip"; else wget "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -O "awscliv2.zip"; fi && \
    unzip awscliv2.zip && \
    ./aws/install && \
    rm -rf /tmp/* 

RUN mkdir /.azure && chown 2000: /.azure

COPY --from=build /scripts /scripts
COPY --from=build /bin /bin
COPY --from=build /etc /etc
COPY --from=build /lib /lib
COPY --from=build /tmp /tmp
COPY --from=build /usr /usr
COPY --from=build /function /function

WORKDIR /home
EXPOSE 9443
USER 2000:2000
ENTRYPOINT ["/function"]