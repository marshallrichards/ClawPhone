#!/usr/bin/env bash
# Shoutout to Brajesh for making and sharing the working Termux setup this
# installer packages into one repeatable script.
# Original gist: https://gist.github.com/Brajesh2022/e42160d29b55417db6c18c52dd1d6d37
set -Eeuo pipefail

SCRIPT_VERSION="0.1.0"
OFFICIAL_INSTALL_URL="https://antigravity.google/cli/install.sh"

TERMUX_PREFIX_DEFAULT="/data/data/com.termux/files/usr"
TERMUX_HOME_DEFAULT="/data/data/com.termux/files/home"
TERMUX_PREFIX="${PREFIX:-$TERMUX_PREFIX_DEFAULT}"
TERMUX_HOME="${HOME:-$TERMUX_HOME_DEFAULT}"

LOCAL_BIN="$TERMUX_HOME/.local/bin"
APP_DIR="$TERMUX_HOME/.local/share/agentphone/agy-termux"
PATCHER="$APP_DIR/patch_agy_va39.py"
STATE_FILE="$APP_DIR/state"
SHIM_DIR="$TERMUX_HOME/.local/lib/agy-glibc"

AGY_ORIG="$LOCAL_BIN/agy"
AGY_PATCHED="$LOCAL_BIN/agy.va39"
WRAPPER="$LOCAL_BIN/agy-va39"

GLIBC_DIR="$TERMUX_PREFIX/glibc/lib"
GLIBC_LOADER="$GLIBC_DIR/ld-linux-aarch64.so.1"
GLIBC_LIBC="$GLIBC_DIR/libc.so.6"
TERMUX_RESOLV="$TERMUX_PREFIX/etc/resolv.conf"
TERMUX_CERT="$TERMUX_PREFIX/etc/tls/cert.pem"
BASHRC="$TERMUX_HOME/.bashrc"

ACTION="install"
FORCE="0"
INSTALL_OFFICIAL="1"
MODIFY_SHELL_RC="1"
REMOVE_OFFICIAL="0"
DRY_RUN="0"
STEP="0"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  BOLD="$(printf '\033[1m')"
  DIM="$(printf '\033[2m')"
  RED="$(printf '\033[31m')"
  GREEN="$(printf '\033[32m')"
  YELLOW="$(printf '\033[33m')"
  BLUE="$(printf '\033[34m')"
  RESET="$(printf '\033[0m')"
else
  BOLD=""
  DIM=""
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  RESET=""
fi

usage() {
  cat <<'USAGE'
AgentPhone Antigravity Termux installer

Usage:
  bash install-antigravity-termux.sh [options]
  curl -fsSL <raw-script-url> | bash
  curl -fsSL <raw-script-url> | bash -s -- [options]

Options:
  --install                 Install or update the Termux Antigravity wrapper (default)
  --uninstall               Remove files and shell hooks created by this script
  --remove-official         With --uninstall, also remove ~/.local/bin/agy
  --force                   Reinstall/repatch even if files already exist
  --skip-official-install   Do not run Google's install script; require ~/.local/bin/agy
  --no-shell-rc             Do not edit ~/.bashrc
  --dry-run                 Print what would happen without changing files
  -h, --help                Show this help

After install, open a new Termux shell or run:
  source ~/.bashrc

Then test:
  agy-va39 --version
  agy --version
USAGE
}

log() {
  printf '%b\n' "$*"
}

step() {
  STEP=$((STEP + 1))
  log ""
  log "${BLUE}${BOLD}[$(printf '%02d' "$STEP")]${RESET} ${BOLD}$*${RESET}"
}

info() {
  log "${DIM}    $*${RESET}"
}

ok() {
  log "${GREEN}    OK${RESET} $*"
}

warn() {
  log "${YELLOW}    WARN${RESET} $*" >&2
}

die() {
  log "${RED}    ERROR${RESET} $*" >&2
  exit 1
}

run() {
  info "+ $*"
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  "$@"
}

