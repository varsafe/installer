#!/bin/bash
# Varsafe CLI installer
# Usage: curl -fsSL https://varsafe.dev/install.sh | bash
#
# This installer uses bash features (set -o pipefail, [[ ]]). If it was started
# by a POSIX shell — e.g. `curl ... | sh` where /bin/sh is dash — re-exec under
# bash. A POSIX shell parses input incrementally, so this runs before any
# bashism below is read.
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    # Fetch into a variable FIRST. `exec bash -c "$(curl ...)"` looks equivalent but
    # silently succeeds when the fetch fails: command substitution swallows curl's
    # exit status, the empty result becomes `bash -c ""`, and that exits 0 — a
    # no-op install reported as success. Any fetch failure (DNS, TLS, proxy, 5xx)
    # hits this path, so both the status AND the body are checked before exec.
    # -q FIRST: without it curl reads ~/.curlrc, where a stray `output=` sends the body to a
    # file (leaving stdout empty) and `write-out=` appends text to the script we are about to
    # execute. Ambient user config must not be able to alter or truncate this download.
    _varsafe_src=$(curl -q -fsSL https://varsafe.dev/install.sh)
    _varsafe_rc=$?
    if [ "$_varsafe_rc" -ne 0 ]; then
      echo "error  could not download the installer (curl exit $_varsafe_rc)." >&2
      echo "       Check your connection, then retry:" >&2
      echo "       curl -fsSL https://varsafe.dev/install.sh | bash" >&2
      exit 1
    fi
    # A non-empty body is NOT a complete one. A connection closed mid-transfer, or a proxy
    # error page, can yield a syntactically valid prefix that runs and exits 0 — the same
    # silent no-op this guard exists to prevent. Require the sentinel on the installer's LAST
    # line, so only a body that arrived complete is executed.
    #
    # The sentinel is assembled from two halves rather than written out, so the full string
    # exists exactly ONCE in this file — on the final line. Spelling it literally here would
    # put it above every truncation point, and any body cut off after this line would still
    # "contain the end marker" and run. The test suite asserts that single occurrence.
    _varsafe_end='# varsafe-installer'
    _varsafe_end="$_varsafe_end-end"
    case "$_varsafe_src" in
      *"$_varsafe_end"*) ;;
      *)
        echo "error  the downloaded installer was empty or truncated — refusing to run it." >&2
        echo "       A partial download can appear to succeed while installing nothing." >&2
        echo "       Retry: curl -fsSL https://varsafe.dev/install.sh | bash" >&2
        exit 1
        ;;
    esac
    exec bash -c "$_varsafe_src" varsafe-install "$@"
  fi
  echo "error  this installer requires bash. Run: curl -fsSL https://varsafe.dev/install.sh | bash" >&2
  exit 1
fi
set -euo pipefail

RELEASES_URL="https://releases.varsafe.dev/cli"

# Minimal containers (docker run, env -i) may have no HOME; under set -u a bare
# $HOME would abort with a raw "unbound variable". A custom VARSAFE_INSTALL_DIR
# makes HOME unnecessary; with neither, fail with a real message.
if [[ -z "${HOME:-}" && -z "${VARSAFE_INSTALL_DIR:-}" ]]; then
  echo "error  HOME is not set. Set VARSAFE_INSTALL_DIR to choose an install directory." >&2
  exit 1
fi
DEFAULT_INSTALL_DIR="${HOME:-}/.varsafe/bin"
INSTALL_DIR="${VARSAFE_INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
# Normalize the spelling so "$HOME/.varsafe/bin/" is recognized AS the default —
# the default-vs-custom distinction gates chmod and the fallback offer below.
INSTALL_DIR="${INSTALL_DIR%/}"
[[ -z "$INSTALL_DIR" ]] && INSTALL_DIR="/"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info() { echo -e "${CYAN}info${NC}  $1"; }
success() { echo -e "${GREEN}success${NC}  $1"; }
warn() { echo -e "${YELLOW}warn${NC}  $1"; }
error() { echo -e "${RED}error${NC}  $1"; exit 1; }

