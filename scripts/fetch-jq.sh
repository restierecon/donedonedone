#!/bin/bash

JQ_VERSION="1.8.1"

die() { echo "fetch-jq.sh: $*" >&2; exit 1; }

usage="usage: fetch-jq.sh <dest-dir> [--url <url> --sha256 <hex>]"
[ $# -ge 1 ] || die "$usage"
dest="$1"; shift
url="" sum=""
while [ $# -gt 0 ]; do
  case "$1" in
    --url) url="${2:-}"; shift 2 || die "$usage" ;;
    --sha256) sum="${2:-}"; shift 2 || die "$usage" ;;
    *) die "$usage" ;;
  esac
done
if [ -n "$url$sum" ] && { [ -z "$url" ] || [ -z "$sum" ]; }; then
  die "--url and --sha256 go together"
fi

ext=""
case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=macos ;;
  MINGW*|MSYS*|CYGWIN*) os=windows ext=".exe" ;;
  *) die "no jq $JQ_VERSION build for $(uname -s); install jq yourself" ;;
esac
case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) die "no jq $JQ_VERSION build for $(uname -m); install jq yourself" ;;
esac
[ "$os" = windows ] && arch=amd64
asset="jq-$os-$arch$ext"

if [ -z "$url" ]; then
  case "$asset" in
    jq-linux-amd64)       sum=020468de7539ce70ef1bceaf7cde2e8c4f2ca6c3afb84642aabc5c97d9fc2a0d ;;
    jq-linux-arm64)       sum=6bc62f25981328edd3cfcfe6fe51b073f2d7e7710d7ef7fcdac28d4e384fc3d4 ;;
    jq-macos-amd64)       sum=e80dbe0d2a2597e3c11c404f03337b981d74b4a8504b70586c354b7697a7c27f ;;
    jq-macos-arm64)       sum=a9fe3ea2f86dfc72f6728417521ec9067b343277152b114f4e98d8cb0e263603 ;;
    jq-windows-amd64.exe) sum=23cb60a1354eed6bcc8d9b9735e8c7b388cd1fdcb75726b93bc299ef22dd9334 ;;
    *) die "no pinned checksum for $asset" ;;
  esac
  url="https://github.com/jqlang/jq/releases/download/jq-$JQ_VERSION/$asset"
fi

if command -v sha256sum >/dev/null 2>&1; then
  sha256_of() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  die "neither sha256sum nor shasum is available, so the download can't be verified; install jq yourself"
fi

mkdir -p "$dest" || die "can't create $dest"
tmp="$dest/.jq-download.$$$ext"
trap 'rm -f "$tmp"' EXIT

if command -v curl >/dev/null 2>&1; then
  curl -fsSL --retry 2 -o "$tmp" "$url" || die "download failed: $url"
elif command -v wget >/dev/null 2>&1; then
  wget -q -O "$tmp" "$url" || die "download failed: $url"
else
  die "neither curl nor wget is available; download $url into $dest as jq$ext yourself"
fi

got=$(sha256_of "$tmp")
[ "$got" = "$sum" ] || die "checksum mismatch for $url (expected $sum, got $got); nothing installed"
chmod +x "$tmp"
"$tmp" --version >/dev/null 2>&1 || die "the downloaded jq doesn't run on this machine; nothing installed"
mv -f "$tmp" "$dest/jq$ext" || die "can't write $dest/jq$ext"
echo "$dest/jq$ext"
