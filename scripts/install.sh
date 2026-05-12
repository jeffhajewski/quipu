#!/usr/bin/env bash
set -euo pipefail

repo_url="${QUIPU_REPO:-https://github.com/jeffhajewski/quipu.git}"
repo_ref="${QUIPU_REF:-main}"
prefix="${QUIPU_PREFIX:-$HOME/.quipu}"
bin_dir="${QUIPU_BIN_DIR:-$prefix/bin}"
with_lattice="${QUIPU_WITH_LATTICE:-1}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'quipu install: missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

need git
need zig

lattice_include_dir() {
  if [ -n "${LATTICE_INCLUDE:-}" ] && [ -f "$LATTICE_INCLUDE/lattice.h" ]; then
    printf '%s\n' "$LATTICE_INCLUDE"
    return
  fi
  if [ -n "${LATTICE_PREFIX:-}" ] && [ -f "$LATTICE_PREFIX/include/lattice.h" ]; then
    printf '%s\n' "$LATTICE_PREFIX/include"
    return
  fi
  for dir in /usr/local/include /opt/homebrew/include "$HOME/.local/include"; do
    if [ -f "$dir/lattice.h" ]; then
      printf '%s\n' "$dir"
      return
    fi
  done
  printf 'quipu install: could not find system lattice.h; set LATTICE_INCLUDE or LATTICE_PREFIX\n' >&2
  exit 1
}

lattice_lib_dir() {
  if [ -n "${LATTICE_LIB_DIR:-}" ] && ls "$LATTICE_LIB_DIR"/liblattice.* >/dev/null 2>&1; then
    printf '%s\n' "$LATTICE_LIB_DIR"
    return
  fi
  if [ -n "${LATTICE_LIB_PATH:-}" ] && [ -f "$LATTICE_LIB_PATH" ]; then
    dirname "$LATTICE_LIB_PATH"
    return
  fi
  if [ -n "${LATTICE_PREFIX:-}" ] && ls "$LATTICE_PREFIX"/lib/liblattice.* >/dev/null 2>&1; then
    printf '%s\n' "$LATTICE_PREFIX/lib"
    return
  fi
  for dir in /usr/local/lib /opt/homebrew/lib "$HOME/.local/lib"; do
    if ls "$dir"/liblattice.* >/dev/null 2>&1; then
      printf '%s\n' "$dir"
      return
    fi
  done
  printf 'quipu install: could not find system liblattice; set LATTICE_LIB_DIR, LATTICE_LIB_PATH, or LATTICE_PREFIX\n' >&2
  exit 1
}

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
  lattice_include="$(lattice_include_dir)"
  lattice_lib="$(lattice_lib_dir)"
  build_args+=(
    -Denable-lattice=true
    "-Dlattice-include=$lattice_include"
    "-Dlattice-lib=$lattice_lib"
  )
else
  build_args+=(-Denable-lattice=false)
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