# Detect whether the Linux C library is musl (Alpine and friends) rather than glibc.
# The two are NOT binary-compatible: a glibc binary aborts on a musl-only system before it
# can even reach the keychain loader, so we ship a dedicated musl artifact.
# The loader path is per-ARCHITECTURE, so probing only the x86_64 one silently answered "glibc"
# on every musl ARM host. /etc/alpine-release and the ldd probe below cover Alpine either way;
# the explicit paths are what catch non-Alpine musl distros with an uninformative ldd.
is_musl() {
  [ -e /lib/ld-musl-x86_64.so.1 ] && return 0
  [ -e /lib/ld-musl-aarch64.so.1 ] && return 0
  [ -f /etc/alpine-release ] && return 0
  if command -v ldd >/dev/null 2>&1; then
    # Capture FIRST, match second. musl's own ldd exits non-zero for `--version` (verified on
    # Alpine: it prints "musl libc (x86_64)" and returns 1), and `set -o pipefail` at the top of
    # this script turns that into a failed probe even though the output says musl. So this
    # last-resort check — the one that exists for musl distros without the standard loader path —
    # answered "glibc" on every host it was meant to catch, and the installer would then download
    # a glibc binary that cannot exec there.
    local ldd_version
    ldd_version=$(ldd --version 2>&1 || true)
    printf '%s' "$ldd_version" | grep -qi musl && return 0
  fi
  return 1
}

# Detect platform
detect_platform() {
  local os arch

  case "$(uname -s)" in
    Linux*)  os="linux" ;;
    Darwin*) os="darwin" ;;
    *)       error "Unsupported OS: $(uname -s)" ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64) arch="x64" ;;
    arm64|aarch64) arch="arm64" ;;
    *)            error "Unsupported architecture: $(uname -m)" ;;
  esac

  # Every Linux arch ships separate glibc and musl builds; pick by detected libc. Must stay in
  # lockstep with releaseArtifactName() in packages/cli/src/shared/domain/release-target.ts —
  # this picks the FIRST install, that one picks every `varsafe update` afterwards, and a
  # disagreement means an update silently swaps the binary for one the host cannot run.
  if [[ "$os" == "linux" ]] && is_musl; then
    echo "linux-${arch}-musl"
    return
  fi

  echo "${os}-${arch}"
}

# The musl binaries dynamically link libstdc++.so.6 and libgcc_s.so.1. That comes from Bun's own
# musl runtime — `bun build --compile` bolts our bundle onto a prebuilt runtime, and upstream
# publishes no statically-linked musl build — so it cannot be removed on our side. Stock Alpine
# ships neither library, and without them the binary dies inside the dynamic loader: ~50 lines of
# mangled C++ symbol errors before a single line of varsafe runs, never naming the real cause.
#
# Best-effort EARLY hint only. The authoritative check is running the downloaded binary
# (smoke_test_binary below): a file existing at a guessed path proves nothing about whether the
# loader can actually use it — wrong architecture, wrong ABI, or its own missing dependency all
# look identical here. This exists purely to avoid a 90 MB download we can already tell will
# fail, so it is deliberately allowed to be wrong in the permissive direction.
musl_prereqs_present() {
  local found_cxx=1 found_gcc=1
  for dir in /usr/lib /lib /usr/local/lib; do
    [ -e "$dir/libstdc++.so.6" ] && found_cxx=0
    [ -e "$dir/libgcc_s.so.1" ] && found_gcc=0
  done
  [[ $found_cxx -eq 0 && $found_gcc -eq 0 ]]
}

# Install the two libraries Bun's musl runtime links against.
#
# CONSENT: root may install after saying so. Passwordless sudo is NOT treated as permission —
# a script piped from the internet finding `sudo -n` available is not the user asking it to
# modify the system package database. Non-root needs an explicit opt-in.
install_musl_prereqs() {
  local apk_args=()
  if [[ "$(id -u)" -eq 0 ]]; then
    apk_args=(apk)
  elif [[ "${VARSAFE_INSTALL_PREREQS:-}" == "1" ]] && command -v sudo >/dev/null 2>&1; then
    apk_args=(sudo -n -- apk)
  else
    return 1
  fi
  command -v apk >/dev/null 2>&1 || return 1

  info "Installing libstdc++ and libgcc (required by varsafe on musl systems)..."
  local out
  # Keep stderr: an apk failure is usually a repository, DNS, lock or read-only-fs problem, and
  # discarding it leaves the user with "could not install" and nothing to act on.
  if out=$("${apk_args[@]}" add --no-cache libstdc++ libgcc 2>&1); then
    success "libstdc++ and libgcc installed"
    return 0
  fi
  warn "Could not install them automatically:"
  echo "$out" | sed 's/^/    /' >&2
  return 1
}

