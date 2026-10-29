#!/usr/bin/env bash
# Keys for a release rehearsal, and opening its encrypted artifact (RELEASING.md, "Rehearsing a release").
#
#   app/Scripts/rehearsal.sh keygen <dir>                       # writes <dir>/rehearsal.key (private, stays here)
#                                                              # and prints the artifact_key input (public, one line)
#   app/Scripts/rehearsal.sh open <artifact-dir> <dir>/rehearsal.key <out-dir>
#                                                              # decrypts files.tar.enc into <out-dir>
#
# A rehearsal signs the app with the real Developer ID certificate, and a signed app carries the certificate's
# name. The repository is public, so its Actions artifacts are downloadable by anyone signed in to GitHub: the
# workflow encrypts the rehearsal's files to a public key (RSA-OAEP wraps a random AES-256 key; the plaintext's
# SHA-256 travels inside the wrapped part and is checked here). Uses the system /usr/bin/openssl (LibreSSL).
set -euo pipefail
OPENSSL=/usr/bin/openssl
die() { echo "rehearsal: $*" >&2; exit 1; }
case "${1:-}" in
  keygen)
    dir="${2:?usage: rehearsal.sh keygen <dir>}"
    mkdir -p "$dir"; umask 077
    [ -e "$dir/rehearsal.key" ] && die "$dir/rehearsal.key exists; use another directory"
    "$OPENSSL" genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$dir/rehearsal.key" 2>/dev/null
    "$OPENSSL" pkey -in "$dir/rehearsal.key" -pubout | base64 | tr -d '\n'; echo
    ;;
  open)
    art="${2:?usage: rehearsal.sh open <artifact-dir> <key> <out-dir>}"; key="${3:?key}"; out="${4:?out-dir}"
    [ -f "$art/files.tar.enc" ] && [ -f "$art/files.key.enc" ] || die "$art has no files.tar.enc / files.key.enc"
    umask 077
    read -r k iv sum < <("$OPENSSL" pkeyutl -decrypt -inkey "$key" -pkeyopt rsa_padding_mode:oaep -in "$art/files.key.enc") || true   # no trailing newline: read returns 1 at EOF
    [ -n "${sum:-}" ] || die "could not unwrap the file key (wrong private key?)"
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    "$OPENSSL" enc -d -aes-256-cbc -K "$k" -iv "$iv" -in "$art/files.tar.enc" -out "$tmp/files.tar"
    [ "$(shasum -a 256 "$tmp/files.tar" | cut -d' ' -f1)" = "$sum" ] || die "SHA-256 mismatch after decryption"
    mkdir -p "$out"; tar -C "$out" -xf "$tmp/files.tar"
    echo "rehearsal: opened into $out (SHA-256 checked)"
    ;;
  *) die "usage: rehearsal.sh keygen <dir> | open <artifact-dir> <key> <out-dir>" ;;
esac
