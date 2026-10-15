#!/bin/bash
# Regression tests for install.sh's destination handling. Sources the installer
# (guarded main) and exercises ensure_install_dir & friends against real
# directories under a private tmpdir — no network, no real install.
#
# Run: bash scripts/test-install-sh.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# uid 0 bypasses DAC, so every "unwritable directory" scenario below silently stops testing
# what it claims to: root writes to a 0500 dir happily and the installer's refusal path is
# never reached. Run as root the suite reports 5 false failures — which reads as a broken
# installer rather than a broken harness. CI images commonly run as root, so drop privileges
# instead of reporting a result that does not mean what it says.
if [[ "${EUID:-$(id -u)}" -eq 0 && -z "${INSTALLER_TESTS_DROPPED_PRIVS:-}" ]]; then
  export INSTALLER_TESTS_DROPPED_PRIVS=1
  # Deliberately NOT chmod-ing the checkout: widening its permissions to satisfy a test would
  # persist after the run and, on a shared runner, expose whatever else the checkout holds.
  # Resolve nobody's uid/gid NUMERICALLY. `--regid=nogroup` is not portable: the group nobody
  # belongs to is `nogroup` on Debian, `nobody` on RHEL/Alpine, and absent entirely on some
  # minimal images — setpriv then dies with "failed to parse regid" and takes the suite with
  # it, because this is an exec. Numeric ids always parse.
  nobody_uid="$(id -u nobody 2>/dev/null || true)"
  nobody_gid="$(id -g nobody 2>/dev/null || true)"
  if command -v setpriv >/dev/null 2>&1 && [[ -n "$nobody_uid" && -n "$nobody_gid" ]]; then
    echo "note: running as root; re-executing as nobody (root cannot exercise the refusal paths)"
    exec setpriv --reuid="$nobody_uid" --regid="$nobody_gid" --clear-groups \
      env HOME=/tmp "$0" "$@"
  elif command -v su >/dev/null 2>&1 && id nobody >/dev/null 2>&1; then
    echo "note: running as root; re-executing as nobody (root cannot exercise the refusal paths)"
    exec su -s /bin/bash nobody -c "HOME=/tmp $(printf '%q' "$0")"
  fi
  echo "error  this suite must not run as root, and privileges could not be dropped." >&2
  echo "       Install util-linux (setpriv) or run it as an unprivileged user." >&2
  exit 1
fi

# The work dir must be EXEC-capable, not merely writable.
#
# This suite plants fake `curl` and `bash` on PATH and asserts whether install.sh reached them. On
# a runner that mounts the tmpdir `noexec` — this repo's desktop runner does — every one of those
# execs fails, and the suite reports three failures that describe the MOUNT while naming install.sh:
# "failed fetch names curl's exit status", "truncated body says truncated", and, worst, the positive
# control whose entire job is to prove the checks can fail. That is the same class of false report
# the root-privilege guard above exists to prevent, so handle it the same way: find a directory that
# actually works, and refuse to run rather than produce a result that does not mean what it says.
#
# Verified by EXECUTING a probe, not by inspecting mount flags: /proc/mounts does not resolve
# bind-mounts and overlays reliably, and the property being asserted is "can I run a file here".
exec_capable() {
  local dir="$1" probe rc
  [[ -d "$dir" && -w "$dir" ]] || return 1
  probe="$(mktemp -d "$dir/varsafe-execprobe.XXXXXX" 2>/dev/null)" || return 1
  printf '#!/bin/sh\nexit 0\n' > "$probe/probe" 2>/dev/null \
    && chmod +x "$probe/probe" 2>/dev/null \
    && "$probe/probe" 2>/dev/null
  rc=$?
  rm -rf "$probe"
  return $rc
}

WORK=""
# $HOME is /tmp on the privilege-dropped path above, so it is a candidate rather than a fallback.
# Every expansion is guarded: `set -u` is on, and this suite has a scenario for an UNSET HOME —
# a bare "$HOME" here would abort with an unbound-variable error before that scenario ever ran,
# which is the very failure mode the scenario exists to prove install.sh avoids.
for parent in "${TMPDIR:-/tmp}" "${CI_PROJECT_DIR:-}" "${HOME:-}" .; do
  [[ -n "$parent" ]] || continue
  if exec_capable "$parent"; then
    WORK="$(mktemp -d "$parent/varsafe-installer-tests.XXXXXX")"
    break
  fi
done

if [[ -z "$WORK" ]]; then
  echo "error  no writable, exec-capable directory found (tried TMPDIR, CI_PROJECT_DIR, HOME, .)." >&2
  echo "       This suite runs executable fakes from that directory; on a noexec mount it would" >&2
  echo "       report failures that describe the mount rather than install.sh." >&2
  echo "       Point TMPDIR at an exec-capable path this user can write." >&2
  exit 1
fi

trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
SKIP=0

ok() { PASS=$((PASS + 1)); echo "  ok    $1"; }
ko() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }

# A case this HOST cannot exercise — no bash-free POSIX shell, an openssl that cannot sign Ed25519.
# That is a fact about the machine, not about the installer, so the matrix below runs the same suite
# on several toolchains and each reports what it could reach. It is still a coverage hole: the job
# that runs on the full CI image sets REQUIRE_FULL_COVERAGE=1, where any skip is a failure.
skip() {
  if [[ -n "${REQUIRE_FULL_COVERAGE:-}" ]]; then
    ko "$1 (REQUIRE_FULL_COVERAGE is set: this host was expected to cover it)"
    return
  fi
  SKIP=$((SKIP + 1))
  echo "  skip  $1"
}

check() {
  local desc="$1"; shift
  if "$@"; then ok "$desc"; else ko "$desc"; fi
}

# `!` is shell syntax, not a command — it cannot travel through check's "$@".
not() { ! "$@"; }

# `stat -c` is GNU and `base64 -d` is not BSD. install.sh already handles both spellings; this suite
# must too, or every permission assertion fails on macOS — the platform whose installer defect
# started all of this, and the one this suite most needs to run on.
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
b64_decode() { if base64 -d </dev/null >/dev/null 2>&1; then base64 -d; else base64 -D; fi; }
b64_encode() { base64 | tr -d '\n'; }
sha256_portable() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'
}

# A PATH with the tools install.sh needs, plus only the verifiers named in "$@".
tool_sandbox() {
  local dir="$1"; shift
  rm -rf "$dir"; mkdir -p "$dir"
  local tool path
  for tool in mktemp rm grep head awk sed cat tr cut uname chmod mkdir stat id dirname basename sha256sum shasum "$@"; do
    path=$(command -v "$tool" 2>/dev/null) || continue
    ln -sf "$path" "$dir/$tool"
  done
  printf '%s' "$dir"
}