ensure_dir() {
  if [[ "$DRY_RUN" == "1" ]]; then
    info "+ mkdir -p $1"
    return 0
  fi
  mkdir -p "$1"
}

parse_args() {
  while (($#)); do
    case "$1" in
      --install)
        ACTION="install"
        ;;
      --uninstall)
        ACTION="uninstall"
        ;;
      --remove-official)
        REMOVE_OFFICIAL="1"
        ;;
      --force)
        FORCE="1"
        ;;
      --skip-official-install)
        INSTALL_OFFICIAL="0"
        ;;
      --no-shell-rc)
        MODIFY_SHELL_RC="0"
        ;;
      --dry-run)
        DRY_RUN="1"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
    shift
  done
}

require_termux() {
  step "Checking Termux environment"

  [[ -d "$TERMUX_PREFIX_DEFAULT" ]] || die "This installer is intended for Termux on Android."
  command -v pkg >/dev/null 2>&1 || die "Termux package manager 'pkg' was not found."

  local arch
  arch="$(uname -m)"
  [[ "$arch" == "aarch64" ]] || die "Antigravity's Linux ARM64 binary needs aarch64. Detected: $arch"

  ok "Termux aarch64 detected"
}

install_termux_packages() {
  step "Installing Termux dependencies"

  run pkg update -y
  run pkg install -y python proot curl ca-certificates

  if [[ ! -x "$GLIBC_LOADER" || ! -f "$GLIBC_LIBC" ]]; then
    warn "Termux glibc runtime was not found; enabling the glibc package repo."
    run pkg install -y glibc-repo
    run pkg update -y

    if ! run pkg install -y glibc-runner; then
      warn "glibc-runner install failed; trying the lower-level glibc package."
    fi

    if [[ ! -x "$GLIBC_LOADER" || ! -f "$GLIBC_LIBC" ]]; then
      run pkg install -y glibc
    fi
  fi

  command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1 || die "Python was not installed correctly."
  command -v curl >/dev/null 2>&1 || die "curl was not installed correctly."
  command -v proot >/dev/null 2>&1 || die "proot was not installed correctly."

  [[ -x "$GLIBC_LOADER" ]] || die "glibc loader is missing: $GLIBC_LOADER"
  [[ -f "$GLIBC_LIBC" ]] || die "glibc libc.so.6 is missing: $GLIBC_LIBC"
  [[ -f "$TERMUX_CERT" ]] || die "Termux CA bundle is missing: $TERMUX_CERT"

  if [[ ! -f "$TERMUX_RESOLV" ]]; then
    warn "Termux resolver file is missing; creating a conservative fallback."
    ensure_dir "$(dirname "$TERMUX_RESOLV")"
    if [[ "$DRY_RUN" != "1" ]]; then
      {
        printf 'nameserver 1.1.1.1\n'
        printf 'nameserver 8.8.8.8\n'
      } > "$TERMUX_RESOLV"
    fi
  fi

  ok "Dependencies are ready"
}

python_bin() {
  if command -v python3 >/dev/null 2>&1; then
    command -v python3
  else
    command -v python
  fi
}

install_official_agy() {
  step "Installing official Antigravity CLI"

  ensure_dir "$LOCAL_BIN"
  local official_preexisted
  official_preexisted="$(state_value official_preexisted __missing)"
  if [[ "$official_preexisted" == "__missing" ]]; then
    official_preexisted="0"
    [[ -e "$AGY_ORIG" ]] && official_preexisted="1"
  fi

  if [[ -x "$AGY_ORIG" && "$FORCE" != "1" ]]; then
    ok "Official agy already exists at $AGY_ORIG"
  elif [[ "$INSTALL_OFFICIAL" != "1" ]]; then
    die "Missing $AGY_ORIG and --skip-official-install was provided."
  else
    info "+ curl -fsSL $OFFICIAL_INSTALL_URL | bash"
    if [[ "$DRY_RUN" != "1" ]]; then
      curl -fsSL "$OFFICIAL_INSTALL_URL" | bash
    fi
  fi

  [[ "$DRY_RUN" == "1" || -x "$AGY_ORIG" ]] || die "Official agy binary was not created at $AGY_ORIG"

  ensure_dir "$APP_DIR"
  if [[ "$DRY_RUN" != "1" ]]; then
    {
      printf 'version=%q\n' "$SCRIPT_VERSION"
      printf 'installed_at=%q\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      printf 'official_preexisted=%q\n' "$official_preexisted"
    } > "$STATE_FILE"
  fi
}