musl_prereq_help() {
  echo "varsafe needs libstdc++ and libgcc on musl systems and will not start without them.
  Install them, then re-run this installer:

      apk add --no-cache libstdc++ libgcc

  Or re-run with VARSAFE_INSTALL_PREREQS=1 to let the installer do it via sudo.
  (On non-Alpine musl distributions, install your libstdc++ / libgcc equivalents.)"
}

# Does the artifact we just downloaded actually RUN here? This is the real check — it exercises
# the true loader configuration, so it catches a missing dependency, a wrong-ABI library found at
# a path we probed, and anything else that stops the binary starting. Runs BEFORE the binary is
# moved into place, so a failure never leaves an unusable varsafe on PATH.
smoke_test_binary() {
  local bin="$1" platform="$2"
  local out status
  if out=$("$bin" --version 2>&1); then
    return 0
  else
    # Must be captured HERE: after the `fi`, $? would be the if-statement's
    # own (zero) status, not the binary's.
    status=$?
  fi

  case "$platform" in
    *-musl)
      if echo "$out" | grep -qiE "libstdc\+\+|libgcc|shared library|symbol not found"; then
        if install_musl_prereqs && "$bin" --version >/dev/null 2>&1; then
          return 0
        fi
        error "$(musl_prereq_help)"
      fi
      ;;
  esac

  # An exec refusal (as opposed to a crash) usually means the destination
  # filesystem is mounted noexec — common for /tmp and hardened home dirs.
  # The CLI itself detects this at runtime (noexec-detect.ts); mirror the
  # guidance here so the install failure names the actual cause. Exit 126
  # ("found but cannot execute") is the primary, locale-independent signal;
  # the message grep is only a fallback for shells that report differently.
  if [[ $status -eq 126 ]] || echo "$out" | grep -qi "permission denied"; then
    error "The downloaded binary could not be executed:
$(echo "$out" | sed 's/^/    /')

  The filesystem at $INSTALL_DIR may be mounted noexec. Set VARSAFE_INSTALL_DIR
  to a directory on an exec-capable filesystem and re-run this installer."
  fi

  error "The downloaded binary did not run on this system:
$(echo "$out" | sed 's/^/    /')"
}

# Fetch content from URL
fetch() {
  local url="$1"
  if command -v curl &>/dev/null; then
    curl -fsSL "$url"
  elif command -v wget &>/dev/null; then
    wget -qO- "$url"
  else
    error "curl or wget is required"
  fi
}

# Download binary
download() {
  local url="$1"
  local dest="$2"

  if command -v curl &>/dev/null; then
    curl -fsSL -o "$dest" "$url"
  elif command -v wget &>/dev/null; then
    wget -qO "$dest" "$url"
  else
    error "curl or wget is required"
  fi
}

# Compute SHA-256 checksum of a file
compute_sha256() {
  local file="$1"
  if command -v sha256sum &>/dev/null; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum &>/dev/null; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    error "Neither sha256sum nor shasum found; cannot verify download integrity"
  fi
}

# Base64 of the raw 32-byte Ed25519 release-signing public key.
#
# MUST equal RELEASE_SIGNING_PUBLIC_KEY in packages/cli/src/system/release-signature.ts — the key
# `varsafe update` already verifies against. scripts/test-install-sh.sh asserts the two are equal,
# because a drift here silently downgrades every first install to unverified.
RELEASE_SIGNING_PUBLIC_KEY="EfoDKBmV+FppWbpf9LSH+oQ3JohiMmyz8q+KmsV4hOQ="

# The SAME key in OpenSSH's encoding, for `ssh-keygen -Y verify` — the verifier a stock machine
# already has (OpenSSH ships with macOS 10.15+ and every mainstream Linux, while /usr/bin/openssl on
# macOS is a LibreSSL that cannot check an Ed25519 signature at all). One trust anchor in two
# encodings: scripts/test-install-sh.sh asserts this decodes to exactly the 32 bytes above.
RELEASE_SIGNING_SSH_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBH6AygZlfhaaVm6X/S0h/qENyaIYjJss/KviprFeITk"
# SSHSIG namespace and signer identity. Both must match what `release-cli` signs with: ssh-keygen
# refuses a signature made under a different namespace, and only a listed principal is trusted.
RELEASE_SIGNING_IDENTITY="varsafe-release@varsafe.dev"

