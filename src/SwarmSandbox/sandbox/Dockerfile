# SwarmSandbox M2 - sandbox workspace image.
#
# Verified spec this image must satisfy:
# - The ZCode desktop enters the container exclusively via
#   `docker exec -i <name> sh -lc '<cmd>'` and deploys its server into
#   $HOME/.zcode on first connect. So the image needs: POSIX /bin/sh,
#   tar + gzip, coreutils, git, a stable non-root user whose login-shell
#   $HOME is writable, and nothing under $HOME/.zcode (the desktop or M1
#   seeds that; this image must not interfere).
# - PowerShell 7 (pinned) for this repo's PowerShell-based agent tooling.
FROM debian:trixie-slim@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132

ARG POWERSHELL_VERSION=7.5.2

ENV HOME=/home/sandbox \
    POWERSHELL_TELEMETRY_OPTOUT=1

# Core toolchain the desktop relies on: sh (dash) + tar/gzip/coreutils are
# already in debian-slim; git and curl are added explicitly. libicu76 is the
# ICU runtime that .NET/pwsh requires at startup (absent from trixie-slim).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        coreutils \
        curl \
        git \
        gzip \
        libicu76 \
        tar \
    && rm -rf /var/lib/apt/lists/*

# PowerShell 7, pinned to POWERSHELL_VERSION, from the official release
# tarball; symlinked onto PATH so login shells (`sh -lc`) find it.
RUN curl -fsSL "https://github.com/PowerShell/PowerShell/releases/download/v${POWERSHELL_VERSION}/powershell-${POWERSHELL_VERSION}-linux-x64.tar.gz" \
        -o /tmp/powershell.tar.gz \
    && mkdir -p /opt/microsoft/powershell/7 \
    && tar -xzf /tmp/powershell.tar.gz -C /opt/microsoft/powershell/7 \
    && rm -f /tmp/powershell.tar.gz \
    && chmod 755 /opt/microsoft/powershell/7/pwsh \
    && ln -s /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh \
    && pwsh --version

# Non-root runtime user (uid 1000). /workspace and /workspace-clone-error.txt
# are pre-created and owned by 'sandbox' so the entrypoint (running as
# non-root) can clone into /workspace and write the failure marker.
RUN useradd --uid 1000 --shell /bin/sh sandbox \
    && mkdir -p /home/sandbox /workspace \
    && touch /workspace-clone-error.txt \
    && chown -R sandbox:sandbox /home/sandbox /workspace /workspace-clone-error.txt

COPY --chmod=0755 entrypoint.sh /entrypoint.sh

USER sandbox
WORKDIR /workspace

ENTRYPOINT ["/entrypoint.sh"]
