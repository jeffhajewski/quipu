#!/usr/bin/env bash
set -euo pipefail

repo_url="${QUIPU_REPO:-https://github.com/jeffhajewski/quipu.git}"
repo_ref="${QUIPU_REF:-main}"
prefix="${QUIPU_PREFIX:-$HOME/.quipu}"
bin_dir="${QUIPU_BIN_DIR:-$prefix/bin}"
with_lattice="${QUIPU_WITH_LATTICE:-1}"
lattice_version="${QUIPU_LATTICE_VERSION:-0.6.0}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'quipu install: missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

platform() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os:$arch" in
    Darwin:arm64) printf 'aarch64-macos' ;;
    Darwin:x86_64) printf 'x86_64-macos' ;;
    Linux:aarch64 | Linux:arm64) printf 'aarch64-linux-gnu' ;;
    Linux:x86_64) printf 'x86_64-linux-gnu' ;;
    *)
      printf 'quipu install: unsupported platform %s/%s\n' "$os" "$arch" >&2
      exit 1
      ;;
  esac
}

sha256_check() {
  local sums_file="$1"
  local archive_name="$2"
  if command -v sha256sum >/dev/null 2>&1; then
    grep "  $archive_name$" "$sums_file" | sha256sum -c -
  else
    grep "  $archive_name$" "$sums_file" | shasum -a 256 -c -
  fi
}

install_lattice() {
  need curl
  need tar

  local target archive archive_url release_url opt_dir tmp_dir
  target="$(platform)"
  archive="latticedb-$lattice_version-$target.tar.gz"
  release_url="https://github.com/jeffhajewski/latticedb/releases/download/v$lattice_version"
  archive_url="$release_url/$archive"
  opt_dir="$prefix/opt"
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN

  mkdir -p "$opt_dir"
  if [ -d "$opt_dir/latticedb-$lattice_version" ]; then
    printf '%s\n' "$opt_dir/latticedb-$lattice_version"
    return
  fi

  printf 'Downloading LatticeDB %s (%s)...\n' "$lattice_version" "$target" >&2
  curl -fsSL "$archive_url" -o "$tmp_dir/$archive"
  curl -fsSL "$release_url/SHA256SUMS" -o "$tmp_dir/SHA256SUMS"
  (cd "$tmp_dir" && sha256_check "SHA256SUMS" "$archive" >&2)
  tar -xzf "$tmp_dir/$archive" -C "$opt_dir"
  printf '%s\n' "$opt_dir/latticedb-$lattice_version"
}

need git
need zig

mkdir -p "$bin_dir"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

printf 'Cloning Quipu (%s)...\n' "$repo_ref"
git clone --depth 1 "$repo_url" "$work_dir/quipu" >/dev/null
(
  cd "$work_dir/quipu"
  if [ "$repo_ref" != "main" ]; then
    git fetch --depth 1 origin "$repo_ref" >/dev/null
    git checkout FETCH_HEAD >/dev/null
  fi
)

build_args=(zig build)
if [ "$with_lattice" != "0" ]; then
  lattice_home="$(install_lattice)"
  build_args+=(
    -Denable-lattice=true
    "-Dlattice-include=$lattice_home/include"
    "-Dlattice-lib=$lattice_home/lib"
  )
fi

printf 'Building quipu...\n'
(
  cd "$work_dir/quipu/core"
  ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$prefix/zig-cache}" "${build_args[@]}"
)

cp "$work_dir/quipu/core/zig-out/bin/quipu" "$bin_dir/quipu"
chmod 0755 "$bin_dir/quipu"

printf '\nInstalled quipu to %s\n' "$bin_dir/quipu"
printf 'Add this to your shell profile if needed:\n'
printf '  export PATH="%s:$PATH"\n' "$bin_dir"
printf '\nTry it:\n'
printf '  %s/quipu --db %s/memory.lattice health\n' "$bin_dir" "$prefix"