# Verify the downloaded binary against the SIGNED release manifest.
#
# `checksums.txt` was never evidence: it is served by the same bucket and CDN as the binary, so
# whoever can replace one can replace the other, and this script would have cheerfully confirmed a
# trojan against its own checksum. The signature is what an attacker who controls the bucket cannot
# forge, and the manifest it covers is where the expected hash actually comes from.
#
# `varsafe update` has verified this way since cli-v6.0.1, and `release-cli` refuses to flip
# `latest` unless the published signature verifies — so every release a user can reach carries one.
# This closes the gap where the FIRST binary, the one that bootstraps that trust, was taken on faith.
#
# Fail-closed: a missing openssl, a missing signature, or a manifest that does not verify all abort
# the install rather than falling back to the unsigned path.
#
# Having `openssl` on PATH is NOT the same as being able to verify: stock macOS ships LibreSSL as
# /usr/bin/openssl, which has no Ed25519 EVP and no `pkeyutl -rawin`. Ask the tool what it can do.
openssl_can_verify_ed25519() {
  local public_key_pem="$1"
  command -v openssl &>/dev/null &&
    openssl pkey -pubin -in "$public_key_pem" -noout >/dev/null 2>&1 &&
    openssl pkeyutl -help 2>&1 | grep -q -- '-rawin'
}

# What this machine has, for whoever has to fix it. $1 is why SSHSIG produced no verdict:
# "missing" (release publishes none), "unsupported" (OpenSSH too old), "none".
describe_verifiers() {
  local sshsig_state="$1"
  if ! command -v ssh-keygen &>/dev/null; then
    echo "  ssh-keygen: not installed"
  elif [[ "$sshsig_state" == "unsupported" ]]; then
    echo "  ssh-keygen: $(command -v ssh-keygen) is older than SSHSIG (needs OpenSSH 8.1+)"
  elif [[ "$sshsig_state" == "missing" ]]; then
    echo "  ssh-keygen: $(command -v ssh-keygen), but this release publishes no SSHSIG signature"
  else
    echo "  ssh-keygen: $(command -v ssh-keygen)"
  fi
  if ! command -v openssl &>/dev/null; then
    echo "  openssl: not installed"
    return
  fi
  echo "  openssl: $(command -v openssl) reports \"$(openssl version 2>&1 | head -1)\", which cannot verify Ed25519 signatures (needs OpenSSL 3)"
}