# A fake curl that serves fixtures the way the CDN would. Routes are "<url-suffix> <file>" pairs;
# anything unrouted is an HTTP error (curl -f exits 22). It writes where `-o` points, as the real
# one does — install.sh downloads only into files — and every requested URL is logged to
# "$dir/requests", so a test can assert what was NEVER fetched.
# Usage: fake_cdn <dir> [<url-suffix> <file>]...
fake_cdn() {
  local dir="$1"; shift
  mkdir -p "$dir"
  : > "$dir/routes"
  : > "$dir/requests"
  while [[ $# -ge 2 ]]; do
    printf '%s %s\n' "$1" "$2" >> "$dir/routes"
    shift 2
  done
  cat > "$dir/curl" <<FAKE
#!/bin/sh
out=""; url=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift ;;
    http://*|https://*) url="\$1" ;;
  esac
  shift
done
echo "\$url" >> "$dir/requests"
while read -r suffix file; do
  case "\$url" in
    *"\$suffix")
      if [ -n "\$out" ]; then cat "\$file" > "\$out"; else cat "\$file"; fi
      exit 0 ;;
  esac
done < "$dir/routes"
exit 22
FAKE
  chmod +x "$dir/curl"
}

# Each scenario runs in a SUBSHELL so error()'s `exit 1` and variable mutations
# stay contained. HOME is redirected into the tmpdir so DEFAULT_INSTALL_DIR is
# ours, never the real one.
scenario() {
  local home_dir="$1" install_dir="$2"
  (
    export HOME="$home_dir"
    export VARSAFE_INSTALL_DIR="$install_dir"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/install.sh"
    ensure_install_dir
    # Report the resolved dir so callers can assert on relocation.
    echo "RESOLVED:$INSTALL_DIR"
  ) </dev/null 2>&1
}

echo "install.sh destination handling"

# --- default dir: created, writable, chmod 700 ---
home="$WORK/home-default"; mkdir -p "$home"
out=$(scenario "$home" "")
check "default dir install resolves to \$HOME/.varsafe/bin" \
  grep -q "RESOLVED:$home/.varsafe/bin" <<<"$out"
check "default dir is created" test -d "$home/.varsafe/bin"
check "default dir is chmod 700" test "$(file_mode "$home/.varsafe/bin")" = "700"

# ~/.varsafe above it is the CLI's own directory, which it keeps 0700. Created by the installer
# under a group-writable umask, it let anyone in the group swap the directory holding the binary.
home="$WORK/home-umask"; mkdir -p "$home"
out=$( (umask 002; scenario "$home" "") )
check "under a group-writable umask, a new ~/.varsafe is created private" \
  test "$(file_mode "$home/.varsafe")" = "700"
# Anything already at ~/.varsafe is not the installer's to change — a symlink least of all, since
# a chmod would follow it — and the CLI tightens its own directory when it first opens it.
home="$WORK/home-symlinked-root"; mkdir -p "$home" "$WORK/shared-varsafe"
chmod 755 "$WORK/shared-varsafe"
ln -s "$WORK/shared-varsafe" "$home/.varsafe"
out=$(scenario "$home" "")
check "a symlinked ~/.varsafe keeps its target's permissions" \
  test "$(file_mode "$WORK/shared-varsafe")" = "755"

# --- trailing slash still counts as the default (chmod applies, no 'custom' path) ---
home="$WORK/home-slash"; mkdir -p "$home"
out=$(scenario "$home" "$home/.varsafe/bin/")
check "trailing-slash spelling resolves to the default" \
  grep -q "RESOLVED:$home/.varsafe/bin$" <<<"$out"
check "trailing-slash default still gets chmod 700" \
  test "$(file_mode "$home/.varsafe/bin")" = "700"

# --- symlinked default: chmod must NOT follow to the target ---
home="$WORK/home-symlink"; mkdir -p "$home/.varsafe" "$WORK/shared-bin"
chmod 755 "$WORK/shared-bin"
ln -s "$WORK/shared-bin" "$home/.varsafe/bin"
out=$(scenario "$home" "")
check "symlinked default dir is warned about" grep -q "symlink" <<<"$out"
check "symlink target permissions untouched" \
  test "$(file_mode "$WORK/shared-bin")" = "755"

# --- unwritable custom dir, no tty: refuse with guidance, never relocate ---
home="$WORK/home-custom"; mkdir -p "$home" "$WORK/unwritable"
chmod 500 "$WORK/unwritable"
out=$(scenario "$home" "$WORK/unwritable")
check "unwritable custom dir refuses" grep -q "Cannot write to $WORK/unwritable" <<<"$out"
check "refusal names the VARSAFE_INSTALL_DIR fix" grep -q "VARSAFE_INSTALL_DIR" <<<"$out"
check "no silent relocation happened" not grep -q "RESOLVED:" <<<"$out"
check "nothing was installed to the default instead" not test -e "$home/.varsafe/bin"

# --- writable custom dir: accepted verbatim, permissions untouched ---
home="$WORK/home-custom2"; mkdir -p "$home" "$WORK/mybin"
chmod 755 "$WORK/mybin"
out=$(scenario "$home" "$WORK/mybin")
check "writable custom dir is honored" grep -q "RESOLVED:$WORK/mybin" <<<"$out"
check "custom dir permissions untouched (no chmod 700)" \
  test "$(file_mode "$WORK/mybin")" = "755"

# --- world-writable custom dir without sticky bit: warn, still honor ---
home="$WORK/home-777"; mkdir -p "$home" "$WORK/open-bin"
chmod 777 "$WORK/open-bin"
out=$(scenario "$home" "$WORK/open-bin")
check "world-writable custom dir warns" grep -q "world-writable" <<<"$out"
check "world-writable custom dir is still honored" grep -q "RESOLVED:$WORK/open-bin" <<<"$out"

# --- the directory must be one PATH can hold ---
# It is written into a shell rc file as a PATH entry. A relative one resolves against whatever
# directory the shell is in; ':' splits it into two entries no quoting can rejoin; and the rc line
# is shell code, so characters a double-quoted string expands or ends on would run at every login.
home="$WORK/home-shape"; mkdir -p "$home"
tilde="~"  # literally: the shell never expands a tilde inside a variable's value
for bad in "bin" "$tilde/bin"; do
  out=$(scenario "$home" "$bad")
  check "a relative install dir ($bad) is refused before anything is created" \
    grep -q "must be an absolute path" <<<"$out"
done
for bad in "$WORK/a:b" "$WORK/a\$(id)" "$WORK/a\"b" "$WORK/a\`b"; do
  out=$(scenario "$home" "$bad")
  check "an install dir PATH cannot hold ($bad) is refused" grep -q "cannot be put on PATH" <<<"$out"
  check "and it was not created" not test -e "$bad"
done
mkdir -p "$WORK/my tools/bin"
out=$(scenario "$home" "$WORK/my tools/bin")
check "an install dir with a space in it is fine" grep -q "RESOLVED:$WORK/my tools/bin" <<<"$out"

# --- `curl … | sudo bash` with the user's HOME kept ---
# macOS's sudoers keeps HOME, as does `sudo -E`: root would create a root-owned 0700 ~/.varsafe/bin
# in that user's home that they cannot even enter. This suite never runs as root, so `id -u` is
# faked, and HOME is a directory the test user does not own — which is exactly the state at issue.
root_box="$WORK/fake-root"; mkdir -p "$root_box"
printf '#!/bin/sh\necho 0\n' > "$root_box/id"; chmod +x "$root_box/id"
as_root_with_home() {
  ( export HOME="$1"; unset VARSAFE_INSTALL_DIR SUDO_USER DOAS_USER
    if [[ -n "$2" ]]; then export "${2?}"; fi
    PATH="$root_box:$PATH"
    source "$REPO_ROOT/install.sh"
    ensure_install_dir
    echo "RESOLVED:$INSTALL_DIR"
  ) </dev/null 2>&1
}
for via in SUDO_USER=alice DOAS_USER=alice; do
  out=$(as_root_with_home / "$via")
  check "root run through ${via%%=*} into another user's HOME is refused with guidance" \
    grep -q "without sudo" <<<"$out"
done
# Root with a HOME it does not own and no sudo/doas is a CI container (GitHub Actions runs root
# with HOME=/github/home, owned by the runner user): not this case, so not refused for it.
out=$(as_root_with_home / "")
check "root in a container with a foreign HOME is not mistaken for sudo" \
  not grep -q "without sudo" <<<"$out"

# --- dir_writable probes with a real file, not permission bits ---
home="$WORK/home-probe"; mkdir -p "$home"
out=$(
  export HOME="$home"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/install.sh" </dev/null 2>&1
  dir_writable "$WORK/probe-target" && echo "WRITABLE"
  ls -A "$WORK/probe-target"
)
check "dir_writable creates and reports a writable dir" grep -q "WRITABLE" <<<"$out"
check "dir_writable leaves no probe file behind" \
  test -z "$(ls -A "$WORK/probe-target" 2>/dev/null)"

# --- smoke test classifies exec refusal (exit 126) as noexec guidance ---
home="$WORK/home-smoke"; mkdir -p "$home"
printf '#!/bin/sh\nexit 0\n' > "$WORK/not-executable"
chmod 644 "$WORK/not-executable"
out=$(
  export HOME="$home"
  export VARSAFE_INSTALL_DIR="$WORK"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/install.sh" </dev/null 2>&1
  smoke_test_binary "$WORK/not-executable" "linux-x64" 2>&1
)
check "exec refusal names noexec and VARSAFE_INSTALL_DIR" \
  grep -q "noexec" <<<"$out"

# --- the literal `curl | bash` shape: script arrives on STDIN, no file, no tty ---
# BASH_SOURCE is UNSET in this shape; with set -u a careless guard aborts the
# script before main() runs. This test pipes the real bytes exactly like curl
# does and must reach ensure_install_dir's clean refusal — not a bash error.
home="$WORK/home-piped"; mkdir -p "$home"
out=$(HOME="$home" VARSAFE_INSTALL_DIR="$WORK/unwritable" bash < "$REPO_ROOT/install.sh" 2>&1)
check "piped stdin (curl|bash shape) reaches the refusal, not a bash error" \
  grep -q "Cannot write to $WORK/unwritable" <<<"$out"
check "piped stdin produces no unbound-variable error" \
  not grep -q "unbound variable" <<<"$out"

# --- no HOME, no custom dir: controlled error, not a raw set -u abort ---
out=$(env -u HOME VARSAFE_INSTALL_DIR= bash < "$REPO_ROOT/install.sh" 2>&1)
check "unset HOME fails with guidance, not an unbound-variable abort" \
  grep -q "VARSAFE_INSTALL_DIR" <<<"$out"
check "unset HOME does not raw-abort" not grep -q "unbound variable" <<<"$out"

# --- production shape: fd0 is a PIPE and a controlling TTY exists ---
# `bash < file` makes fd0 a regular file; curl|bash makes it a pipe, and the
# /dev/tty prompt branch only exists when a controlling terminal is present.
# script(1) provides the PTY; the pipe inside carries the real installer bytes.
if command -v script >/dev/null 2>&1; then
  home="$WORK/home-pty"; mkdir -p "$home"
  # `script` is not one program: GNU takes `-qec CMD FILE`, BSD (macOS) takes `-q FILE CMD...`.
  # Using the GNU spelling on macOS fails the case and reads as an installer defect.
  pty_command="sh -c 'cat \"$REPO_ROOT/install.sh\" | HOME=\"$home\" VARSAFE_INSTALL_DIR=\"$WORK/unwritable\" bash'"
  if script --version 2>&1 | grep -qi util-linux; then
    out=$(printf 'n\n' | script -qec "$pty_command" /dev/null 2>&1)
  else
    out=$(printf 'n\n' | script -q /dev/null sh -c "$pty_command" 2>&1)
  fi
  check "pipe+PTY shape reaches the /dev/tty offer" grep -aq "instead" <<<"$out"
  check "declining the offer refuses without installing" \
    not test -e "$home/.varsafe/bin/varsafe"
else
  # Loud, counted skip — not silent: the suite's total below would not add up.
  skip "pipe+PTY shape: script(1) not available on this host"
fi

# --- POSIX re-exec path: a failed fetch must NOT report success ---
# `exec bash -c "$(curl ...)"` swallows curl's exit status; the empty substitution
# becomes `bash -c ""`, which exits 0 and installs nothing. These tests pin the
# fetch failure to a loud non-zero exit.
#
# Run under a REAL POSIX shell, resolved by absolute path before any fake is on PATH.
# Reproducing the shape with `bash -c 'unset BASH_VERSION'` would let a bashism inside the
# guard pass here and still break for the users this path exists for — `curl … | sh` where
# /bin/sh is dash. Note /bin/sh on macOS IS bash and sets BASH_VERSION, so it cannot be used.
# Prefer dash, then busybox, then /bin/sh — but only accept /bin/sh if it is NOT bash. On many
# systems /bin/sh IS bash (always on macOS), and bash sets BASH_VERSION even when invoked as sh,
# so the re-exec guard would never trigger and these cases would silently test nothing. Asking
# the candidate whether it reports BASH_VERSION is the portable way to tell, and it means the
# suite does not depend on `dash` being installed — the varsafe-ci image has no dash.
posix_sh_candidate() {
  local sh="$1"
  [[ -x "$sh" ]] || return 1
  [[ -z "$("$sh" -c 'echo "${BASH_VERSION:-}"' 2>/dev/null)" ]]
}

POSIX_SH=""
for candidate in "$(command -v dash || true)" /bin/dash /bin/sh /usr/bin/sh; do
  [[ -n "$candidate" ]] || continue
  if posix_sh_candidate "$candidate"; then POSIX_SH="$candidate"; break; fi
done

# A fake curl emitting $2, exiting $3; a fake bash that only records that it ran. Recording
# rather than executing is what lets us assert the installer never reached the exec.
# The body goes to a FILE that the fake cats, never interpolated into the fake's source:
# the real installer's end marker contains double quotes, which would terminate the string
# early and silently change what the fake emits.
fake_fetch() {
  local dir="$WORK/fake-$1"; mkdir -p "$dir"
  printf '%b' "$2" > "$dir/body"
  printf '#!/bin/sh\ncat %s/body\nexit %s\n' "$dir" "$3" > "$dir/curl"
  printf '#!/bin/sh\ntouch "%s/bash-was-invoked"\nexit 0\n' "$dir" > "$dir/bash"
  chmod +x "$dir/curl" "$dir/bash"
  echo "$dir"
}

reexec() {
  ( PATH="$1:$PATH" "$POSIX_SH" "$REPO_ROOT/install.sh" ) </dev/null 2>&1
}

if [[ -z "$POSIX_SH" ]]; then
  # Loud, counted skip — these cases are the whole point of the re-exec guard.
  skip "POSIX re-exec cases: no non-bash POSIX shell on this host (install dash)"
else
  # The sentinel on the installer's LAST line. Only a body containing it arrived complete.
  MARKER='# varsafe-installer-end'

  # 1. transport failure
  d=$(fake_fetch fails "" 22)
  out=$(reexec "$d"); rc=$?
  check "failed fetch exits non-zero (not a silent success)" test "$rc" -ne 0
  check "failed fetch names curl's exit status" grep -q "curl exit 22" <<<"$out"
  check "failed fetch never execs bash" not test -e "$d/bash-was-invoked"

  # 2. HTTP 200 with an empty body — the proxy/CDN shape that made this silent
  d=$(fake_fetch empty "" 0)
  out=$(reexec "$d"); rc=$?
  check "empty body exits non-zero" test "$rc" -ne 0
  check "empty body never execs bash" not test -e "$d/bash-was-invoked"

  # 3. whitespace-only body: non-empty, so a bare -z check would wave it through
  d=$(fake_fetch blank '   ' 0)
  out=$(reexec "$d"); rc=$?
  check "whitespace-only body exits non-zero" test "$rc" -ne 0
  check "whitespace-only body never execs bash" not test -e "$d/bash-was-invoked"

  # 4. truncated but syntactically valid prefix — curl exits 0, body runs, exits 0.
  #    This is the case a status+non-empty check alone cannot catch.
  d=$(fake_fetch truncated '#!/bin/bash\n# transfer cut here' 0)
  out=$(reexec "$d"); rc=$?
  check "truncated body exits non-zero" test "$rc" -ne 0
  check "truncated body says truncated" grep -q "truncated" <<<"$out"
  check "truncated body never execs bash" not test -e "$d/bash-was-invoked"

  # 4b. The sentinel must appear EXACTLY ONCE, on the last line. If the guard spelled it
  #     literally, that occurrence would sit above every truncation point and any body cut off
  #     after it would still "contain the end marker" and run — the check would look present
  #     while detecting nothing. (It did, briefly: the first version keyed on `main "$@"`,
  #     which the guard's own case statement contains at line 32.)
  check "end sentinel appears exactly once in install.sh" \
    test "$(grep -cF "$MARKER" "$REPO_ROOT/install.sh")" = "1"
  check "end sentinel is on the LAST line of install.sh" \
    grep -qF "$MARKER" <<<"$(tail -1 "$REPO_ROOT/install.sh")"

  # 4c. The strongest truncation case: the REAL installer, genuinely cut short. A synthetic
  #     stub cannot show that a realistic partial body — hundreds of valid lines, including
  #     the guard itself — is refused.
  real_trunc="$WORK/fake-realtrunc"; mkdir -p "$real_trunc"
  head -200 "$REPO_ROOT/install.sh" > "$real_trunc/body"
  printf '#!/bin/sh\ncat %s/body\nexit 0\n' "$real_trunc" > "$real_trunc/curl"
  printf '#!/bin/sh\ntouch "%s/bash-was-invoked"\nexit 0\n' "$real_trunc" > "$real_trunc/bash"
  chmod +x "$real_trunc/curl" "$real_trunc/bash"
  out=$(reexec "$real_trunc"); rc=$?
  check "a truncated copy of the REAL installer is refused" test "$rc" -ne 0
  check "truncated REAL installer never execs bash" not test -e "$real_trunc/bash-was-invoked"

  # 5. POSITIVE CONTROL: a complete body MUST reach the exec. Without this the four
  #    "never execs bash" assertions above could all pass for the trivial reason that the
  #    fake was never reachable — proving nothing.
  d=$(fake_fetch complete "#!/bin/bash\n$MARKER" 0)
  reexec "$d" >/dev/null
  check "control: a COMPLETE body does exec bash (proves the checks can fail)" \
    test -e "$d/bash-was-invoked"

  # 6. No curl: stock Alpine has only BusyBox's wget. Run with a PATH holding no curl at all —
  #    the host's would otherwise be found first — and the fake wget serving the complete body.
  d=$(fake_fetch wget-only "#!/bin/bash\n$MARKER" 0)
  mv "$d/curl" "$d/wget"
  ( PATH="$d:$(tool_sandbox "$WORK/box-reexec-wget" touch)" "$POSIX_SH" "$REPO_ROOT/install.sh" ) </dev/null >/dev/null 2>&1
  check "without curl, the re-exec downloads itself with wget" test -e "$d/bash-was-invoked"

  # 7. Neither: say so, rather than report a download failure that never happened.
  d=$(fake_fetch no-downloader "" 0)
  rm -f "$d/curl"
  out=$( ( PATH="$d:$(tool_sandbox "$WORK/box-reexec-none" touch)" "$POSIX_SH" "$REPO_ROOT/install.sh" ) </dev/null 2>&1 )
  check "with neither curl nor wget, the re-exec says that is what is missing" \
    grep -q "needs curl or wget" <<<"$out"
  check "and it never execs bash" not test -e "$d/bash-was-invoked"
fi

# ---------------------------------------------------------------------------
# A custom install directory must be the one that lands on PATH. The bash/zsh branch wrote the
# DEFAULT directory literally, so `VARSAFE_INSTALL_DIR=... | bash` left a PATH entry pointing at a
# directory the install had never used and `varsafe` was still not found.
custom_rc="$WORK/custom/.zshrc"
mkdir -p "$WORK/custom"
(
  # A HOME the directory is not under: inherited, it can be /tmp (the CI privilege drop sets it)
  # with this work dir inside it, and the line is then — correctly — written $HOME-relative.
  export HOME="$WORK/custom-home"
  . "$REPO_ROOT/install.sh"
  INSTALL_DIR="$WORK/custom/opt/varsafe/bin"
  add_to_shell_config zsh "$custom_rc"
) >/dev/null 2>&1
check "a custom install dir is the directory added to PATH" \
  grep -q "$WORK/custom/opt/varsafe/bin" "$custom_rc"

# The default install keeps writing a $HOME-relative entry, so a synced rc file works on a machine
# whose home directory has a different path.
default_rc="$WORK/custom/.zshrc-default"
(
  . "$REPO_ROOT/install.sh"
  HOME="$WORK/custom"
  INSTALL_DIR="$WORK/custom/.varsafe/bin"
  add_to_shell_config zsh "$default_rc"
) >/dev/null 2>&1
check "the default install dir stays \$HOME-relative in the rc file" \
  grep -q 'export PATH="\$HOME/.varsafe/bin:\$PATH"' "$default_rc"

# Re-running must converge. The "already configured" check looked for the DEFAULT directory, so
# every re-run with a custom VARSAFE_INSTALL_DIR appended another PATH line — and an rc file that
# still named the default from an earlier install passed for a custom directory it never mentioned.
# A PATH holding no varsafe, so `command -v varsafe` cannot short-circuit on this host's own.
path_box=$(tool_sandbox "$WORK/box-path")
configure_twice() {
  ( export HOME="$1" SHELL=/bin/zsh; unset ZDOTDIR
    . "$REPO_ROOT/install.sh"
    PATH="$path_box"
    INSTALL_DIR="$2"
    configure_path; configure_path ) </dev/null >/dev/null 2>&1
}
home="$WORK/home-rerun"; mkdir -p "$home"
configure_twice "$home" "$WORK/opt-varsafe/bin"
check "re-running with a custom install dir adds its PATH line exactly once" \
  test "$(grep -c "opt-varsafe/bin" "$home/.zshrc")" = "1"
home="$WORK/home-stale"; mkdir -p "$home"
printf '# Varsafe CLI\nexport PATH="$HOME/.varsafe/bin:$PATH"\n' > "$home/.zshrc"
configure_twice "$home" "$WORK/elsewhere/bin"
check "an rc line for the default dir does not count as configuring a custom one" \
  grep -q "$WORK/elsewhere/bin" "$home/.zshrc"

# Only a whole PATH entry counts, never part of one: with $HOME/bin reduced to "bin", an rc file
# that put /usr/local/bin on PATH passed for it, and varsafe stayed unreachable after a reload.
home="$WORK/home-homebin"; mkdir -p "$home/bin"
printf 'export PATH="/usr/local/bin:$PATH"\n' > "$home/.zshrc"
printf '#!/bin/sh\necho ok\n' > "$home/bin/varsafe"; chmod +x "$home/bin/varsafe"
configure_twice "$home" "$home/bin"
reloaded=$( ( export HOME="$home"; PATH=/usr/bin:/bin; . "$home/.zshrc"; command -v varsafe ) 2>/dev/null )
check "an rc file putting /usr/local/bin on PATH does not count for \$HOME/bin" \
  test "$reloaded" = "$home/bin/varsafe"
check "and re-running still adds that line exactly once" \
  test "$(grep -c 'HOME/bin:' "$home/.zshrc")" = "1"

# rc file content -> whether the DEFAULT directory counts as already on PATH there.
default_counts() {
  local home="$WORK/home-default-$1"; rm -rf "$home"; mkdir -p "$home"
  printf '%s\n' "$2" > "$home/.zshrc"
  ( export HOME="$home" SHELL=/bin/zsh; unset ZDOTDIR
    . "$REPO_ROOT/install.sh"; rc_has_install_dir "$home/.zshrc" zsh ) </dev/null >/dev/null 2>&1
}
check "a commented-out PATH line does not count" \
  not default_counts commented '# export PATH="$HOME/.varsafe/bin:$PATH"'
check "an alias that merely mentions the directory does not count" \
  not default_counts alias 'alias vs=~/.varsafe/bin/varsafe'
check "a hand-written PATH entry for the default dir counts, so no duplicate is added" \
  default_counts handwritten 'export PATH=$PATH:~/.varsafe/bin'
# Earlier installers wrote fish's line unquoted, with the custom directory: it must still count, or
# every existing fish install gains a second line on its next run.
fish_legacy="$WORK/home-fish-legacy/.config/fish/config.fish"; mkdir -p "$(dirname "$fish_legacy")"
printf '\n# Varsafe CLI\nfish_add_path %s\n' "$WORK/opt-fish/bin" > "$fish_legacy"
( export HOME="$WORK/home-fish-legacy" SHELL=/usr/bin/fish; . "$REPO_ROOT/install.sh"
  PATH="$path_box"; INSTALL_DIR="$WORK/opt-fish/bin"; configure_path ) </dev/null >/dev/null 2>&1
check "the unquoted fish line earlier installers wrote still counts" \
  test "$(grep -c 'fish_add_path' "$fish_legacy")" = "1"

out=$( ( export HOME="$WORK/home-manual"
  . "$REPO_ROOT/install.sh"; INSTALL_DIR="$WORK/opt-varsafe/bin"
  print_manual_instructions zsh "$WORK/.zshrc" ) 2>&1 )
check "manual PATH instructions name the directory actually installed into" \
  grep -q "$WORK/opt-varsafe/bin" <<<"$out"

out=$( ( export HOME="$WORK/home-zdot" SHELL=/bin/zsh ZDOTDIR="$WORK/zdot"
  . "$REPO_ROOT/install.sh"; get_shell_config ) 2>&1 )
check "zsh's rc file is the one in ZDOTDIR when that is set" test "$out" = "$WORK/zdot/.zshrc"

fish_rc="$WORK/fish/config.fish"
( . "$REPO_ROOT/install.sh"; INSTALL_DIR="$WORK/my tools/bin"; add_to_shell_config fish "$fish_rc" ) \
  >/dev/null 2>&1
check "fish gets the directory quoted, so a path with a space stays one entry" \
  grep -qF "fish_add_path \"$WORK/my tools/bin\"" "$fish_rc"

# ---------------------------------------------------------------------------
# Release signature verification (audit F-05)
#
# `checksums.txt` came from the same bucket as the binary, so it was never evidence: whoever
# could swap one could swap the other. These cases drive `verify_manifest` directly, with a
# throwaway Ed25519 key, and assert it refuses everything except a genuinely signed manifest.
# ---------------------------------------------------------------------------

# The key baked into install.sh must be the one `varsafe update` verifies against. A drift here
# downgrades every FIRST install to unverified while the updater still looks correct.
install_key=$(sed -n 's/^RELEASE_SIGNING_PUBLIC_KEY="\(.*\)"$/\1/p' "$REPO_ROOT/install.sh")
check "installer pins a release signing key" test -n "$install_key"
# The updater's copy of the key lives in the CLI source, which the public installer repository
# deliberately does not carry. Assert it where both halves exist, and say why where they do not —
# the private pipeline runs this suite with REQUIRE_FULL_COVERAGE, so the skip fails there.
cli_key_source="$REPO_ROOT/packages/cli/src/system/release-signature.ts"
if [[ ! -f "$cli_key_source" ]]; then
  skip "installer/updater key match: the CLI source is not part of this repository"
else
  cli_key=$(sed -n "s/^export const RELEASE_SIGNING_PUBLIC_KEY = '\(.*\)';$/\1/p" "$cli_key_source")
  check "installer key matches the key the CLI updater verifies against" \
    test "$install_key" = "$cli_key"
fi

# The payload every fixture describes, and the manifest that names its checksum — built WITHOUT
# openssl, so a host whose openssl cannot sign Ed25519 can still exercise the SSHSIG verifier.
# That host (Ubuntu 20.04, and stock macOS) is exactly where SSHSIG is the only thing that works.
sig_dir="$WORK/sig"; mkdir -p "$sig_dir"
printf 'payload' > "$sig_dir/binary"
payload_sha=$(sha256sum "$sig_dir/binary" 2>/dev/null | awk '{print $1}')
[[ -n "$payload_sha" ]] || payload_sha=$(shasum -a 256 "$sig_dir/binary" | awk '{print $1}')
# The CDN manifest conventionally ends in a newline. Keep it in the signed fixture so this
# regression catches any installer that loses bytes via command substitution.
printf '%s\n' '{"version":"9.9.9","checksums":{"varsafe-linux-x64":"'"$payload_sha"'"}}' \
  > "$sig_dir/release.json"

# Stands in for the pinned key on a host that cannot sign: only the SSHSIG cases run there, and
# they override it themselves.
test_pub='no-openssl-on-this-host'

# -------------------------------------------------------------------------
# What the machine can actually verify WITH
#
# `command -v openssl` succeeding does not mean the release can be verified. Stock macOS ships
# LibreSSL as /usr/bin/openssl: it has no Ed25519 EVP and no `pkeyutl -rawin`, so every check
# below it failed and the installer told real users their download looked tampered with. These
# cases build a PATH holding exactly the tools a given machine has.
# -------------------------------------------------------------------------


# Stands in for macOS's /usr/bin/openssl: present, answers `version`, and cannot do Ed25519.
plant_libressl() {
  cat > "$1/openssl" <<'LIBRESSL'
#!/bin/sh
case "$1" in
version) echo "LibreSSL 3.3.6"; exit 0 ;;
pkey) echo "unknown message digest" >&2; exit 1 ;;
pkeyutl) echo "pkeyutl: unknown option -rawin" >&2; exit 1 ;;
esac
exit 1
LIBRESSL
  chmod +x "$1/openssl"
}

