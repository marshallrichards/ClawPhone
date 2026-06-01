# Running Antigravity CLI on Termux

This repo includes an installer for running Google's Linux ARM64 Antigravity CLI (`agy`) directly from Termux on Android.

The goal is native Termux first: no `proot-distro`, no VM, no Cloud Shell. The wrapper does use `proot` by default, but only as a tiny filesystem bind so the glibc/Go process can see Termux's DNS config at `/etc/resolv.conf`.

Shoutout to [Brajesh](https://github.com/Brajesh2022) for making and sharing the [original working Termux setup](https://gist.github.com/Brajesh2022/e42160d29b55417db6c18c52dd1d6d37) this script is based on. This version packages those fixes into one installer so people can set it up, update it, or uninstall it without doing every step by hand.

## Quick Install

From Termux on an ARM64 Android phone:

```bash
curl -fsSL https://raw.githubusercontent.com/marshallrichards/ClawPhone/main/scripts/install-antigravity-termux.sh | bash
source ~/.bashrc
agy --version
```

You can also run it from a cloned checkout:

```bash
bash scripts/install-antigravity-termux.sh
```

Useful options:

```bash
bash scripts/install-antigravity-termux.sh --force
bash scripts/install-antigravity-termux.sh --skip-official-install
bash scripts/install-antigravity-termux.sh --no-shell-rc
bash scripts/install-antigravity-termux.sh --uninstall
bash scripts/install-antigravity-termux.sh --uninstall --remove-official
```

When installing from the raw GitHub URL, pass options through `bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/marshallrichards/ClawPhone/main/scripts/install-antigravity-termux.sh | bash -s -- --uninstall
```

## What Gets Installed

The installer creates this layout:

```text
~/.local/bin/agy                         official Antigravity binary, unchanged
~/.local/bin/agy.va39                    patched binary
~/.local/bin/agy-va39                    Termux launcher wrapper
~/.local/lib/agy-glibc/libc.so           shim symlink to real glibc libc.so.6
~/.local/lib/agy-glibc/libc.so.6         shim symlink to real glibc libc.so.6
~/.local/share/agentphone/agy-termux/    patcher and install state
```

It also adds a managed block to `~/.bashrc`:

```bash
export PATH="$HOME/.local/bin:$HOME/bin:$PATH"

agy() {
  hash -r 2>/dev/null || true
  command agy-va39 "$@"
}
```

## What Each Step Fixes

The official Antigravity Linux ARM64 binary is built for a normal glibc Linux environment. Termux is Android userspace with Bionic libc, Android filesystem layout, and Android syscall/security behavior. These are the main fixes.

### 1. Termux Packages

The script installs:

```bash
pkg install -y python proot curl ca-certificates
pkg install -y glibc-repo glibc-runner
```

`python` runs the binary patcher. `curl` downloads Google's official installer. `ca-certificates` provides the TLS root bundle. `proot` is used only for the DNS bind described below. `glibc-runner` provides the glibc loader and libraries under:

```text
/data/data/com.termux/files/usr/glibc/lib
```

### 2. Official `agy`

The script runs Google's official installer if `~/.local/bin/agy` does not already exist:

```bash
curl -fsSL https://antigravity.google/cli/install.sh | bash
```

The original binary stays untouched. The patched copy is written to `~/.local/bin/agy.va39`.

### 3. VA39 TCMalloc Patch

Many Android phones expose a 39-bit userspace virtual address layout. The Antigravity binary's TCMalloc code assumes a 48-bit ARM64 userspace layout. On affected phones, startup can fail before the CLI really begins:

```text
MmapAligned() failed - unable to allocate with tag
TCMalloc assumes a 48-bit virtual address space size
```

The patcher scans the `google_malloc` section and rewrites the relevant ARM64 instruction patterns:

- tag extraction/insertion moves from bit 42 to bit 35
- random mmap address masks are reduced to 39 bits
- the mmap upper bound changes from `1 << 48` to `1 << 39`
- inlined tag and deallocation masks are rewritten for the lower VA layout

The scanner is pattern-based instead of offset-based, so it can survive ordinary binary layout changes. Before it writes the patched binary, it now requires the input SHA256 and observed patch counts to match a known compatibility profile.

The current profile is for Antigravity CLI `1.0.3` `linux_arm64`:

```text
input SHA256: 71d038c419221f858db992348e849e10263df9b67d37d13cff3515aef3cf7dea
```

```text
ubfx patches: 15
lsl patches: 2
random mask pairs: 3
mmap upper-bound patches: 1
faccessat2 syscall rewrites: 1
tag constants: 108
```

If the binary SHA or counts drift, the script prints the input SHA256 and observed counts, then refuses to write `agy.va39`. Update the patch profile for the new release, or set `AGENTPHONE_AGY_ALLOW_UNVERIFIED_PATCH=1` only if you have manually reviewed the new binary and want to test an unverified profile.

### 4. `faccessat2` Syscall Patch

Go can use the newer `faccessat2` syscall while resolving executables. Android seccomp may block that syscall and kill the process with `SIGSYS`.

The patcher rewrites that syscall number from `faccessat2` to the older `faccessat`, which is enough for the path checks Antigravity needs in Termux.

### 5. glibc `libc.so` Shim

Some glibc layouts use `libc.so` as a linker script rather than a real ELF shared object. If the loader or program tries to load it directly, you can get:

```text
invalid ELF header
```

The installer creates:

```text
~/.local/lib/agy-glibc/libc.so -> /data/data/com.termux/files/usr/glibc/lib/libc.so.6
```

The wrapper puts that shim directory first in glibc's `--library-path`.

### 6. Clean glibc Process Environment

Termux may set `LD_PRELOAD` for Bionic features such as `libtermux-exec-ld-preload.so`. That library is for Android's Bionic libc, not glibc, so preloading it into Antigravity can break symbol resolution.

The wrapper clears:

```sh
unset LD_PRELOAD
unset LD_LIBRARY_PATH
```

This keeps Termux/Bionic libraries from polluting the glibc process.

### 7. DNS Resolver

Go's resolver expects `/etc/resolv.conf` on Unix-like systems. In Termux, the resolver file normally lives here instead:

```text
/data/data/com.termux/files/usr/etc/resolv.conf
```

Without a readable `/etc/resolv.conf`, the CLI can try bad defaults such as `[::1]:53`.

The wrapper uses:

```sh
proot -b /data/data/com.termux/files/usr/etc/resolv.conf:/etc/resolv.conf
```

That makes the Termux resolver config appear at the exact path the glibc/Go binary expects.

### 8. TLS Certificates

The glibc-loaded process may not automatically discover Termux's certificate bundle. The wrapper sets:

```sh
export SSL_CERT_FILE=/data/data/com.termux/files/usr/etc/tls/cert.pem
```

That fixes HTTPS verification for login and API calls.

### 9. Shell Hash Cache

Bash caches command lookups. If `agy` previously pointed somewhere else, the current shell can keep launching the old target.

The `agy` shell function runs `hash -r` before launching `agy-va39`. The installer verifies `agy-va39 --version` before adding or replacing this shell hook, so a failed install does not shadow the official `agy` command for new installs.

## Why `proot` Is Used

This setup is not using `proot-distro`. It is not booting Debian or Ubuntu. It uses Termux directly and launches the official glibc binary with Termux's glibc loader.

The reason `proot` is still useful is one narrow path problem: the binary wants `/etc/resolv.conf`, but Termux's resolver file is under `$PREFIX/etc/resolv.conf`. Android apps cannot normally create or replace `/etc/resolv.conf` because `/etc` belongs to the Android system image.

`proot` gives one launched process a fake view where:

```text
/etc/resolv.conf -> /data/data/com.termux/files/usr/etc/resolv.conf
```

That is enough to make Go DNS resolution work without a full Linux userspace.

## Can It Work Without `proot`?

Sometimes, yes. The generated wrapper uses the known-good `proot` DNS bind by default, but you can force the no-`proot` path:

```sh
if [ "${AGENTPHONE_AGY_NO_PROOT:-0}" = "1" ]; then
  exec "$G/ld-linux-aarch64.so.1" --library-path "$S:$G" "$B" "$@"
fi
```

```bash
AGENTPHONE_AGY_NO_PROOT=1 agy-va39 --version
```

On normal unrooted Android this usually makes DNS fail, because `/etc/resolv.conf` is missing or not the Termux resolver file.

The realistic ways around `proot` are:

- Run on an environment where `/etc/resolv.conf` already exists and points to usable DNS.
- Patch the Go resolver path inside the binary to another same-length path that Termux can provide. This is possible in theory, but it is riskier than the current patch because it touches generic runtime strings rather than Antigravity's known allocator/syscall instructions.
- Use a small native launcher or library trick that redirects `open("/etc/resolv.conf")` to Termux's resolver file. That would avoid `proot`, but it adds another compiled compatibility component.
- Get an upstream Android/Termux build that knows Termux's resolver and certificate paths.

For now, `proot` is the least invasive reliable fix. It is only used as a bind-mount compatibility shim.

## Uninstall

Run:

```bash
bash scripts/install-antigravity-termux.sh --uninstall
```

This removes the wrapper, patched binary, glibc shim, generated patcher, install state, and the managed `~/.bashrc` block.

If the official `~/.local/bin/agy` binary did not exist before this installer created it, uninstall removes it too. If it existed before, uninstall keeps it. To remove it anyway:

```bash
bash scripts/install-antigravity-termux.sh --uninstall --remove-official
```