verify_release() {
  local file="$1"
  local binary_name="$2"
  local version="$3"

  local workdir
  workdir="$(mktemp -d "${TMPDIR:-/tmp}/varsafe-verify.XXXXXX")" || {
    error "Could not create a temporary directory for signature verification"
  }

  # Do not capture these in command substitutions: shells strip terminal newlines from
  # substitution output, while an Ed25519 signature covers every manifest byte.
  if ! fetch "${RELEASES_URL}/v${version}/release.json" > "${workdir}/release.json" 2>/dev/null; then
    rm -rf "$workdir"
    error "Could not fetch release.json for v${version}; aborting install"
  fi
  if [[ ! -s "${workdir}/release.json" ]]; then
    rm -rf "$workdir"
    error "Empty release manifest for v${version}; aborting install"
  fi

  local tampered="Release signature verification FAILED for v${version}.\n\nThe manifest served by the CDN is not signed by the varsafe release key.\nThis is what a tampered download looks like. Refusing to install."
  # Why the SSHSIG path did not produce a verdict, for the diagnosis if nothing else can either:
  # "missing" (this release publishes none), "unsupported" (OpenSSH older than SSHSIG), "none".
  local verified=1 sshsig_state="missing"

  # SSHSIG first: it needs only OpenSSH, which a fresh machine already has. A release that
  # publishes no .sshsig (everything before cli-v7.2.32) falls through to the OpenSSL path; a
  # .sshsig that does NOT verify is a definitive refusal, never a reason to try another verifier.
  if command -v ssh-keygen &>/dev/null &&
    fetch "${RELEASES_URL}/v${version}/release.json.sshsig" > "${workdir}/release.json.sshsig" 2>/dev/null &&
    [[ -s "${workdir}/release.json.sshsig" ]]; then
    sshsig_state="none"
    printf '%s %s\n' "$RELEASE_SIGNING_IDENTITY" "$RELEASE_SIGNING_SSH_PUBLIC_KEY" \
      > "${workdir}/allowed_signers"
    local ssh_error
    if ssh_error=$(ssh-keygen -Y verify -f "${workdir}/allowed_signers" \
      -I "$RELEASE_SIGNING_IDENTITY" -n "$RELEASE_SIGNING_IDENTITY" \
      -s "${workdir}/release.json.sshsig" < "${workdir}/release.json" 2>&1 >/dev/null); then
      verified=0
    elif [[ "$ssh_error" == *"unknown option"* || "$ssh_error" == *"illegal option"* ]]; then
      # OpenSSH predating SSHSIG (before 8.1). That is a verifier this machine does not have, not
      # a verdict on the release: the raw signature below still decides.
      sshsig_state="unsupported"
    else
      rm -rf "$workdir"
      error "$tampered"
    fi
  fi

  if [[ "$verified" -ne 0 ]]; then
    # Assemble a PEM from the raw 32 bytes. An Ed25519 SubjectPublicKeyInfo is a fixed 12-byte
    # prefix plus the key; 12 is a multiple of 3, so the prefix base64-encodes to exactly 16
    # characters with no padding and simply concatenates. Pure text assembly — no xxd, no \xNN
    # escapes. Same construction as the release pipeline's own verification step.
    printf -- "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEA%s\n-----END PUBLIC KEY-----\n" \
      "$RELEASE_SIGNING_PUBLIC_KEY" > "${workdir}/pub.pem"

    # No capable verifier is NOT evidence of tampering, and saying so sent every stock-macOS user a
    # security warning about a release that was fine. Say what is missing, and install nothing.
    if ! openssl_can_verify_ed25519 "${workdir}/pub.pem"; then
      local diagnosis
      diagnosis="$(describe_verifiers "$sshsig_state")"
      rm -rf "$workdir"
      error "Cannot verify the release signature on this machine — nothing was installed.\n\n${diagnosis}\n\nInstall a verifier and re-run:\n  macOS:          OpenSSH 8.1+ (ships with 10.15+), or brew install openssl@3\n  Debian/Ubuntu:  apt install openssh-client   (or openssl)\n  Alpine:         apk add openssh-keygen       (or openssl)"
    fi

    if ! fetch "${RELEASES_URL}/v${version}/release.json.sig" > "${workdir}/sig.b64" 2>/dev/null ||
      [[ ! -s "${workdir}/sig.b64" ]]; then
      rm -rf "$workdir"
      error "Could not fetch release.json.sig for v${version}; aborting install"
    fi
    if openssl base64 -d -A -in "${workdir}/sig.b64" -out "${workdir}/sig.bin" >/dev/null 2>&1 &&
      openssl pkeyutl -verify -pubin -inkey "${workdir}/pub.pem" -rawin \
        -in "${workdir}/release.json" -sigfile "${workdir}/sig.bin" >/dev/null 2>&1; then
      verified=0
    fi
    if [[ "$verified" -ne 0 ]]; then
      rm -rf "$workdir"
      error "$tampered"
    fi
  fi

  # Only now is the manifest trustworthy enough to take a hash from.
  local expected
  expected=$(grep -o "\"${binary_name}\"[[:space:]]*:[[:space:]]*\"[0-9a-f]\{64\}\"" "${workdir}/release.json" |
    head -1 | grep -o '[0-9a-f]\{64\}')
  rm -rf "$workdir"
  if [[ -z "$expected" ]]; then
    error "The signed manifest for v${version} lists no checksum for ${binary_name}; aborting install"
  fi

  local actual
  actual=$(compute_sha256 "$file")

  if [[ "$actual" != "$expected" ]]; then
    error "Checksum mismatch for ${binary_name}!\n  Expected: ${expected}\n  Got:      ${actual}\n\nThe signed manifest and the downloaded binary disagree. Refusing to install."
  fi

  success "Signature and checksum verified"
}

