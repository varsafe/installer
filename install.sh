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
    # No --retry here, unlike every other download below: a retried transfer is appended to
    # whatever the failed attempt already wrote to stdout, and that concatenation would run.
    # wget is for hosts without curl — stock Alpine has only BusyBox's.
    if command -v curl >/dev/null 2>&1; then
      _varsafe_dl=curl
      _varsafe_src=$(curl -q -fsSL --proto '=https' https://varsafe.dev/install.sh)
    elif command -v wget >/dev/null 2>&1; then
      _varsafe_dl=wget
      _varsafe_src=$(wget -qO- https://varsafe.dev/install.sh)
    else
      echo "error  this installer needs curl or wget to download itself." >&2
      exit 1
    fi
    _varsafe_rc=$?
    if [ "$_varsafe_rc" -ne 0 ]; then
      echo "error  could not download the installer ($_varsafe_dl exit $_varsafe_rc)." >&2
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

# Scratch space for the release manifest and its signatures, and the binary while it downloads.
# Set by main; both are removed on every exit — success, refusal or Ctrl-C — so a failed install
# leaves nothing behind for the next one to trip over.
WORK_DIR=""
TMP_BINARY=""
cleanup() {
  if [[ -n "$TMP_BINARY" ]]; then rm -f "$TMP_BINARY"; fi
  if [[ -n "$WORK_DIR" ]]; then rm -rf "$WORK_DIR"; fi
}

# Colour only for a person at a terminal: CI logs and redirected output get plain text instead of
# escape codes, and NO_COLOR (https://no-color.org) turns it off everywhere.
if [[ -t 1 && -t 2 && -z "${NO_COLOR:-}" ]]; then
  RED=$'\033[0;31m' GREEN=$'\033[0;32m' YELLOW=$'\033[1;33m' CYAN=$'\033[0;36m' NC=$'\033[0m'
else
  RED='' GREEN='' YELLOW='' CYAN='' NC=''
fi

# printf, never `echo -e`: macOS's /bin/sh is bash in POSIX mode, whose echo takes no options and
# prints a literal "-e" — and `curl … | sh` runs there without the re-exec, BASH_VERSION being set.
#
# Warnings and errors go to STDERR. Callers such as `platform=$(detect_platform)` capture stdout,
# so an error printed there was swallowed into the variable and the installer exited 1 having said
# nothing at all — on its most common failure, the release server being unreachable.
info() { printf '%sinfo%s  %s\n' "$CYAN" "$NC" "$1"; }
success() { printf '%ssuccess%s  %s\n' "$GREEN" "$NC" "$1"; }
warn() { printf '%swarn%s  %s\n' "$YELLOW" "$NC" "$1" >&2; }
error() { printf '%serror%s  %s\n' "$RED" "$NC" "$1" >&2; exit 1; }

# Last resort for is_musl, when no C library answered: does the filesystem look like a musl
# system? Not evidence on its own — see is_musl.
musl_filesystem() {
  [ -f /etc/alpine-release ] || [ -e /lib/ld-musl-x86_64.so.1 ] || [ -e /lib/ld-musl-aarch64.so.1 ]
}

# Detect whether the Linux C library is musl (Alpine and friends) rather than glibc.
# The two are NOT binary-compatible: a glibc binary aborts on a musl-only system before it
# can even reach the keychain loader, so we ship a dedicated musl artifact.
#
# The answer is permanent: `varsafe update` keeps the flavour of the binary it runs as, so the
# first install's choice is the one that host keeps. Ask the C library itself first.
# - glibc's getconf answers GNU_LIBC_VERSION ("glibc 2.36"); musl's does not know the variable.
#   This comes before any file probe because a loader on disk proves nothing: Debian, Ubuntu and
#   Arch all package musl (Rust developers install it to build static binaries), which puts
#   /lib/ld-musl-x86_64.so.1 on a glibc system — and the musl build cannot start there.
# - ldd names its libc. Capture FIRST, match second: musl's ldd exits non-zero for `--version`
#   (it prints "musl libc (x86_64)" and returns 1), and under `set -o pipefail` a piped probe read
#   that as failure, answering "glibc" on every host the probe was meant to catch.
is_musl() {
  local probe
  probe=$(getconf GNU_LIBC_VERSION 2>/dev/null || true)
  case "$probe" in
    glibc\ [0-9]*) return 1 ;;
  esac
  if command -v ldd >/dev/null 2>&1; then
    probe=$(ldd --version 2>&1 || true)
    case "$probe" in
      *musl*) return 0 ;;
      *GNU*|*GLIBC*) return 1 ;;
    esac
  fi
  musl_filesystem
}