write_patcher() {
  step "Writing VA39 binary patcher"

  ensure_dir "$APP_DIR"
  info "+ write $PATCHER"
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi

  cat > "$PATCHER" <<'PY'
#!/usr/bin/env python3
"""
Generalized VA39 patch for the Antigravity CLI linux_arm64 binary.

This scanner is based on the Termux compatibility work documented by
Brajesh2022 and hjotha. It changes the TCMalloc ARM64 address/tag constants
from a 48-bit userspace VA layout to the 39-bit layout commonly exposed by
Android/Termux devices, and it rewrites Go's faccessat2 syscall wrapper to
the older faccessat syscall accepted by Android seccomp.
"""

import hashlib
import os
import struct
import sys
from pathlib import Path


src = Path(sys.argv[1] if len(sys.argv) > 1 else str(Path.home() / ".local/bin/agy"))
dst = Path(str(src) + ".va39")

PATCH_PROFILES = {
    # Antigravity CLI 1.0.3 linux_arm64, from:
    # https://storage.googleapis.com/antigravity-public/antigravity-cli/1.0.3-6260531212976128/linux-arm/cli_linux_arm64.tar.gz
    "71d038c419221f858db992348e849e10263df9b67d37d13cff3515aef3cf7dea": {
        "label": "Antigravity CLI 1.0.3 linux_arm64",
        "counts": {
            "ubfx": 15,
            "lsl": 2,
            "random_mask": 3,
            "mmap_aligned": 1,
            "tag_constants": 108,
            "faccessat2": 1,
        },
    },
}
ALLOW_UNVERIFIED = os.environ.get("AGENTPHONE_AGY_ALLOW_UNVERIFIED_PATCH") == "1"

if not src.exists():
    raise SystemExit(f"Input binary does not exist: {src}")

original = src.read_bytes()
if original[:4] != b"\x7fELF":
    raise SystemExit(f"Input is not an ELF binary: {src}")
if original[4] != 2 or original[5] != 1:
    raise SystemExit("Input is not a 64-bit little-endian ELF binary")
if struct.unpack_from("<H", original, 18)[0] != 183:
    raise SystemExit("Input ELF is not AArch64/ARM64")

input_sha = hashlib.sha256(original).hexdigest()
print(f"Input binary : {src}")
print(f"SHA256 in    : {input_sha}")
print()

data = bytearray(original)


def get(off):
    return struct.unpack_from("<I", data, off)[0]


def put(off, word):
    struct.pack_into("<I", data, off, word)


lo, hi = 0, len(data)


def find_section(name_target):
    e_shoff = struct.unpack_from("<Q", data, 40)[0]
    e_shentsize = struct.unpack_from("<H", data, 58)[0]
    e_shnum = struct.unpack_from("<H", data, 60)[0]
    e_shstrndx = struct.unpack_from("<H", data, 62)[0]

    if e_shoff == 0 or e_shentsize == 0 or e_shstrndx >= e_shnum:
        return None, None

    shstr_base = e_shoff + e_shstrndx * e_shentsize
    shstr_off = struct.unpack_from("<Q", data, shstr_base + 24)[0]

    for i in range(e_shnum):
        base = e_shoff + i * e_shentsize
        sh_name = struct.unpack_from("<I", data, base)[0]
        sh_offset = struct.unpack_from("<Q", data, base + 24)[0]
        sh_size = struct.unpack_from("<Q", data, base + 32)[0]

        nend = data.index(b"\x00", shstr_off + sh_name)
        section = data[shstr_off + sh_name : nend].decode("utf-8", errors="replace")
        if section == name_target:
            return sh_offset, sh_offset + sh_size

    return None, None


sec_lo, sec_hi = find_section("google_malloc")
if sec_lo is not None:
    lo, hi = sec_lo, sec_hi
    print(f"Found google_malloc section: file 0x{lo:x} - 0x{hi:x} ({(hi - lo) // 1024} KB)")
else:
    print("google_malloc section not found - scanning entire binary.")
    print("This is slower but may still work.")
print()

# 1. ubfx #42,#3 -> #35,#3 and lsl #42 -> #35.
ubfx_count = 0
lsl_count = 0
for off in range(lo, hi - 3, 4):
    w = get(off)
    if (w & 0x7F800000) == 0x53000000:
        immr = (w >> 16) & 0x3F
        imms = (w >> 10) & 0x3F
        if immr == 42 and imms == 44:
            put(off, (w & ~((0x3F << 16) | (0x3F << 10))) | (35 << 16) | (37 << 10))
            ubfx_count += 1
        elif immr == 22 and imms == 21:
            put(off, (w & ~((0x3F << 16) | (0x3F << 10))) | (29 << 16) | (28 << 10))
            lsl_count += 1

print(f"[1] ubfx patches : {ubfx_count}  (expect around 15)")
print(f"    lsl  patches : {lsl_count}   (expect around 2)")

# 2. Random address mask pairs:
# mov x10, #-0x6c00000001; movk x10, #0, lsl #48
# -> mov x10, #-1; lsr x10, x10, #29
mask_count = 0
for off in range(lo, hi - 7, 4):
    if get(off) == 0x92D3800A and get(off + 4) == 0xF2E0000A:
        put(off, 0x9280000A)
        put(off + 4, 0xD35DFD4A)
        mask_count += 1

print(f"[2] Random mask  : {mask_count}  (expect around 3)")

# 3. MmapAlignedLocked upper bound: 1 << 48 -> 1 << 39.
mmap_count = 0
for off in range(lo, hi - 3, 4):
    if get(off) == 0xF2E00029:
        put(off, 0xD3596129)
        mmap_count += 1

print(f"[3] MmapAligned  : {mmap_count}  (expect around 1)")

# 4. Inlined tag constants and fast-path deallocation masks.
word_rewrites = {
    0xD2C20009: 0xD2C00409,
    0xD2C2000A: 0xD2C0040A,
    0xF2C20008: 0xF2DFF408,
    0xF2C20009: 0xF2DFF409,
    0xD2C10009: 0xD2C00209,
    0xD2C1000A: 0xD2C0020A,
    0xF2C38008: 0xF2DFF708,
    0xF2C38009: 0xF2DFF709,
    0x92560A6C: 0x925D0A6C,
    0x92560A6A: 0x925D0A6A,
    0xD2C3000D: 0xD2C0060D,
    0xD2C3000C: 0xD2C0060C,
    0xD2C08008: 0xD2C00108,
}
counts = {old: 0 for old in word_rewrites}
for off in range(lo, hi - 3, 4):
    w = get(off)
    if w in word_rewrites:
        put(off, word_rewrites[w])
        counts[w] += 1

tag_count = sum(counts.values())
print(f"[4] Tag constants: {tag_count} words rewritten")

# 5. Android/Termux syscall compatibility.
faccessat2_count = 0
for off in range(0, len(data) - 15, 4):
    if (
        get(off) == 0xAA1F03E5
        and get(off + 4) == 0xAA1F03E6
        and get(off + 8) == 0xD28036E0
        and (get(off + 12) & 0xFC000000) == 0x94000000
    ):
        put(off + 8, 0xD2800600)
        faccessat2_count += 1

print(f"[5] faccessat2   : {faccessat2_count} syscall wrapper rewritten")

observed_counts = {
    "ubfx": ubfx_count,
    "lsl": lsl_count,
    "random_mask": mask_count,
    "mmap_aligned": mmap_count,
    "tag_constants": tag_count,
    "faccessat2": faccessat2_count,
}

total = sum(observed_counts.values())
if total == 0:
    print()
    print("ERROR: No patches applied - binary structure may have changed.")
    print(f"Input SHA256: {input_sha}")
    print("Refusing to write the patched binary.")
    raise SystemExit(2)

profile_errors = []
profile = PATCH_PROFILES.get(input_sha)
if profile is None:
    profile_errors.append(f"unknown input SHA256: {input_sha}")
else:
    for name, expected in profile["counts"].items():
        observed = observed_counts[name]
        if observed != expected:
            profile_errors.append(f"{name}: expected {expected}, observed {observed}")
profile_verified = not profile_errors

if profile_errors:
    print()
    print("ERROR: Patch counts do not match the expected compatibility profile.")
    for error in profile_errors:
        print(f"  - {error}")
    print("Observed patch counts:")
    for name, observed in observed_counts.items():
        print(f"  - {name}: {observed}")
    print(f"Input SHA256: {input_sha}")
    print("Refusing to write the patched binary.")
    if not ALLOW_UNVERIFIED:
        print("Update PATCH_PROFILES or set AGENTPHONE_AGY_ALLOW_UNVERIFIED_PATCH=1 only after manual review.")
        raise SystemExit(3)
    print("AGENTPHONE_AGY_ALLOW_UNVERIFIED_PATCH=1 is set; writing output anyway.")

dst.write_bytes(data)
dst.chmod(0o755)

out_sha = hashlib.sha256(data).hexdigest()
print()
print(f"SHA256 out   : {out_sha}")
print(f"Output       : {dst}")
print()
if not profile_verified:
    print("Unverified patch profile accepted by override. Test with:")
else:
    print(f"Patch profile accepted: {profile['label']}. Test with:")
print()
print("  agy-va39 --version")
PY

  chmod +x "$PATCHER"
  ok "Patcher written"
}