# Which version to install: the pin if the caller set one, else whatever `latest` points at.
#
# VARSAFE_VERSION exists for two jobs the installer could not do before: reinstalling a known-good
# release after a bad one, and letting CI prove a just-published version installs BEFORE `latest`
# is flipped to it. The value becomes part of `${RELEASES_URL}/v<version>/<artifact>`, so it is
# validated as a version rather than pasted into a URL — a pin like `../..` would otherwise walk
# out of the release path and fetch something else entirely.
resolve_version() {
  if [[ -n "${VARSAFE_VERSION:-}" ]]; then
    if [[ ! "$VARSAFE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
      error "VARSAFE_VERSION is not a version: '${VARSAFE_VERSION}'.\n\nUse a released version such as VARSAFE_VERSION=7.2.32, or leave it unset to install the latest."
    fi
    printf '%s' "$VARSAFE_VERSION"
    return
  fi
  get_latest_version
}

# Get latest version from CDN
get_latest_version() {
  local version
  version=$(fetch "${RELEASES_URL}/latest/version.txt" 2>/dev/null) || {
    error "Could not fetch latest version from CDN"
  }
  echo "$version"
}

# Check if running interactively
is_interactive() {
  [[ -t 0 && -t 1 ]]
}

# Can we create (if needed) and actually write into "$1"? Probes with a real file
# rather than `test -w` — permission bits lie on NFS (root_squash), ACLs, and
# read-only mounts, and mkdir -p on an EXISTING unwritable dir succeeds silently.
dir_writable() {
  local dir="$1" probe
  mkdir -p "$dir" 2>/dev/null || return 1
  probe=$(mktemp "$dir/.varsafe-probe.XXXXXX" 2>/dev/null) || return 1
  rm -f "$probe"
  return 0
}

# A yes/no prompt that reaches the human through /dev/tty and NEVER assumes yes.
#
# Distinct from prompt_yes_no on both counts, deliberately: under the canonical
# `curl … | bash` invocation stdin is the script pipe, so `[[ -t 0 ]]` is false
# even though a person is right there — /dev/tty is how we reach them anyway.
# And when no terminal exists (CI), the answer is NO: prompt_yes_no's
# non-interactive yes-default is fine for cosmetic questions, but changing the
# install location is not a decision to assume on the user's behalf.
prompt_yes_no_tty() {
  local prompt="$1" response
  # The /dev/tty NODE always exists; only a process with a controlling terminal
  # can OPEN it. Probe the open quietly — a bare redirect would print the
  # shell's own "No such device or address" before our clean refusal.
  if ! { : < /dev/tty; } 2>/dev/null; then
    return 1
  fi
  echo -en "${CYAN}?${NC} $prompt ${GREEN}[y/N]${NC} " > /dev/tty
  # -t 60: a CI runner can allocate a PTY nobody is attached to; without a
  # timeout the read blocks the job forever. Timeout = no, same as no terminal.
  read -r -t 60 response < /dev/tty || return 1
  case "$response" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# Harden the default directory. chmod is skipped when the path is a symlink:
# chmod follows links, so a symlinked ~/.varsafe/bin pointing at a shared
# directory would have ITS TARGET locked to 700 — as root, that succeeds and
# locks everyone else out. Failure to chmod is a warning, not a failure: the
# install itself is still sound (ACLs can allow file creation but not chmod).
tighten_default_dir() {
  if [[ -L "$INSTALL_DIR" ]]; then
    warn "$INSTALL_DIR is a symlink; leaving its target's permissions unchanged"
    return 0
  fi
  chmod 700 "$INSTALL_DIR" 2>/dev/null || warn "Could not tighten permissions on $INSTALL_DIR"
}

# Resolve INSTALL_DIR to a directory we can write, BEFORE any network I/O.
#
# Policy: never install somewhere the user did not choose. A custom
# VARSAFE_INSTALL_DIR that cannot be written gets an EXPLICIT offer of the
# default (via /dev/tty) or a refusal with the fix — silently relocating a
# secrets binary is worse than failing.
ensure_install_dir() {
  if dir_writable "$INSTALL_DIR"; then
    if [[ "$INSTALL_DIR" == "$DEFAULT_INSTALL_DIR" ]]; then
      tighten_default_dir
    elif [[ -d "$INSTALL_DIR" && ! -L "$INSTALL_DIR" ]]; then
      # The user's choice stands, but a world-writable destination without the
      # sticky bit means anyone can replace the binary later — say so.
      local mode
      mode=$(stat -c '%a' "$INSTALL_DIR" 2>/dev/null || stat -f '%Lp' "$INSTALL_DIR" 2>/dev/null || echo "")
      if [[ "$mode" =~ [2367]$ ]] && [[ ! -k "$INSTALL_DIR" ]]; then
        warn "$INSTALL_DIR is world-writable without the sticky bit — any local user can replace binaries installed there"
      fi
    fi
    return 0
  fi

  if [[ "$INSTALL_DIR" == "$DEFAULT_INSTALL_DIR" ]]; then
    error "Cannot write to $INSTALL_DIR.
  Your home directory may be read-only. Set VARSAFE_INSTALL_DIR to a writable
  directory on your PATH and re-run this installer."
  fi

  warn "Cannot write to VARSAFE_INSTALL_DIR: $INSTALL_DIR"
  if prompt_yes_no_tty "Install to the default $DEFAULT_INSTALL_DIR instead?"; then
    INSTALL_DIR="$DEFAULT_INSTALL_DIR"
    dir_writable "$INSTALL_DIR" || error "Cannot write to $INSTALL_DIR either"
    tighten_default_dir
    return 0
  fi

  error "Cannot write to $INSTALL_DIR.
  Re-run with a writable VARSAFE_INSTALL_DIR, run with privileges that can write
  to $INSTALL_DIR, or unset VARSAFE_INSTALL_DIR to install to $DEFAULT_INSTALL_DIR."
}

# Prompt user for yes/no (defaults to yes)
prompt_yes_no() {
  local prompt="$1"
  local response

  if ! is_interactive; then
    return 0  # Default to yes in non-interactive mode
  fi

  echo -en "${CYAN}?${NC} $prompt ${GREEN}[Y/n]${NC} "
  read -r response
  case "$response" in
    [nN]|[nN][oO]) return 1 ;;
    *) return 0 ;;
  esac
}

# Get shell config file
get_shell_config() {
  local shell_name
  # No HOME (custom-dir install in a stripped container): there is no rc file
  # to edit — empty return routes configure_path to the manual instructions.
  if [[ -z "${HOME:-}" ]]; then
    echo ""
    return
  fi
  shell_name=$(basename "${SHELL:-/bin/bash}")

  case "$shell_name" in
    zsh)  echo "$HOME/.zshrc" ;;
    bash)
      # Prefer .bashrc, fall back to .bash_profile on macOS
      if [[ -f "$HOME/.bashrc" ]]; then
        echo "$HOME/.bashrc"
      elif [[ -f "$HOME/.bash_profile" ]]; then
        echo "$HOME/.bash_profile"
      else
        echo "$HOME/.bashrc"
      fi
      ;;
    fish) echo "$HOME/.config/fish/config.fish" ;;
    *)    echo "" ;;
  esac
}