# Detect platform
detect_platform() {
  local os arch

  case "$(uname -s)" in
    Linux*)  os="linux" ;;
    Darwin*) os="darwin" ;;
    MINGW*|MSYS*|CYGWIN*) error "Unsupported OS: $(uname -s). On Windows, run this installer inside WSL." ;;
    *)       error "Unsupported OS: $(uname -s)" ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64) arch="x64" ;;
    arm64|aarch64) arch="arm64" ;;
    *)            error "Unsupported architecture: $(uname -m)" ;;
  esac

  # A terminal running under Rosetta 2 reports x86_64 on Apple silicon. The x64 build would run
  # there translated, and stay: `varsafe update` picks by the architecture it runs as.
  if [[ "$os" == "darwin" && "$arch" == "x64" ]] &&
    [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" == "1" ]]; then
    arch="arm64"
  fi

  # Every Linux arch ships separate glibc and musl builds; pick by detected libc. Must stay in
  # lockstep with releaseArtifactName() in packages/cli/src/shared/domain/release-target.ts —
  # this picks the FIRST install, that one names the artifact for every `varsafe update`
  # afterwards, and a disagreement means an update fetches a build the host cannot run.
  if [[ "$os" == "linux" ]] && is_musl; then
    echo "linux-${arch}-musl"
    return
  fi

  echo "${os}-${arch}"
}

# varsafe's x64 builds need an x86-64-v2 CPU — SSSE3, SSE4.1, SSE4.2, POPCNT, which every Intel and
# AMD CPU since about 2010 has. Without one the binary crashes on start (SIGILL, or SIGSEGV for a
# missing SSE4.2): what a VM on the bare qemu64/kvm64 CPU model shows. Used only to EXPLAIN such a
# crash, never to refuse up front: cpuinfo is an inventory, and a container can show a filtered one
# on a CPU that runs varsafe fine. Whether the binary runs is the smoke test's verdict.
x64_cpu_supported() {
  local flags flag
  flags=$(grep -m1 '^flags' "$1" 2>/dev/null) || return 0
  for flag in ssse3 sse4_1 sse4_2 popcnt; do
    case " $flags " in *" $flag "*) ;; *) return 1 ;; esac
  done
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
      if grep -qiE "libstdc\+\+|libgcc|shared library|symbol not found" <<<"$out"; then
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
  if [[ $status -eq 126 ]] || grep -qi "permission denied" <<<"$out"; then
    error "The downloaded binary could not be executed:
$(echo "$out" | sed 's/^/    /')

  The filesystem at $INSTALL_DIR may be mounted noexec. Set VARSAFE_INSTALL_DIR
  to a directory on an exec-capable filesystem and re-run this installer."
  fi

  # The status is a hint, not a diagnosis: a program can return any code. 127 is what the shell
  # reports when the kernel cannot even start the file — its loader is missing.
  local hint=""
  [[ $status -eq 127 ]] && hint="Possible cause: this system cannot load ${platform} binaries, e.g. a 32-bit OS on a 64-bit CPU (uname -m: $(uname -m))."
  [[ $status -gt 128 ]] && hint="It was killed by signal $((status - 128))."
  if [[ $status -gt 128 && "$platform" == linux-x64* ]] && ! x64_cpu_supported /proc/cpuinfo; then
    hint="$hint This CPU lacks the x86-64-v2 instructions varsafe's x64 build needs (SSSE3, SSE4.1, SSE4.2, POPCNT).
  On a virtual machine, set a CPU type of x86-64-v2 or newer, or host, instead of qemu64/kvm64."
  fi
  error "The downloaded binary did not run on this system:
$(echo "$out" | sed 's/^/    /')
  ${hint}"
}

# Every transfer, with one policy:
#   -q (first)       ~/.curlrc cannot alter or redirect what is downloaded (see the re-exec above).
#   --proto =https   a redirect can never downgrade to plain HTTP.
#   --retry 3        transient failures (timeouts, resets, 5xx) are retried...
#   -o FILE          ...which is only safe into a file curl owns: curl truncates it before a retry,
#                    while a body already written to a pipe or a shell redirect stays, and the
#                    retried one is appended to it — a signature failure that reads as tampering.
#   --speed-*        a stalled connection fails after a minute instead of hanging forever.
# No --tlsv1.2: curl before 7.34 (RHEL 7, whose glibc can run varsafe) rejects the option, and
# nothing rests on the TLS version — the release signature is what makes a download trustworthy.
# A third argument shows a progress bar, when there is a terminal to draw it on.
download() {
  local url="$1" dest="$2" progress="${3:-}"
  if command -v curl >/dev/null 2>&1; then
    local display="-sS"
    if [[ -n "$progress" && -t 2 ]]; then display="--progress-bar"; fi
    curl -q --proto '=https' -fL "$display" --retry 3 --connect-timeout 20 \
      --speed-limit 1 --speed-time 60 -o "$dest" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 60 -O "$dest" "$url"
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

# Having `openssl` on PATH is NOT the same as being able to verify: stock macOS ships LibreSSL as
# /usr/bin/openssl, which has no Ed25519 EVP and no `pkeyutl -rawin`, and neither does OpenSSL
# 1.1.1 (RHEL 8, Ubuntu 20.04). Ask the tool what it can do. $1 is the binary to ask: EPEL's
# OpenSSL 3 for the RHEL 8 family installs as `openssl3`, beside the system's 1.1.1 `openssl`.
openssl_can_verify_ed25519() {
  local openssl_bin="$1" public_key_pem="$2" help
  command -v "$openssl_bin" &>/dev/null || return 1
  "$openssl_bin" pkey -pubin -in "$public_key_pem" -noout >/dev/null 2>&1 || return 1
  # Captured, then matched: `pkeyutl -help` exits non-zero on some builds, which a pipeline
  # under pipefail would report as "cannot verify" even when the option is listed.
  help=$("$openssl_bin" pkeyutl -help 2>&1 || true)
  [[ "$help" == *-rawin* ]]
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

# Verify the SIGNED release manifest for version $2 and set EXPECTED_SHA256 to the checksum it lists
# for artifact $1 — BEFORE the binary is downloaded. A machine that cannot verify, a pinned version
# that does not exist and a manifest that does not verify all stop here, instead of after 90 MB was
# fetched for nothing. Same order as `varsafe update`.
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
# Fail-closed: no capable verifier, a missing signature, or a manifest that does not verify all
# abort the install rather than falling back to the unsigned path.
EXPECTED_SHA256=""
verify_manifest() {
  local binary_name="$1" version="$2"
  local manifest="${WORK_DIR}/release.json"

  # Downloaded to a file and verified from it, never captured in a command substitution: shells
  # strip trailing newlines from substitution output, while an Ed25519 signature covers every byte.
  if ! download "${RELEASES_URL}/v${version}/release.json" "$manifest" || [[ ! -s "$manifest" ]]; then
    error "Could not fetch the release manifest for v${version}; nothing was installed.
  If you set VARSAFE_VERSION, check that ${version} is a published release."
  fi

  local tampered="Release signature verification FAILED for v${version}.

The manifest served by the CDN is not signed by the varsafe release key.
This is what a tampered download looks like. Refusing to install."
  # Why the SSHSIG path did not produce a verdict, for the diagnosis if nothing else can either:
  # "missing" (this release publishes none), "unsupported" (OpenSSH older than SSHSIG), "none".
  local verified=1 sshsig_state="missing"

  # SSHSIG first: it needs only OpenSSH, which a fresh machine already has. A release that
  # publishes no .sshsig (everything before cli-v7.2.32) falls through to the OpenSSL path; a
  # .sshsig that does NOT verify is a definitive refusal, never a reason to try another verifier.
  if command -v ssh-keygen &>/dev/null &&
    download "${RELEASES_URL}/v${version}/release.json.sshsig" "${WORK_DIR}/release.json.sshsig" 2>/dev/null &&
    [[ -s "${WORK_DIR}/release.json.sshsig" ]]; then
    sshsig_state="none"
    printf '%s %s\n' "$RELEASE_SIGNING_IDENTITY" "$RELEASE_SIGNING_SSH_PUBLIC_KEY" \
      > "${WORK_DIR}/allowed_signers"
    local ssh_error
    if ssh_error=$(ssh-keygen -Y verify -f "${WORK_DIR}/allowed_signers" \
      -I "$RELEASE_SIGNING_IDENTITY" -n "$RELEASE_SIGNING_IDENTITY" \
      -s "${WORK_DIR}/release.json.sshsig" < "$manifest" 2>&1 >/dev/null); then
      verified=0
    elif [[ "$ssh_error" == *"unknown option"* || "$ssh_error" == *"illegal option"* ]]; then
      # OpenSSH predating SSHSIG (before 8.1). That is a verifier this machine does not have, not
      # a verdict on the release: the raw signature below still decides.
      sshsig_state="unsupported"
    else
      error "$tampered"
    fi
  fi

  if [[ "$verified" -ne 0 ]]; then
    # Assemble a PEM from the raw 32 bytes. An Ed25519 SubjectPublicKeyInfo is a fixed 12-byte
    # prefix plus the key; 12 is a multiple of 3, so the prefix base64-encodes to exactly 16
    # characters with no padding and simply concatenates. Pure text assembly — no xxd, no \xNN
    # escapes. Same construction as the release pipeline's own verification step.
    printf -- "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEA%s\n-----END PUBLIC KEY-----\n" \
      "$RELEASE_SIGNING_PUBLIC_KEY" > "${WORK_DIR}/pub.pem"

    local openssl_bin="" candidate
    for candidate in openssl openssl3; do
      openssl_can_verify_ed25519 "$candidate" "${WORK_DIR}/pub.pem" && { openssl_bin="$candidate"; break; }
    done

    # No capable verifier is NOT evidence of tampering, and saying so sent every stock-macOS user a
    # security warning about a release that was fine. Say what is missing, and install nothing.
    if [[ -z "$openssl_bin" ]]; then
      error "Cannot verify the release signature on this machine — nothing was installed.

$(describe_verifiers "$sshsig_state")

Install a verifier and re-run:
  macOS:              OpenSSH 8.1+ (ships with 10.15+), or OpenSSL 3 first on PATH
  Debian/Ubuntu:      apt install openssh-client     (or openssl)
  Fedora/RHEL 9+:     dnf install openssh            (or openssl)
  RHEL/Rocky/Alma 8:  dnf install epel-release && dnf install openssl3
  Alpine:             apk add openssh-keygen         (or openssl)"
    fi

    if ! download "${RELEASES_URL}/v${version}/release.json.sig" "${WORK_DIR}/sig.b64" ||
      [[ ! -s "${WORK_DIR}/sig.b64" ]]; then
      error "Could not fetch release.json.sig for v${version}; nothing was installed."
    fi
    if "$openssl_bin" base64 -d -A -in "${WORK_DIR}/sig.b64" -out "${WORK_DIR}/sig.bin" >/dev/null 2>&1 &&
      "$openssl_bin" pkeyutl -verify -pubin -inkey "${WORK_DIR}/pub.pem" -rawin \
        -in "$manifest" -sigfile "${WORK_DIR}/sig.bin" >/dev/null 2>&1; then
      verified=0
    fi
    if [[ "$verified" -ne 0 ]]; then
      error "$tampered"
    fi
  fi

  # Only now is the manifest trustworthy enough to read. Reading it whole is safe at this point:
  # its bytes are verified, and a lost trailing newline changes no value. Matched with bash regexes
  # rather than grep pipelines, whose early exit under pipefail aborted the script without a word.
  local content signed_version="" version_re checksum_re
  content=$(cat "$manifest")
  version_re='"version"[[:space:]]*:[[:space:]]*"([^"]*)"'
  if [[ "$content" =~ $version_re ]]; then signed_version="${BASH_REMATCH[1]}"; fi
  # The signature proves varsafe published this manifest, not that it belongs to the version
  # requested: version.txt and the path are unsigned, so whoever controls the CDN could serve an
  # older, genuinely signed release under a newer path. The signed version binds them, as it does
  # for `varsafe update`. (Nothing here can stop an older release being named as latest.)
  if [[ "$signed_version" != "$version" ]]; then
    error "The signed manifest served for v${version} is for version '${signed_version}'. Refusing to install it."
  fi

  checksum_re="\"${binary_name}\"[[:space:]]*:[[:space:]]*\"([0-9a-f]{64})\""
  EXPECTED_SHA256=""
  if [[ "$content" =~ $checksum_re ]]; then EXPECTED_SHA256="${BASH_REMATCH[1]}"; fi
  if [[ -z "$EXPECTED_SHA256" ]]; then
    error "The signed manifest for v${version} lists no checksum for ${binary_name}; nothing was installed."
  fi
}

# A release version as published: 7.2.32, or a prerelease such as 8.0.0-rc.1. It becomes part of
# `${RELEASES_URL}/v<version>/<artifact>`, so it is validated rather than pasted into a URL — a
# value like `../..` would otherwise walk out of the release path and fetch something else entirely.
is_version() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]
}

