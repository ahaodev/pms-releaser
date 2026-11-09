# Dockerfile for PMS Releaser Tool
# Based on alpine/curl with additional tools for changelog generation and release upload

FROM alpine/curl:latest

# Metadata
LABEL maintainer="CICD Team"
LABEL description="PMS Releaser CI/CD Tool with Changelog Generation"
LABEL version="1.0.0"

# Install required packages
RUN apk add --no-cache \
    bash \
    git \
    jq \
    ca-certificates \
    tzdata

# Trust only the documented container mount roots, without changing host Git config.
RUN git config --system --add safe.directory /workspace && \
    git config --system --add safe.directory /github/workspace

# Set timezone (optional, can be overridden)
ENV TZ=Asia/Shanghai

# Create working directory
WORKDIR /workspace

# Install both standalone commands and the compatibility entrypoint as siblings.
COPY scripts/ /usr/local/bin/
RUN chmod +x /usr/local/bin/pms-releaser.sh /usr/local/bin/collect-changelog.sh /usr/local/bin/pms-publish.sh && \
    ln -s /usr/local/bin/pms-releaser.sh /usr/local/bin/pms-releaser && \
    ln -s /usr/local/bin/collect-changelog.sh /usr/local/bin/collect-changelog && \
    ln -s /usr/local/bin/pms-publish.sh /usr/local/bin/pms-publish

# Set default environment variables
ENV ACCESS_TOKEN=""
ENV RELEASE_URL=""
ENV GITHUB_REF=""
ENV GITHUB_REF_NAME=""
ENV GITHUB_SHA=""

# Docker Actions use root to access runner-owned artifacts and Git metadata.
USER root

# Override alpine/curl's ENTRYPOINT so args are passed to pms-releaser
ENTRYPOINT ["pms-releaser"]

# Health check (optional)
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD which pms-releaser && which curl && which git && which jq || exit 1
