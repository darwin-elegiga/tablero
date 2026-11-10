#!/bin/zsh
# One-time setup of a clone: commit signing with YOUR SSH key, the safety hooks, and the
# list of keys the app trusts for self-updates (.git/info/allowed_signers, local only).
#
#   ./setup.sh [path/to/your_key.pub] [--trust-upstream]
#
# --trust-upstream also trusts the original author's key (signers/darwin-elegiga.allowed), so the
# app accepts updates pulled from the original repo. Without it, only commits you sign are applied.
set -eu
cd "$(dirname "$0")"
git rev-parse --git-dir >/dev/null

KEY=""
TRUST_UPSTREAM=0
for arg in "$@"; do
  case "$arg" in
    --trust-upstream) TRUST_UPSTREAM=1 ;;
    *) KEY="$arg" ;;
  esac
done
if [[ -z "$KEY" ]]; then
  for candidate in ~/.ssh/id_ed25519.pub ~/.ssh/id_ecdsa.pub ~/.ssh/id_rsa.pub; do
    [[ -f "$candidate" ]] && KEY="$candidate" && break
  done
fi
[[ -n "$KEY" && -f "$KEY" ]] || { echo "No encuentro tu clave pública SSH. Uso: ./setup.sh ~/.ssh/tu_clave.pub" >&2; exit 1; }
[[ "$KEY" == *.pub ]] || { echo "Pasa la clave PÚBLICA (.pub), nunca la privada." >&2; exit 1; }

EMAIL="$(git config user.email || true)"
[[ -n "$EMAIL" ]] || { echo "Configura antes tu correo: git config user.email tu@correo" >&2; exit 1; }

SIGNERS="$(cd "$(git rev-parse --git-dir)" && pwd)/info/allowed_signers"
mkdir -p "$(dirname "$SIGNERS")"
echo "$EMAIL namespaces=\"git\" $(cut -d' ' -f1,2 "$KEY")" >"$SIGNERS"
if ((TRUST_UPSTREAM)); then
  cat signers/darwin-elegiga.allowed >>"$SIGNERS"
fi
chmod 600 "$SIGNERS"

git config --local user.email "$EMAIL" # the pre-push hook checks commits against this identity
git config --local gpg.format ssh
git config --local gpg.ssh.program /usr/bin/ssh-keygen
git config --local user.signingkey "$KEY"
git config --local commit.gpgsign true
git config --local gpg.ssh.allowedSignersFile "$SIGNERS"
git config --local core.hooksPath githooks

echo "Listo:"
echo "  - Tus commits se firman con $KEY"
echo "  - La app solo aplica actualizaciones firmadas por: $(cut -d' ' -f1 "$SIGNERS" | paste -sd, - | sed 's/,/, /g')"
echo "  - Hooks de seguridad activos (githooks/)"
echo "Siguiente paso: ./build-notifier.sh"