# Which version to install: the pin if the caller set one, else whatever `latest` points at.
#
# VARSAFE_VERSION exists for two jobs the installer could not do before: reinstalling a known-good
# release after a bad one, and letting CI prove a just-published version installs BEFORE `latest`
# is flipped to it. What `latest` names is checked the same way: a proxy or portal answering in its
# place would otherwise turn into a confusing download failure.
resolve_version() {
  local version
  if [[ -n "${VARSAFE_VERSION:-}" ]]; then
    if ! is_version "$VARSAFE_VERSION"; then
      error "VARSAFE_VERSION is not a version: '${VARSAFE_VERSION}'.

Use a released version such as VARSAFE_VERSION=7.2.32 (no leading v), or leave it unset to install the latest."
    fi
    printf '%s' "$VARSAFE_VERSION"
    return
  fi
  if ! download "${RELEASES_URL}/latest/version.txt" "${WORK_DIR}/version.txt"; then
    error "Could not fetch the latest version from ${RELEASES_URL}/latest/version.txt.
  Check your connection or proxy, then re-run this installer."
  fi
  version=$(tr -d '[:space:]' < "${WORK_DIR}/version.txt")
  if ! is_version "$version"; then
    error "${RELEASES_URL}/latest/version.txt did not return a version (got '$(printf '%s' "$version" | head -c 40)').
  A proxy or captive portal may be answering instead of the release server."
  fi
  printf '%s' "$version"
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
  printf '%s?%s %s %s[y/N]%s ' "$CYAN" "$NC" "$prompt" "$GREEN" "$NC" > /dev/tty
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
  # The directory ends up on PATH, through a line in a shell rc file, so it must be one PATH can
  # hold. Absolute: a relative entry is resolved against whatever directory the shell is in, so
  # commands would be looked up in every directory the user cds into. No ':', PATH's separator,
  # which no quoting protects. And none of the characters a double-quoted rc line would expand or
  # end on — the rc file is shell code, run at every login.
  case "$INSTALL_DIR" in
    *[\"\$\`\\:]*|*"
"*) error "The install directory '$INSTALL_DIR' cannot be put on PATH: it contains one of : \" \$ \` \\ or a newline. Choose another with VARSAFE_INSTALL_DIR." ;;
    /*) ;;
    *) error "The install directory must be an absolute path, not '$INSTALL_DIR'. Set VARSAFE_INSTALL_DIR to a full path, e.g. \$HOME/bin." ;;
  esac

  # `curl … | sudo bash` keeps the invoking user's HOME on macOS, whose sudoers keeps it, and under
  # `sudo -E`: root would create a root-owned 0700 ~/.varsafe/bin inside that user's home, which the
  # user can neither enter nor update, and edit their shell rc as root. Keyed on sudo/doas having
  # run us, not on ownership alone: CI containers commonly run as root with a HOME someone else owns.
  if [[ "$INSTALL_DIR" == "$DEFAULT_INSTALL_DIR" && "$(id -u)" -eq 0 && -n "${SUDO_USER:-}${DOAS_USER:-}" ]] &&
    [[ -d "$HOME" && ! -O "$HOME" ]]; then
    error "Run this installer without sudo: it installs varsafe for your own user, in ~/.varsafe/bin.
  To install for every user instead, choose a system directory explicitly:
      curl -fsSL https://varsafe.dev/install.sh | sudo VARSAFE_INSTALL_DIR=/usr/local/bin bash"
  fi

  # ~/.varsafe is the CLI's own directory, kept 0700 because it holds the credential store — but
  # only once the CLI first opens it. Created here with the umask's permissions, it let anyone in a
  # shared group swap the directory holding the binary before varsafe ever ran. `mkdir -m` creates
  # it private in one step and leaves anything already there alone, a symlink included: nothing is
  # chmodded through a path that could be swapped between a check and the change. HOME first, so a
  # HOME that does not exist yet does not leave it to the umask-mode `mkdir -p` below.
  if [[ "$INSTALL_DIR" == "$DEFAULT_INSTALL_DIR" ]]; then
    local varsafe_home
    varsafe_home=$(dirname "$INSTALL_DIR")
    mkdir -p "$(dirname "$varsafe_home")" 2>/dev/null || true
    mkdir -m 700 "$varsafe_home" 2>/dev/null || true
  fi

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

  if [[ ! -t 0 || ! -t 1 ]]; then
    return 0  # Default to yes in non-interactive mode
  fi

  printf '%s?%s %s %s[Y/n]%s ' "$CYAN" "$NC" "$prompt" "$GREEN" "$NC"
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
    # zsh reads its rc files from ZDOTDIR when that is set.
    zsh)  echo "${ZDOTDIR:-$HOME}/.zshrc" ;;
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

# The rc-file line that puts INSTALL_DIR on PATH, for shell $1 — the directory actually installed
# into. A directory under $HOME is written $HOME-relative, so a synced rc file still works on a
# machine whose home directory has a different path. Quoting is safe: ensure_install_dir refused
# every character a double-quoted string would interpret.
path_line() {
  local shell_name="$1" entry="$INSTALL_DIR"
  if [[ "$shell_name" == "fish" ]]; then
    printf 'fish_add_path "%s"\n' "$INSTALL_DIR"
    return
  fi
  if [[ -n "${HOME:-}" && "$INSTALL_DIR" == "$HOME/"* ]]; then
    entry="\$HOME/${INSTALL_DIR#"$HOME"/}"
  fi
  printf 'export PATH="%s:$PATH"\n' "$entry"
}

# Does rc file $1 already put INSTALL_DIR on PATH for shell $2? An uncommented line must be the one
# this installer writes (or the unquoted fish line earlier versions wrote) — or, for the default
# directory, which people also add by hand, name it as a whole PATH entry: absolutely, or as
# $HOME/…, ${HOME}/… or ~/…. Never a bare substring: keyed on the default, every re-run with a
# custom VARSAFE_INSTALL_DIR appended another line, and keyed on part of the path, $HOME/bin
# matched /usr/local/bin and was left off PATH.
rc_has_install_dir() {
  local rc="$1" shell_name="$2" lines words
  lines=$(grep -v '^[[:space:]]*#' "$rc" 2>/dev/null || true)
  if grep -qxF -e "$(path_line "$shell_name")" -e "fish_add_path $INSTALL_DIR" <<<"$lines"; then
    return 0
  fi
  [[ "$INSTALL_DIR" == "$DEFAULT_INSTALL_DIR" ]] || return 1
  # Split at the characters that delimit a PATH entry, so only a whole entry can match.
  words=$(tr '=:"'"'"'()[:space:]' '\n' <<<"$lines")
  local prefix spellings=(-e "$INSTALL_DIR")
  for prefix in '$HOME' '${HOME}' '~'; do spellings+=(-e "$prefix/.varsafe/bin"); done
  grep -qxF "${spellings[@]}" <<<"$words"
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

  if [[ -n "$shell_rc" ]] && rc_has_install_dir "$shell_rc" "$shell_name"; then
    info "PATH already configured in $shell_rc"
    print_reload_instructions "$shell_rc"
    return 0
  fi

  # Ask to add to PATH (or auto-add in non-interactive mode)
  if [[ -n "$shell_rc" ]] && prompt_yes_no "Add varsafe to PATH in $shell_rc?"; then
    add_to_shell_config "$shell_name" "$shell_rc"
    print_reload_instructions "$shell_rc"
  else
    print_manual_instructions "$shell_name" "$shell_rc"
  fi
}

# Add PATH config to shell rc file
add_to_shell_config() {
  local shell_name="$1"
  local shell_rc="$2"

  mkdir -p "$(dirname "$shell_rc")"
  printf '\n# Varsafe CLI\n%s\n' "$(path_line "$shell_name")" >> "$shell_rc"
  success "Added varsafe to $shell_rc"
}

# Print reload instructions
print_reload_instructions() {
  local shell_rc="$1"

  echo ""
  printf '  %sAlmost there!%s To start using varsafe:\n\n' "$GREEN" "$NC"
  printf '  %sOption 1:%s Reload your shell config\n' "$CYAN" "$NC"
  printf '           %ssource %s%s\n\n' "$GREEN" "$shell_rc" "$NC"
  printf '  %sOption 2:%s Open a new terminal window\n\n' "$CYAN" "$NC"
}

# Print manual instructions when user declines auto-config, or the shell is one we do not edit.
# The line names the directory actually installed into, not the default.
print_manual_instructions() {
  local shell_name="$1" shell_rc="$2"

  echo ""
  printf '%sTo add varsafe to your PATH, add this line to %s:%s\n\n' \
    "$YELLOW" "${shell_rc:-your shell config file}" "$NC"
  printf '  %s%s%s\n\n' "$GREEN" "$(path_line "$shell_name")" "$NC"
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

  # The download can only be checked with a SHA-256 tool: find out now, not after fetching 90 MB.
  compute_sha256 /dev/null >/dev/null

  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/varsafe-install.XXXXXX")" ||
    error "Could not create a temporary directory in ${TMPDIR:-/tmp}"
  trap cleanup EXIT

  version=$(resolve_version)
  if [[ -n "${VARSAFE_VERSION:-}" ]]; then
    info "Pinned version: v$version"
  else
    info "Latest version: v$version"
  fi

  binary_name="varsafe-${platform}"
  download_url="${RELEASES_URL}/v${version}/${binary_name}"

  # The signed manifest first: it decides whether this machine can verify the release at all, and
  # whether the version exists, before the binary is fetched.
  verify_manifest "$binary_name" "$version"

  # Directory writability and permissions were settled by ensure_install_dir before any network
  # I/O. The binary lands in a temporary file beside its destination, so the final mv is a rename.
  info "Downloading ${binary_name}..."
  TMP_BINARY="$(mktemp "${INSTALL_DIR}/.varsafe.XXXXXX")"
  if ! download "$download_url" "$TMP_BINARY" progress; then
    error "Failed to download ${download_url}"
  fi

  local actual
  actual=$(compute_sha256 "$TMP_BINARY")
  if [[ "$actual" != "$EXPECTED_SHA256" ]]; then
    error "Checksum mismatch for ${binary_name}!
  Expected: ${EXPECTED_SHA256}
  Got:      ${actual}

The signed manifest and the downloaded binary disagree. Refusing to install."
  fi
  success "Signature and checksum verified"

  chmod 755 "$TMP_BINARY"

  # Prove it runs BEFORE putting it on PATH. Verified bytes are not the same as a usable binary.
  smoke_test_binary "$TMP_BINARY" "$platform"

  mv "$TMP_BINARY" "$INSTALL_DIR/varsafe"
  TMP_BINARY=""

  local installed_version
  installed_version=$("$INSTALL_DIR/varsafe" --version 2>/dev/null || echo "$version")
  success "Installed varsafe ${installed_version} to $INSTALL_DIR/varsafe"

  configure_path

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
