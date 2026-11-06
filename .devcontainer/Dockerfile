FROM nim:2.4.0

# The official image already ships gcc, g++, git, curl, openssl, and PCRE.
# lldb is the debugger the Nim extension uses for "Debug selected file".
# 2.4.0 images are amd64 and i386 only until the arm builds are published.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        lldb \
        sudo \
    ; \
    rm -rf /var/lib/apt/lists/*

ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=1000

RUN set -eux; \
    groupadd --gid "${USER_GID}" "${USERNAME}"; \
    useradd --uid "${USER_UID}" --gid "${USER_GID}" --create-home --shell /bin/bash "${USERNAME}"; \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"; \
    chmod 0440 "/etc/sudoers.d/${USERNAME}"

USER ${USERNAME}

# The official image only puts /root/.nimble/bin on PATH. Binaries for this user
# land in /home/vscode/.nimble/bin, listed first so the Atlas release below
# shadows the older atlas shipped inside the compiler tarball.
ENV HOME=/home/vscode
ENV PATH="/home/vscode/.nimble/bin:/opt/nim/bin:${PATH}"

# The image's WORKDIR is /usr/src/app and is owned by root. A link line longer
# than 32k characters makes the compiler write <project>_linkerArgs.txt in the
# current directory, and nimlangserver crosses that limit. Build from a
# directory this user can write.
WORKDIR /home/vscode

# nimlangserver has no binary release for this image. Nimble compiles it.
# The lock file pins Nim 2.2.12. --useSystemNim and --nim keep the 2.4.0
# compiler in this image, which satisfies nimlangserver's `nim >= 2.2.12`.
# nph 0.7.0, the formatter nimlangserver calls, only compiles on Nim 2.2, so
# the matching release binary is installed instead. It embeds the 2.2 parser
# and will not format syntax that was added in 2.4.
RUN set -eux; \
    git config --global --add safe.directory '*'; \
    nimble install -y -g --useSystemNim --nim:/opt/nim/bin/nim nimlangserver; \
    dpkgArch="$(dpkg --print-architecture)"; \
    case "${dpkgArch}" in \
      amd64) nphAsset='nph-linux_x64.tar.gz'; nphSha='1a01337e704e18471cf5d584547ff82ce92cb54df1e44b25c5027c73cc67479f' ;; \
      i386) nphAsset='nph-linux_x32.tar.gz'; nphSha='015f9b6457f86304615dd61a9c0470d8ae9a811166a706f74a8678388d46040e' ;; \
      *) echo >&2 "nph 0.7.0 has no binary for ${dpkgArch}"; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/nph.tar.gz \
      "https://github.com/arnetheduck/nph/releases/download/v0.7.0/${nphAsset}"; \
    echo "${nphSha}  /tmp/nph.tar.gz" | sha256sum --check --strict -; \
    mkdir -p /home/vscode/.nimble/bin; \
    tar -xzf /tmp/nph.tar.gz -C /home/vscode/.nimble/bin nph; \
    chmod +x /home/vscode/.nimble/bin/nph; \
    rm -f /tmp/nph.tar.gz; \
    command -v nim; \
    command -v nimsuggest; \
    command -v nimlangserver; \
    command -v nph; \
    nim --version; \
    nimlangserver -v; \
    nph --version

# Current Atlas (package cloner). The copy bundled with Nim is older.
# The installer uses the latest GitHub release and falls back to a source build.
RUN set -eux; \
    curl -fsSL -o /tmp/atlas-install.sh \
        https://raw.githubusercontent.com/nim-lang/atlas/master/install.sh; \
    bash /tmp/atlas-install.sh; \
    rm -f /tmp/atlas-install.sh; \
    command -v atlas; \
    command -v atlas-run; \
    atlas --version; \
    atlas-run --version

# NimLang.nimlang is published only on the VS Code Marketplace. Cursor installs
# from Open VSX, so the marketplace id never resolves. The container installs
# this release VSIX directly.
RUN set -eux; \
    mkdir -p /home/vscode/.vscode-extensions; \
    curl -fsSL -o /home/vscode/.vscode-extensions/nimvscode-1.8.1.vsix \
        https://github.com/nim-lang/vscode-nim/releases/download/v1.8.1/nimvscode-1.8.1.vsix; \
    echo "0297ead1578b1265e7c6c6a2a40f9a26bfd05fe721010406410fbae21a8521b0  /home/vscode/.vscode-extensions/nimvscode-1.8.1.vsix" \
        | sha256sum --check --strict -

WORKDIR /workspaces/parseSEGD