# Runs verify_manifest for the 9.9.9 fixture with PATH set to exactly $1, the pinned raw key
# replaced by $2 and, when given, the OpenSSH key by $3. Prints what it said, then the checksum the
# manifest yielded — so a case can assert what verification produced, not only that it did not
# refuse.
verify_with() {
  ( PATH="$1"
    . "$REPO_ROOT/install.sh"
    RELEASE_SIGNING_PUBLIC_KEY="$2"
    if [[ -n "${3:-}" ]]; then RELEASE_SIGNING_SSH_PUBLIC_KEY="$3"; fi
    WORK_DIR=$(mktemp -d "$WORK/verify.XXXXXX")
    verify_manifest "varsafe-linux-x64" "9.9.9"
    echo "SHA256:$EXPECTED_SHA256"
  ) 2>&1
}

libressl_box=$(tool_sandbox "$WORK/box-libressl")
plant_libressl "$libressl_box"
fake_cdn "$libressl_box" release.json.sig "$sig_dir/sig.b64" release.json "$sig_dir/release.json"
libressl_out=$(verify_with "$libressl_box" "$test_pub")
libressl_rc=$?

check "a machine whose openssl cannot verify Ed25519 is NOT told its download is tampered with" \
  not grep -qi "tampered" <<<"$libressl_out"
