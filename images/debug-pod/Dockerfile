# syntax=docker/dockerfile:1

# Debug pod image, see README.md for build and push instructions.
# All tool versions are pinned; override with --build-arg to upgrade.

ARG DEBIAN_TAG=trixie-20260918-slim

FROM debian:${DEBIAN_TAG}

ARG TARGETARCH

ARG KUBECTL_VERSION=v1.37.1
ARG FLUX_VERSION=2.9.5
ARG KUSTOMIZE_VERSION=v5.8.1
ARG ENVSUBST_VERSION=v1.4.3
ARG PY_JWT_VERSION=1.4.0

ARG DEBUG_UID=10001

# HOME is set here rather than via /etc/passwd so it is correct for any UID,
# including OpenShift's randomly assigned ones. /tmp is the only writable
# path under the chart's read-only root filesystem, so kubectl, flux, git etc.
# keep their caches and config there.
ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/tmp

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update -y \
    && apt-get install -y --no-install-recommends \
    ca-certificates \
    postgresql-common \
    ssh \
    coreutils \
    sudo \
    lsb-release \
    ack \
    bind9-dnsutils \
    libnss-wrapper \
    wget unzip git jq curl gettext-base \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/build

RUN case "${TARGETARCH}" in \
      amd64) ENVSUBST_ARCH=x86_64 ;; \
      arm64) ENVSUBST_ARCH=arm64 ;; \
      *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    # kubectl
    && curl -fsSL -o /usr/local/bin/kubectl \
       "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
    && chmod 755 /usr/local/bin/kubectl \
    # flux
    && curl -fsSL "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_linux_${TARGETARCH}.tar.gz" \
       | tar -xz -C /usr/local/bin flux \
    # kustomize
    && curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_${TARGETARCH}.tar.gz" \
       | tar -xz -C /usr/local/bin kustomize \
    # a8m envsubst (installed alongside gettext-base envsubst)
    && curl -fsSL -o /usr/local/bin/envsubst-a8m \
       "https://github.com/a8m/envsubst/releases/download/${ENVSUBST_VERSION}/envsubst-Linux-${ENVSUBST_ARCH}" \
    && chmod 755 /usr/local/bin/envsubst-a8m \
    # python jwt
    && pip3 install --no-cache-dir --break-system-packages "jwt==${PY_JWT_VERSION}" \
    && cd / && rm -rf /tmp/build

# Non-root user so the image works with the chart's default runAsNonRoot
# security context. Primary group is root (GID 0) per the OpenShift
# convention for images that may run as an arbitrary UID.
RUN useradd --uid "${DEBUG_UID}" --gid 0 --home-dir /tmp --no-create-home \
      --shell /bin/bash debug \
    && echo "debug ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/debug \
    && chmod 440 /etc/sudoers.d/debug

COPY --chmod=644 nss-wrapper.sh /etc/profile.d/nss-wrapper.sh
RUN echo '. /etc/profile.d/nss-wrapper.sh' >> /etc/bash.bashrc

USER ${DEBUG_UID}:0
WORKDIR /tmp

CMD ["/bin/bash"]