# Configure PATH
configure_path() {
  local shell_name shell_rc
  shell_name=$(basename "${SHELL:-/bin/bash}")
  shell_rc=$(get_shell_config)

  # Check if already in PATH
  if command -v varsafe &>/dev/null; then
    local installed_path
    installed_path=$(command -v varsafe)
    if [[ "$installed_path" == "$INSTALL_DIR/varsafe" ]]; then
      success "varsafe is ready to use!"
      return 0
    else
      warn "Another varsafe found at: $installed_path"
      warn "The new installation at $INSTALL_DIR/varsafe may be shadowed"
    fi
  fi

  # Check if PATH is already configured in shell rc
  if [[ -n "$shell_rc" ]] && grep -qF ".varsafe/bin" "$shell_rc" 2>/dev/null; then
    info "PATH already configured in $shell_rc"
    print_reload_instructions "$shell_rc"
    return 0
  fi

  # Ask to add to PATH (or auto-add in non-interactive mode)
  if [[ -n "$shell_rc" ]]; then
    if prompt_yes_no "Add varsafe to PATH in $shell_rc?"; then
      add_to_shell_config "$shell_name" "$shell_rc"
      print_reload_instructions "$shell_rc"
    else
      print_manual_instructions "$shell_name"
    fi
  else
    print_manual_instructions "$shell_name"
  fi
}

# Add PATH config to shell rc file
add_to_shell_config() {
  local shell_name="$1"
  local shell_rc="$2"

  if [[ "$shell_name" == "fish" ]]; then
    mkdir -p "$(dirname "$shell_rc")"
    echo "" >> "$shell_rc"
    echo "# Varsafe CLI" >> "$shell_rc"
    echo "fish_add_path $INSTALL_DIR" >> "$shell_rc"
  else
    # The directory that was actually installed into — VARSAFE_INSTALL_DIR was previously ignored
    # here, so a custom install put a path on PATH that nothing had been written to. Keep it
    # $HOME-relative when it is under $HOME, so a synced rc file still works on another machine.
    local path_entry="$INSTALL_DIR"
    [[ "$INSTALL_DIR" == "$HOME/"* ]] && path_entry="\$HOME/${INSTALL_DIR#"$HOME"/}"
    echo "" >> "$shell_rc"
    echo "# Varsafe CLI" >> "$shell_rc"
    echo "export PATH=\"${path_entry}:\$PATH\"" >> "$shell_rc"
  fi
  success "Added varsafe to $shell_rc"
}

# Print reload instructions
print_reload_instructions() {
  local shell_rc="$1"

  echo ""
  echo -e "  ${GREEN}Almost there!${NC} To start using varsafe:"
  echo ""
  echo -e "  ${CYAN}Option 1:${NC} Reload your shell config"
  echo -e "           ${GREEN}source ${shell_rc}${NC}"
  echo ""
  echo -e "  ${CYAN}Option 2:${NC} Open a new terminal window"
  echo ""
}