check "it is told which tool cannot verify, and what to install" \
  grep -qi "ssh-keygen\|openssl" <<<"$libressl_out"
check "and it still refuses to install (no unverified fallback)" \
  test "$libressl_rc" -ne 0

# ---------------------------------------------------------------------------
# Which VERSION gets installed
#
# `latest` is the only thing the installer could ever fetch, so there was no way to install a known
# good release after a bad one — and no way for CI to prove a just-published version installs
# BEFORE flipping `latest` to it. The pinned value lands in a CDN URL path, so it is validated.
# ---------------------------------------------------------------------------
printf '7.0.0\n' > "$WORK/version-latest.txt"
version_box=$(tool_sandbox "$WORK/box-version")
fake_cdn "$version_box" latest/version.txt "$WORK/version-latest.txt"

resolved_version() {
  ( PATH="$1"; export VARSAFE_VERSION="$2"; . "$REPO_ROOT/install.sh"
    WORK_DIR=$(mktemp -d "$WORK/resolve.XXXXXX")
    resolve_version ) 2>&1
}

check "with no pin, the latest version is installed" \
  test "$(resolved_version "$version_box" "")" = "7.0.0"
check "a pinned version is installed instead of latest" \
  test "$(resolved_version "$version_box" "7.2.32")" = "7.2.32"