patch_agy() {
  step "Patching Antigravity for Android VA39"

  local py
  py="$(python_bin)"
  run "$py" "$PATCHER" "$AGY_ORIG"
  [[ "$DRY_RUN" == "1" || -x "$AGY_PATCHED" ]] || die "Patched binary was not created: $AGY_PATCHED"

  ok "Patched binary is ready at $AGY_PATCHED"
}

create_glibc_shim() {
  step "Creating glibc libc.so shim"

  ensure_dir "$SHIM_DIR"
  run ln -sfn "$GLIBC_LIBC" "$SHIM_DIR/libc.so"
  run ln -sfn "$GLIBC_LIBC" "$SHIM_DIR/libc.so.6"

  ok "glibc shim points libc.so at the real libc.so.6"
}

create_wrapper() {
  step "Creating agy-va39 launcher"

  ensure_dir "$LOCAL_BIN"
  info "+ write $WRAPPER"
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi

  cat > "$WRAPPER" <<'SH'
#!/data/data/com.termux/files/usr/bin/sh
P=/data/data/com.termux/files/usr
H=${HOME:-/data/data/com.termux/files/home}
G=$P/glibc/lib
S=$H/.local/lib/agy-glibc
B=$H/.local/bin/agy.va39

unset LD_PRELOAD
unset LD_LIBRARY_PATH
export GODEBUG=netdns=go
export SSL_CERT_FILE=$P/etc/tls/cert.pem

if [ "${AGENTPHONE_AGY_VERBOSE:-0}" = "1" ]; then
  echo "agy-va39: launching patched Antigravity CLI" >&2
fi

if [ "${AGENTPHONE_AGY_NO_PROOT:-0}" = "1" ]; then
  exec "$G/ld-linux-aarch64.so.1" --library-path "$S:$G" "$B" "$@"
fi

exec "$P/bin/proot" \
  -b "$P/etc/resolv.conf:/etc/resolv.conf" \
  "$G/ld-linux-aarch64.so.1" --library-path "$S:$G" \
  "$B" "$@"
SH

  chmod +x "$WRAPPER"
  ok "Wrapper created at $WRAPPER"
}