# Print manual instructions when user declines auto-config
print_manual_instructions() {
  local shell_name="$1"

  echo ""
  echo -e "${YELLOW}To add varsafe to your PATH, run:${NC}"
  echo ""

  case "$shell_name" in
    zsh)
      echo -e "  ${GREEN}echo 'export PATH=\"\$HOME/.varsafe/bin:\$PATH\"' >> ~/.zshrc${NC}"
      echo -e "  ${GREEN}source ~/.zshrc${NC}"
      ;;
    bash)
      echo -e "  ${GREEN}echo 'export PATH=\"\$HOME/.varsafe/bin:\$PATH\"' >> ~/.bashrc${NC}"
      echo -e "  ${GREEN}source ~/.bashrc${NC}"
      ;;
    fish)
      echo -e "  ${GREEN}fish_add_path ~/.varsafe/bin${NC}"
      ;;
    *)
      echo -e "  ${GREEN}export PATH=\"\$HOME/.varsafe/bin:\$PATH\"${NC}"
      echo ""
      echo "  Add the above line to your shell config file."
      ;;
  esac
  echo ""
}

main() {
  echo ""
  echo "  Varsafe CLI Installer"
  echo ""

  local platform version binary_name download_url

  platform=$(detect_platform)
  info "Detected platform: $platform"

  # Fail on an unwritable destination BEFORE fetching anything — same contract
  # as `varsafe update`, which probes its install directory before downloading.
  ensure_install_dir

  # Cheap early exit so we do not download 90 MB we already know cannot run. Authoritative
  # check is smoke_test_binary, after the download.
  case "$platform" in
    *-musl)
      if ! musl_prereqs_present && ! install_musl_prereqs; then
        error "$(musl_prereq_help)"
      fi
      ;;
  esac

  version=$(resolve_version)
  if [[ -z "$version" ]]; then
    error "Could not determine latest version"
  fi
  if [[ -n "${VARSAFE_VERSION:-}" ]]; then
    info "Pinned version: v$version"
  else
    info "Latest version: v$version"
  fi

  binary_name="varsafe-${platform}"
  download_url="${RELEASES_URL}/v${version}/${binary_name}"

  # Download binary (directory writability and permissions were settled by
  # ensure_install_dir before any network I/O)
  info "Downloading ${binary_name}..."
  local tmp_binary
  tmp_binary="$(mktemp "${INSTALL_DIR}/.varsafe.XXXXXX")"
  trap 'rm -f "$tmp_binary"' EXIT

  if ! download "$download_url" "$tmp_binary"; then
    error "Failed to download from CDN"
  fi

  # Verify the signed manifest, then the binary's hash against it
  verify_release "$tmp_binary" "$binary_name" "$version"

  chmod 755 "$tmp_binary"

  # Prove it runs BEFORE putting it on PATH. Verified bytes are not the same as a usable binary.
  smoke_test_binary "$tmp_binary" "$platform"

  mv "$tmp_binary" "$INSTALL_DIR/varsafe"
  trap - EXIT

  success "Installed varsafe to $INSTALL_DIR/varsafe"

  # Configure PATH
  configure_path

  # Verify installation
  if [[ -x "$INSTALL_DIR/varsafe" ]]; then
    local installed_version
    installed_version=$("$INSTALL_DIR/varsafe" --version 2>/dev/null || echo "unknown")
    success "Installed varsafe $installed_version"
  fi

  echo ""
  echo "  Get started:"
  echo "    varsafe login"
  echo "    varsafe --help"
  echo ""
}

# Sourceable for tests: scripts/test-install-sh.sh sources this file to exercise
# ensure_install_dir and friends without performing a real install.
#
# The probe below asks bash directly "am I being sourced?": `return` is only
# legal in a source context, and the subshell keeps the answer side-effect
# free. Every executed shape — curl|bash (stdin), bash -c "$(curl …)",
# bash install.sh — runs main; only genuine sourcing skips it.
#
# Deliberately NOT a ${BASH_SOURCE[0]} comparison: that variable is UNSET on
# piped stdin, and under set -u the bare reference ABORTED the whole script on
# this line — v2026-07-30 briefly shipped an installer that died in exactly
# the flow the docs advertise. A name comparison can also be spoofed into
# running main from a sourced context (bash -c 'source ./install.sh' ./install.sh).
if ! (return 0 2>/dev/null); then
  main "$@"
fi

# varsafe-installer-end