check "a pinned prerelease is accepted" \
  test "$(resolved_version "$version_box" "8.0.0-rc.1")" = "8.0.0-rc.1"
# The version becomes part of `${RELEASES_URL}/v<version>/...`, so anything that is not a version
# must be refused rather than pasted into a URL.
for bogus in "../../etc/passwd" "7.2.32/../../x" "latest" "" " 7.2.32"; do
  [[ -z "$bogus" ]] && continue
  out=$(resolved_version "$version_box" "$bogus")
  check "a pin that is not a version ($bogus) is refused" \
    grep -qi "VARSAFE_VERSION" <<<"$out"
done

# What `latest` names is checked the same way: a proxy or captive portal answering in the release
# server's place must stop the install with that said, not become part of a download URL.
printf '<html>Sign in to continue</html>\n' > "$WORK/version-portal.txt"
portal_box=$(tool_sandbox "$WORK/box-portal")
fake_cdn "$portal_box" latest/version.txt "$WORK/version-portal.txt"
out=$(resolved_version "$portal_box" "")
check "a latest pointer that is not a version is refused, naming the likely cause" \
  grep -q "did not return a version" <<<"$out"

# The resolver is not the wiring. `main` could go back to fetching `latest` regardless, and every
# case above would still pass while a pinned install quietly fetched `latest`, which is the whole
# point of the pin. Record the URLs the installer actually asks for. getconf answers glibc, so a
# musl host runs this too rather than stopping at the libstdc++ prerequisite: libc is not what is
# under test here.
url_box=$(tool_sandbox "$WORK/box-url")
printf '#!/bin/sh\necho "glibc 2.36"\n' > "$url_box/getconf"
chmod +x "$url_box/getconf"

# Runs the whole installer against a CDN that answers nothing, pinned to $2 when given. Prints what
# it said; the URLs it asked for are left in $url_box/requests.
run_installer() {
  local home="$WORK/url-home-$1"; rm -rf "$home"; mkdir -p "$home"
  fake_cdn "$url_box"
  (
    PATH="$url_box"
    export HOME="$home" VARSAFE_INSTALL_DIR="$home/bin"
    unset VARSAFE_VERSION
    if [[ -n "$2" ]]; then export VARSAFE_VERSION="$2"; fi
    # By absolute path: PATH here is the sandbox, which deliberately holds no bash.
    "$BASH" "$REPO_ROOT/install.sh"
  ) </dev/null 2>&1
}

run_installer pinned 7.2.32 >/dev/null
check "a pinned install downloads from that version's path" \
  grep -q '/v7\.2\.32/' "$url_box/requests"
check "a pinned install never asks what latest is" \
  not grep -q '/latest/' "$url_box/requests"
run_installer unpinned "" >/dev/null
check "without a pin the installer asks what latest is" \
  grep -q '/latest/version\.txt' "$url_box/requests"

# ---------------------------------------------------------------------------
# A failure says what failed
#
# error() printed to STDOUT, and main captures stdout from detect_platform and resolve_version: their
# errors were swallowed into a variable and the installer exited 1 having said nothing at all. The
# commonest failure there is the release server being unreachable.
# ---------------------------------------------------------------------------
out=$(run_installer unreachable ""); rc=$?
check "an unreachable release server is reported, not a silent exit" \
  grep -q "Could not fetch the latest version" <<<"$out"
check "and the run fails" test "$rc" -ne 0
out=$(run_installer typo v7.6.0)
check "a VARSAFE_VERSION with a leading v is reported as not a version" \
  grep -qF "VARSAFE_VERSION is not a version: 'v7.6.0'" <<<"$out"
check "output read through a pipe or a log carries no colour codes" not grep -q $'\033' <<<"$out"
no_dl_box=$(tool_sandbox "$WORK/box-no-downloader")
cp "$url_box/getconf" "$no_dl_box/getconf"
out=$( ( PATH="$no_dl_box"; export HOME="$WORK/home-no-dl"
  unset VARSAFE_INSTALL_DIR; "$BASH" "$REPO_ROOT/install.sh" ) </dev/null 2>&1 )
check "a machine with neither curl nor wget is told so before anything is fetched" \
  grep -q "curl or wget is required" <<<"$out"
# Without a SHA-256 tool the binary could not be checked: that must stop the run before 90 MB is
# fetched, not after.
no_sha_box=$(tool_sandbox "$WORK/box-no-sha")
rm -f "$no_sha_box/sha256sum" "$no_sha_box/shasum"
cp "$url_box/getconf" "$no_sha_box/getconf"
fake_cdn "$no_sha_box"
out=$( ( PATH="$no_sha_box"; export HOME="$WORK/home-no-sha"
  unset VARSAFE_INSTALL_DIR; "$BASH" "$REPO_ROOT/install.sh" ) </dev/null 2>&1 )
check "a machine with no SHA-256 tool is told so before anything is downloaded" \
  grep -q "sha256sum or shasum is required" <<<"$out"
check "and nothing was requested" test ! -s "$no_sha_box/requests"

# ---------------------------------------------------------------------------
# Which artifact this machine asks for
#
# The FIRST install picks the artifact and `varsafe update` picks every one after it, so
# detect_platform() here and releaseArtifactName() in the CLI must agree. Nothing tested either
# side against the other: release-target.ts records a real defect where an arm64 musl host resolved
# to the GLIBC name, and install.sh would have made the same wrong choice — a binary that cannot
# exec. `uname` and `ldd` are faked so every (os, arch, libc) pair runs on one machine.
# ---------------------------------------------------------------------------

platform_box() {
  local dir="$1" os="$2" machine="$3" libc="$4"
  dir=$(tool_sandbox "$dir")
  # tool_sandbox SYMLINKS uname to the host's. Writing through that symlink would target
  # /usr/bin/uname (silently refused as non-root) and leave the real one in place — which is
  # exactly how the first version of these cases "passed" only for this machine's own arch.
  rm -f "$dir/uname" "$dir/ldd" "$dir/getconf"
  cat > "$dir/uname" <<UNAME
#!/bin/sh
case "\$1" in
  -s) echo "$os" ;;
  -m) echo "$machine" ;;
  *)  echo "$os" ;;
esac
UNAME
  chmod +x "$dir/uname"
  # What each C library's own tools say. "none" plants neither: a musl system without musl-utils.
  case "$libc" in
    musl)
      printf '#!/bin/sh\necho "musl libc (%s)" >&2\nexit 1\n' "$machine" > "$dir/ldd"
      printf '#!/bin/sh\necho "getconf: GNU_LIBC_VERSION: unknown variable" >&2\nexit 1\n' > "$dir/getconf"
      ;;
    gnu)
      printf '#!/bin/sh\necho "ldd (GNU libc) 2.36"\n' > "$dir/ldd"
      printf '#!/bin/sh\necho "glibc 2.36"\n' > "$dir/getconf"
      ;;
  esac
  if [[ -f "$dir/ldd" ]]; then chmod +x "$dir/ldd" "$dir/getconf"; fi
  printf '%s' "$dir"
}

detected_platform() {
  ( PATH="$1"; . "$REPO_ROOT/install.sh"; detect_platform ) 2>/dev/null
}