remove_managed_block() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  local tmp
  tmp="$(mktemp)"
  awk '
    /^# >>> agentphone agy termux$/ { skip = 1; next }
    /^# <<< agentphone agy termux$/ { skip = 0; next }
    !skip { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

install_shell_shortcuts() {
  if [[ "$MODIFY_SHELL_RC" != "1" ]]; then
    warn "Skipping ~/.bashrc changes because --no-shell-rc was provided."
    return 0
  fi

  step "Adding shell shortcuts"

  if [[ "$DRY_RUN" == "1" ]]; then
    info "+ update $BASHRC"
    return 0
  fi

  touch "$BASHRC"
  remove_managed_block "$BASHRC"
  cat >> "$BASHRC" <<'RC'

# >>> agentphone agy termux
export PATH="$HOME/.local/bin:$HOME/bin:$PATH"

agy() {
  hash -r 2>/dev/null || true
  command agy-va39 "$@"
}
# <<< agentphone agy termux
RC

  ok "Added agy function to $BASHRC"
}

verify_install() {
  step "Verifying wrapper"

  if [[ "$DRY_RUN" == "1" ]]; then
    info "+ $WRAPPER --version"
    return 0
  fi

  "$WRAPPER" --version || die "agy-va39 --version failed. Re-run with AGENTPHONE_AGY_VERBOSE=1 agy-va39 --version for more detail."
  ok "agy-va39 starts successfully"
}

state_value() {
  local key="$1"
  local default="$2"

  if [[ -f "$STATE_FILE" ]]; then
    local line
    line="$(grep -E "^${key}=" "$STATE_FILE" 2>/dev/null | tail -n 1 || true)"
    if [[ -n "$line" ]]; then
      printf '%s\n' "${line#*=}"
      return 0
    fi
  fi

  printf '%s\n' "$default"
}

uninstall() {
  step "Removing AgentPhone Antigravity files"

  run rm -f "$WRAPPER" "$AGY_PATCHED"
  run rm -rf "$SHIM_DIR"

  if [[ "$MODIFY_SHELL_RC" == "1" ]]; then
    info "+ remove managed block from $BASHRC"
    if [[ "$DRY_RUN" != "1" ]]; then
      remove_managed_block "$BASHRC"
    fi
  fi

  local official_preexisted
  official_preexisted="$(state_value official_preexisted 1)"

  if [[ "$REMOVE_OFFICIAL" == "1" || "$official_preexisted" == "0" ]]; then
    run rm -f "$AGY_ORIG"
  else
    info "Keeping official binary at $AGY_ORIG"
    info "Use --uninstall --remove-official if you want that removed too."
  fi

  run rm -rf "$APP_DIR"
  if [[ "$DRY_RUN" != "1" ]]; then
    rmdir "$TERMUX_HOME/.local/share/agentphone" 2>/dev/null || true
  fi

  ok "Uninstall complete"
}

install() {
  log "${BOLD}AgentPhone Antigravity Termux installer${RESET} ${DIM}v$SCRIPT_VERSION${RESET}"
  require_termux
  install_termux_packages
  install_official_agy
  write_patcher
  patch_agy
  create_glibc_shim
  create_wrapper
  verify_install
  install_shell_shortcuts

  log ""
  ok "Done. Open a new shell or run: source ~/.bashrc"
  info "Commands: agy-va39, agy"
  info "Uninstall: bash install-antigravity-termux.sh --uninstall"
}

main() {
  parse_args "$@"
  case "$ACTION" in
    install)
      install
      ;;
    uninstall)
      log "${BOLD}AgentPhone Antigravity Termux uninstaller${RESET} ${DIM}v$SCRIPT_VERSION${RESET}"
      require_termux
      uninstall
      ;;
    *)
      die "Unknown action: $ACTION"
      ;;
  esac
}

main "$@"