# The C library's own answer comes before the filesystem's, so these rows run on any host — a musl
# one pretends to be glibc through getconf and ldd alone.
platform_case() {
  local label="$1" os="$2" machine="$3" libc="$4" expected="$5"
  local box detected
  box=$(platform_box "$WORK/box-platform-$label" "$os" "$machine" "$libc")
  detected=$(detected_platform "$box")
  check "$os/$machine/$libc asks for $expected" test "$detected" = "$expected"

  # Lockstep with the updater: `varsafe update` resolves the same host through
  # releaseArtifactName(), and a disagreement swaps a working binary for one that cannot run.
  if command -v bun >/dev/null 2>&1; then
    local cli_arch cli_platform cli_name
    case "$machine" in x86_64|amd64) cli_arch=x64 ;; *) cli_arch=arm64 ;; esac
    case "$os" in Darwin) cli_platform=darwin ;; *) cli_platform=linux ;; esac
    cli_name=$(cd "$REPO_ROOT" && bun -e "
      const { releaseArtifactName } = await import('./packages/cli/src/shared/domain/release-target.ts');
      console.log(releaseArtifactName({ platform: '$cli_platform', arch: '$cli_arch', isMusl: $([[ "$libc" == musl && "$os" != Darwin ]] && echo true || echo false) }));
    " 2>/dev/null)
    # Compare what the installer ACTUALLY resolved, not what this row expects: comparing the
    # expectation would assert the CLI against a literal and never involve install.sh at all.
    check "$os/$machine/$libc resolves to the same artifact the updater would fetch" \
      test "varsafe-$detected" = "$cli_name"
  else
    skip "lockstep with releaseArtifactName for $label: no bun on this host"
  fi
}

platform_case linux-x64-gnu    Linux  x86_64  gnu  linux-x64
platform_case linux-x64-musl   Linux  x86_64  musl linux-x64-musl
platform_case linux-arm64-gnu  Linux  aarch64 gnu  linux-arm64
platform_case linux-arm64-musl Linux  aarch64 musl linux-arm64-musl
# Some kernels report arm64 rather than aarch64; both are the same machine.
platform_case linux-arm64-alt  Linux  arm64   gnu  linux-arm64
platform_case darwin-arm64     Darwin arm64   gnu  darwin-arm64
platform_case darwin-x64       Darwin x86_64  gnu  darwin-x64

# An architecture with no published artifact must be refused, not guessed at.
riscv_box=$(platform_box "$WORK/box-platform-riscv" Linux riscv64 gnu)
riscv_out=$( ( PATH="$riscv_box"; . "$REPO_ROOT/install.sh"; detect_platform ) 2>&1 )
check "an architecture with no artifact is refused by name" \
  grep -qi "Unsupported architecture: riscv64" <<<"$riscv_out"
# ...and a whole install run says so too: main captures detect_platform's output, which is where
# the refusal used to disappear.
fake_cdn "$riscv_box"
riscv_out=$( ( PATH="$riscv_box"; export HOME="$WORK/home-riscv"; unset VARSAFE_INSTALL_DIR
  mkdir -p "$HOME"; "$BASH" "$REPO_ROOT/install.sh" ) </dev/null 2>&1 )
check "a whole install on such an architecture says why it stopped" \
  grep -q "Unsupported architecture: riscv64" <<<"$riscv_out"

out=$( ( PATH="$(platform_box "$WORK/box-windows" MINGW64_NT-10.0-19045 x86_64 gnu)"
  . "$REPO_ROOT/install.sh"; detect_platform ) 2>&1 )
check "Git Bash on Windows is pointed at WSL" grep -q "inside WSL" <<<"$out"

# The C library's answer outranks what the filesystem looks like. Debian, Ubuntu and Arch package
# musl, which puts /lib/ld-musl-x86_64.so.1 on a glibc system: the installer took that for a musl
# host and refused it — on Arch, after downloading the musl build and failing to run it. And the
# choice is permanent, because `varsafe update` keeps the flavour it runs as. musl_filesystem is
# replaced, so each case runs on any host without root.
detected_with_fs() {
  ( fs_answer="$2"; PATH="$1"; . "$REPO_ROOT/install.sh"
    musl_filesystem() { return "$fs_answer"; }
    detect_platform ) 2>/dev/null
}
box=$(platform_box "$WORK/box-glibc-with-musl" Linux x86_64 gnu)
check "a glibc system with musl's loader installed asks for the glibc build" \
  test "$(detected_with_fs "$box" 0)" = "linux-x64"
box=$(platform_box "$WORK/box-libc-silent" Linux x86_64 none)
check "a system whose libc tools say nothing is recognized as musl by its filesystem" \
  test "$(detected_with_fs "$box" 0)" = "linux-x64-musl"
check "and taken for glibc when the filesystem shows no musl either" \
  test "$(detected_with_fs "$box" 1)" = "linux-x64"
box=$(platform_box "$WORK/box-getconf-blank" Linux x86_64 musl)
printf '#!/bin/sh\nexit 0\n' > "$box/getconf"
check "a getconf that succeeds without naming glibc does not outvote ldd's musl" \
  test "$(detected_with_fs "$box" 1)" = "linux-x64-musl"

# A terminal running under Rosetta 2 on Apple silicon reports x86_64; the native build is wanted,
# because `varsafe update` would otherwise keep the translated one for good.
box=$(platform_box "$WORK/box-rosetta" Darwin x86_64 gnu)
printf '#!/bin/sh\necho 1\n' > "$box/sysctl"; chmod +x "$box/sysctl"
check "an x86_64 shell under Rosetta 2 asks for the native arm64 build" \
  test "$(detected_platform "$box")" = "darwin-arm64"
printf '#!/bin/sh\necho 0\n' > "$box/sysctl"
check "an Intel Mac keeps the x64 build" test "$(detected_platform "$box")" = "darwin-x64"


if ! command -v openssl >/dev/null 2>&1 || ! openssl pkeyutl -help 2>&1 | grep -q -- '-rawin'; then
  skip "raw-signature cases: no openssl that can sign Ed25519 (needs OpenSSL 3)"
else
  # A throwaway signing pair, so the fixtures are real signatures rather than mocks.
  openssl genpkey -algorithm ed25519 -out "$sig_dir/key.pem" 2>/dev/null
  openssl pkey -in "$sig_dir/key.pem" -pubout -outform DER -out "$sig_dir/pub.der" 2>/dev/null
  # Strip the 12-byte SubjectPublicKeyInfo prefix to get the raw 32 bytes, base64 them.
  test_pub=$(tail -c 32 "$sig_dir/pub.der" | openssl base64 -A)
  openssl pkeyutl -sign -inkey "$sig_dir/key.pem" -rawin -in "$sig_dir/release.json" \
    -out "$sig_dir/sig.bin" 2>/dev/null
  openssl base64 -A -in "$sig_dir/sig.bin" -out "$sig_dir/sig.b64"

  # Serve the fixtures the way the CDN would, and point the installer at them.
  serve() {
    local d="$WORK/serve"; rm -rf "$d"
    fake_cdn "$d" release.json.sig "$1" release.json "$2"
    echo "$d"
  }

  run_verify() {
    verify_with "$1:$PATH" "$2" >/dev/null
  }

  d=$(serve "$sig_dir/sig.b64" "$sig_dir/release.json")
  out=$(verify_with "$d:$PATH" "$test_pub")
  check "control: a correctly signed manifest verifies and yields the binary's checksum" \
    grep -q "SHA256:$payload_sha" <<<"$out"

  # RHEL 8's openssl is 1.1.1, which cannot verify Ed25519 at all; EPEL's OpenSSL 3 installs beside
  # it as `openssl3`. The host's OpenSSL 3 stands in under that name, next to an openssl that cannot.
  ossl3_box=$(tool_sandbox "$WORK/box-openssl3")
  plant_libressl "$ossl3_box"
  ln -sf "$(command -v openssl)" "$ossl3_box/openssl3"
  fake_cdn "$ossl3_box" release.json.sig "$sig_dir/sig.b64" release.json "$sig_dir/release.json"
  out=$(verify_with "$ossl3_box" "$test_pub")
  check "an openssl3 beside an openssl that cannot verify (RHEL 8 with EPEL) is used" \
    grep -q "SHA256:$payload_sha" <<<"$out"

  # The whole point: a valid-looking manifest whose signature is not ours.
  printf '%s' '{"version":"9.9.9","checksums":{"varsafe-linux-x64":"'"$(printf 'trojan' | \
    sha256sum | awk '{print $1}')"'"}}' > "$sig_dir/tampered.json"
  d=$(serve "$sig_dir/sig.b64" "$sig_dir/tampered.json")
  run_verify "$d" "$test_pub"
  check "a manifest whose signature does not cover it is REFUSED" test $? -ne 0

  # A signature that is valid, but under a different key — the bucket-owner scenario.
  openssl genpkey -algorithm ed25519 -out "$sig_dir/other.pem" 2>/dev/null
  openssl pkeyutl -sign -inkey "$sig_dir/other.pem" -rawin -in "$sig_dir/release.json" \
    -out "$sig_dir/other.bin" 2>/dev/null
  openssl base64 -A -in "$sig_dir/other.bin" -out "$sig_dir/other.b64"
  d=$(serve "$sig_dir/other.b64" "$sig_dir/release.json")
  run_verify "$d" "$test_pub"
  check "a manifest signed by the WRONG key is REFUSED" test $? -ne 0

  # An empty signature is the shape a missing CDN object takes.
  : > "$sig_dir/empty.b64"
  d=$(serve "$sig_dir/empty.b64" "$sig_dir/release.json")
  run_verify "$d" "$test_pub"
  check "a missing or empty signature is REFUSED (no unsigned fallback)" test $? -ne 0

  # -------------------------------------------------------------------------
  # SSHSIG: the verifier a stock machine already has
  #
  # `ssh-keygen -Y verify` ships with OpenSSH (macOS 10.15+, every mainstream Linux) and verifies
  # the SAME Ed25519 release key, so a fresh Mac needs nothing installed. The release publishes
  # both encodings of one signature over identical manifest bytes.
  # -------------------------------------------------------------------------
fi

if ! command -v ssh-keygen >/dev/null 2>&1 || ssh-keygen -Y verify 2>&1 | grep -qi "unknown option"; then
  skip "SSHSIG cases: no ssh-keygen with -Y (needs OpenSSH 8.1+)"
else
    ssh_dir="$sig_dir/ssh"; mkdir -p "$ssh_dir"
    ssh-keygen -q -t ed25519 -N '' -C 'installer-test' -f "$ssh_dir/key"
    test_ssh_pub=$(cut -d' ' -f1,2 < "$ssh_dir/key.pub")
    cp "$sig_dir/release.json" "$ssh_dir/release.json"
    ssh-keygen -Y sign -q -n varsafe-release@varsafe.dev -f "$ssh_dir/key" "$ssh_dir/release.json"
    mv "$ssh_dir/release.json.sig" "$ssh_dir/release.json.sshsig"

    # Serves the manifest plus whichever signature encodings the test wants published.
    serve_signed() {
      local dir="$1" manifest="$2" sshsig="${3:-}" rawsig="${4:-}"
      local routes=(release.json "$manifest")
      if [[ -n "$sshsig" ]]; then routes+=(release.json.sshsig "$sshsig"); fi
      if [[ -n "$rawsig" ]]; then routes+=(release.json.sig "$rawsig"); fi
      fake_cdn "$dir" "${routes[@]}"
    }

    ssh_box=$(tool_sandbox "$WORK/box-ssh" ssh-keygen)
    serve_signed "$ssh_box" "$sig_dir/release.json" "$ssh_dir/release.json.sshsig"
    out=$(verify_with "$ssh_box" "$test_pub" "$test_ssh_pub")
    check "a machine with ssh-keygen and no openssl verifies a correctly signed release" \
      grep -q "SHA256:$payload_sha" <<<"$out"

    # A genuinely signed manifest for ANOTHER version, served where the requested one belongs:
    # the signature verifies, and only the version it signs gives the substitution away.
    sed 's/"version":"9.9.9"/"version":"9.9.8"/' "$sig_dir/release.json" > "$ssh_dir/older.json"
    ssh-keygen -Y sign -q -n varsafe-release@varsafe.dev -f "$ssh_dir/key" "$ssh_dir/older.json"
    serve_signed "$ssh_box" "$ssh_dir/older.json" "$ssh_dir/older.json.sig"
    out=$(verify_with "$ssh_box" "$test_pub" "$test_ssh_pub")
    check "a genuinely signed manifest for another version is refused (no replay under its path)" \
      grep -q "is for version '9.9.8'" <<<"$out"

    # A signature under a key that is not ours, published where the real one goes. The raw
    # signature served alongside it IS valid: a verifier chain that fell through to the second
    # encoding after the first refused would install this.
    ssh-keygen -q -t ed25519 -N '' -C 'impostor' -f "$ssh_dir/impostor"
    cp "$sig_dir/release.json" "$ssh_dir/impostor-release.json"
    ssh-keygen -Y sign -q -n varsafe-release@varsafe.dev -f "$ssh_dir/impostor" \
      "$ssh_dir/impostor-release.json"
    both_box=$(tool_sandbox "$WORK/box-both" ssh-keygen openssl)
    serve_signed "$both_box" "$sig_dir/release.json" \
      "$ssh_dir/impostor-release.json.sig" "$sig_dir/sig.b64"
    impostor_out=$(verify_with "$both_box" "$test_pub" "$test_ssh_pub")
    check "an SSHSIG signed by another key is REFUSED even though the raw signature is valid" \
      grep -qi "tampered" <<<"$impostor_out"

    # Same key, wrong namespace: a signature made for some other purpose must not be accepted
    # here just because the bytes and the signer match.
    cp "$sig_dir/release.json" "$ssh_dir/other-namespace.json"
    ssh-keygen -Y sign -q -n some-other-namespace -f "$ssh_dir/key" "$ssh_dir/other-namespace.json"
    serve_signed "$ssh_box" "$sig_dir/release.json" "$ssh_dir/other-namespace.json.sig"
    namespace_out=$(verify_with "$ssh_box" "$test_pub" "$test_ssh_pub")
    check "an SSHSIG made under a different namespace is REFUSED" \
      grep -qi "tampered" <<<"$namespace_out"

  # The two cases below fall back TO the raw signature, so they need a raw-signature fixture —
  # which a host whose openssl cannot sign Ed25519 cannot produce. That is the same honest gap the
  # raw-signature cases report, not a property of the installer.
  if [[ ! -s "$sig_dir/sig.b64" ]]; then
    skip "raw-signature fallback cases: no raw signature fixture on this host"
  else
    # OpenSSH older than SSHSIG (RHEL/CentOS era) has ssh-keygen but no `-Y`. That is a verifier
    # this machine does not have, not evidence about the release: the raw signature still verifies.
    old_ssh_box=$(tool_sandbox "$WORK/box-old-ssh" openssl)
    cat > "$old_ssh_box/ssh-keygen" <<'OLDSSH'
#!/bin/sh
case "$1" in
  -Y) echo "ssh-keygen: unknown option -- Y" >&2; exit 255 ;;
esac
exit 0
OLDSSH
    chmod +x "$old_ssh_box/ssh-keygen"
    serve_signed "$old_ssh_box" "$sig_dir/release.json" "$ssh_dir/release.json.sshsig" \
      "$sig_dir/sig.b64"
    old_ssh_out=$(verify_with "$old_ssh_box" "$test_pub" "$test_ssh_pub")
    old_ssh_rc=$?
    check "an ssh-keygen too old for SSHSIG falls back to the raw signature instead of refusing" \
      test "$old_ssh_rc" -eq 0
    check "and it does not accuse the release of being tampered with" \
      not grep -qi "tampered" <<<"$old_ssh_out"

    # A release published before SSHSIG existed has no .sshsig at all; the raw signature carries it.
    no_sshsig_box=$(tool_sandbox "$WORK/box-no-sshsig" ssh-keygen openssl)
    serve_signed "$no_sshsig_box" "$sig_dir/release.json" "" "$sig_dir/sig.b64"
    verify_with "$no_sshsig_box" "$test_pub" "$test_ssh_pub" >/dev/null 2>&1
    check "a release that publishes no SSHSIG still verifies through the raw signature" \
      test $? -eq 0
  fi

  # One trust anchor, two encodings: the OpenSSH string must carry exactly the pinned raw key.
  # Decoded with whichever base64 the host has (see file_mode/b64_decode above) — this case must
  # run on machines with no usable openssl, which is the whole reason the OpenSSH encoding exists.
  ssh_pinned=$(sed -n 's/^RELEASE_SIGNING_SSH_PUBLIC_KEY="ssh-ed25519 \(.*\)"$/\1/p' \
    "$REPO_ROOT/install.sh")
  check "installer pins the release key in OpenSSH form too" test -n "$ssh_pinned"
  check "the OpenSSH form decodes to the same 32-byte key the CLI updater verifies against" \
    test "$(printf '%s' "$ssh_pinned" | b64_decode | tail -c 32 | b64_encode)" = "$install_key"
fi

# ---------------------------------------------------------------------------
# How every download is made
#
# With --retry, a transfer that fails midway is retried, and only a file curl opened itself can be
# rewound: a body already written to stdout or a shell redirect stays, the retry is appended, and
# the manifest then fails its signature — read as tampering. ~/.curlrc must not get a say either.
# ---------------------------------------------------------------------------
argv_box="$WORK/box-argv"; mkdir -p "$argv_box"
printf '#!/bin/sh\nfor a in "$@"; do echo "$a"; done > %s/argv\n' "$argv_box" > "$argv_box/curl"
chmod +x "$argv_box/curl"
( PATH="$argv_box:$PATH"; . "$REPO_ROOT/install.sh"; download https://example.invalid/x "$WORK/dl-dest" ) \
  >/dev/null 2>&1
check "downloads ignore ~/.curlrc (-q comes first)" test "$(head -1 "$argv_box/argv")" = "-q"
retried_into_own_file() {
  grep -qx -- "--retry" "$argv_box/argv" &&
    test "$(grep -x -A1 -- '-o' "$argv_box/argv" | tail -1)" = "$WORK/dl-dest"
}
check "downloads are retried only into the file curl was given (-o), never through stdout" \
  retried_into_own_file

# The exit status of a binary that cannot start is a hint worth naming: bash reports 127 when the
# kernel cannot load an ELF at all, its loader missing — a 32-bit OS on a 64-bit CPU, say. (A script
# with a missing interpreter is 126 instead, so the stand-in reports the status itself.)
printf '#!/bin/sh\necho "cannot execute: required file not found" >&2\nexit 127\n' > "$WORK/no-loader"
chmod +x "$WORK/no-loader"
out=$( ( . "$REPO_ROOT/install.sh"; smoke_test_binary "$WORK/no-loader" linux-arm64 ) 2>&1 )
check "a binary the system cannot load is refused with a possible cause" \
  grep -q "Possible cause: this system cannot load linux-arm64 binaries" <<<"$out"

# ---------------------------------------------------------------------------
# The whole installer, end to end, against a fake CDN
#
# Everything above drives single functions. These run install.sh as `bash install.sh` does, against
# a CDN this suite controls — real signatures, a real binary that runs, a real install directory and
# rc file — so what main() wires together is under test too: that the manifest is verified BEFORE
# the binary is fetched, that a refusal installs nothing and leaves nothing behind, and that a re-run
# converges instead of accumulating.
#
# The release key is pinned in install.sh, so these run a copy with a throwaway key in its place,
# checked to differ from install.sh in that line and no other.
# ---------------------------------------------------------------------------
if ! command -v ssh-keygen >/dev/null 2>&1 || ssh-keygen -Y verify 2>&1 | grep -qi "unknown option"; then
  skip "end-to-end installs: no ssh-keygen with -Y to sign the fixtures (needs OpenSSH 8.1+)"
else
  e2e="$WORK/e2e"; mkdir -p "$e2e/tmp"
  ssh-keygen -q -t ed25519 -N '' -C 'installer-e2e' -f "$e2e/key"
  e2e_installer="$e2e/install.sh"
  sed "s|^RELEASE_SIGNING_SSH_PUBLIC_KEY=.*|RELEASE_SIGNING_SSH_PUBLIC_KEY=\"$(cut -d' ' -f1,2 < "$e2e/key.pub")\"|" \
    "$REPO_ROOT/install.sh" > "$e2e_installer"
  # Compared without diff, whose default output format differs between GNU and BusyBox.
  key_line='^RELEASE_SIGNING_SSH_PUBLIC_KEY='
  only_key_differs() {
    [[ "$(grep -v "$key_line" "$REPO_ROOT/install.sh")" == "$(grep -v "$key_line" "$e2e_installer")" ]] &&
      [[ "$(grep "$key_line" "$REPO_ROOT/install.sh")" != "$(grep "$key_line" "$e2e_installer")" ]]
  }
  check "the end-to-end installer differs from install.sh only in its pinned key" only_key_differs

  # A binary that runs anywhere and reports the version it claims to be, and one that does not match.
  printf '#!/bin/sh\necho 9.9.9\n' > "$e2e/varsafe"
  printf '#!/bin/sh\necho trojan\n' > "$e2e/trojan"
  printf '9.9.9\n' > "$e2e/version.txt"
  e2e_artifacts="varsafe-linux-x64 varsafe-linux-x64-musl varsafe-linux-arm64 varsafe-linux-arm64-musl varsafe-darwin-x64 varsafe-darwin-arm64"

  # A signed release directory: release.json for version $2 listing $3's checksum for every artifact.
  e2e_release() {
    local dir="$1" version="$2" sha name sep=""
    sha=$(sha256_portable "$3")
    mkdir -p "$dir"
    {
      printf '{"version":"%s","checksums":{' "$version"
      for name in $e2e_artifacts; do printf '%s"%s":"%s"' "$sep" "$name" "$sha"; sep=","; done
      printf '}}\n'
    } > "$dir/release.json"
    ssh-keygen -Y sign -q -n varsafe-release@varsafe.dev -f "$e2e/key" "$dir/release.json"
    mv "$dir/release.json.sig" "$dir/release.json.sshsig"
  }
  # A CDN in $1 serving latest=9.9.9, release directory $2 under /v9.9.9/, and binary $3.
  e2e_cdn() {
    local dir="$1" rel="$2" bin="$3" name routes=()
    routes=(latest/version.txt "$e2e/version.txt" v9.9.9/release.json "$rel/release.json"
      v9.9.9/release.json.sshsig "$rel/release.json.sshsig")
    for name in $e2e_artifacts; do routes+=("v9.9.9/$name" "$bin"); done
    fake_cdn "$dir" "${routes[@]}"
  }
  # One installer run for HOME=$1 against CDN $2, with any further NAME=value exported. getconf
  # answers glibc so that a musl CI host does not stop at the libstdc++ prerequisite.
  mkdir -p "$e2e/tools"
  printf '#!/bin/sh\necho "glibc 2.36"\n' > "$e2e/tools/getconf"; chmod +x "$e2e/tools/getconf"
  # BASH_POSIX_FLAGS set runs it the way macOS's /bin/sh would: bash in POSIX mode, with xpg_echo.
  e2e_run() {
    local home="$1" cdn="$2"; shift 2
    local shell_flags=()
    if [[ -n "${BASH_POSIX_FLAGS:-}" ]]; then shell_flags=(--posix -O xpg_echo); fi
    mkdir -p "$home"
    ( export HOME="$home" SHELL=/bin/bash TMPDIR="$e2e/tmp"
      unset VARSAFE_INSTALL_DIR VARSAFE_VERSION ZDOTDIR BASH_POSIX_FLAGS
      while [[ $# -gt 0 ]]; do export "${1?}"; shift; done
      PATH="$cdn:$e2e/tools:$PATH" "$BASH" ${shell_flags[@]+"${shell_flags[@]}"} "$e2e_installer" ) </dev/null 2>&1
  }

  e2e_release "$e2e/rel" 9.9.9 "$e2e/varsafe"
  e2e_cdn "$e2e/cdn" "$e2e/rel" "$e2e/varsafe"
  home="$WORK/e2e-home"
  out=$(e2e_run "$home" "$e2e/cdn"); rc=$?
  check "a signed release installs end to end" test "$rc" -eq 0
  check "the installed binary runs and is the version installed" \
    test "$("$home/.varsafe/bin/varsafe" --version 2>/dev/null)" = "9.9.9"
  check "the install reports the version it put in place" \
    grep -q "Installed varsafe 9.9.9 to $home/.varsafe/bin/varsafe" <<<"$out"
  check "the install directory is added to PATH" grep -q '.varsafe/bin' "$home/.bashrc"
  out=$(e2e_run "$home" "$e2e/cdn"); rc=$?
  check "re-running over an install succeeds" test "$rc" -eq 0
  check "and leaves exactly one PATH line" test "$(grep -c '.varsafe/bin' "$home/.bashrc")" = "1"

  # `curl … | sh` on macOS runs this file in /bin/sh — bash in POSIX mode, where echo honours
  # backslashes and takes no options, so every `echo -e` message began with a literal "-e".
  out=$(BASH_POSIX_FLAGS=1 e2e_run "$WORK/e2e-posix" "$e2e/cdn"); rc=$?
  check "under macOS's /bin/sh (bash --posix, xpg_echo) a signed release installs" test "$rc" -eq 0
  check "and no message starts with a stray -e" not grep -q -- '^-e ' <<<"$out"

  # The same manifest, but the CDN serves other bytes as the binary: a refusal, after which the
  # working install from above must be untouched and nothing must be left beside it.
  e2e_cdn "$e2e/cdn-trojan" "$e2e/rel" "$e2e/trojan"
  out=$(e2e_run "$home" "$e2e/cdn-trojan"); rc=$?
  check "a binary that does not match the signed checksum is refused" \
    grep -q "Checksum mismatch" <<<"$out"
  check "and the existing install is left exactly as it was" \
    test "$("$home/.varsafe/bin/varsafe" --version 2>/dev/null)" = "9.9.9"
  check "and no partial download is left in the install directory" \
    test "$(ls -A "$home/.varsafe/bin")" = "varsafe"

  # A genuinely signed manifest for an older release, served where 9.9.9's belongs.
  e2e_release "$e2e/rel-older" 9.9.8 "$e2e/varsafe"
  e2e_cdn "$e2e/cdn-replay" "$e2e/rel-older" "$e2e/varsafe"
  out=$(e2e_run "$WORK/e2e-replay" "$e2e/cdn-replay")
  check "an older signed release served as 9.9.9 is refused" grep -q "is for version '9.9.8'" <<<"$out"
  check "and its binary is never downloaded" not grep -q '/varsafe-' "$e2e/cdn-replay/requests"

  # A manifest altered after signing: refused before the binary is fetched, so a machine is never
  # made to download 90 MB for a release it was always going to reject.
  mkdir -p "$e2e/rel-tampered"
  sed 's/"version":"9.9.9"/"version":"9.9.9" /' "$e2e/rel/release.json" > "$e2e/rel-tampered/release.json"
  cp "$e2e/rel/release.json.sshsig" "$e2e/rel-tampered/"
  e2e_cdn "$e2e/cdn-tampered" "$e2e/rel-tampered" "$e2e/varsafe"
  out=$(e2e_run "$WORK/e2e-tampered" "$e2e/cdn-tampered"); rc=$?
  check "a manifest altered after signing is refused as tampered" grep -q "tampered" <<<"$out"
  check "before the binary is downloaded" not grep -q '/varsafe-' "$e2e/cdn-tampered/requests"
  check "and nothing is installed" not test -e "$WORK/e2e-tampered/.varsafe/bin/varsafe"

  # A pinned version that was never published has no manifest: say so, before any binary.
  e2e_cdn "$e2e/cdn-missing" "$e2e/rel" "$e2e/varsafe"
  out=$(e2e_run "$WORK/e2e-missing" "$e2e/cdn-missing" VARSAFE_VERSION=9.9.7)
  check "a pinned version with no release is refused, naming the version" \
    grep -q "Could not fetch the release manifest for v9.9.7" <<<"$out"
  check "and nothing is requested for it beyond that manifest" \
    test "$(cat "$e2e/cdn-missing/requests")" = "https://releases.varsafe.dev/cli/v9.9.7/release.json"

  check "no run leaves its scratch directory behind" \
    test -z "$(ls -A "$e2e/tmp")"
fi

echo ""
echo "$PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -eq 0 ]]
