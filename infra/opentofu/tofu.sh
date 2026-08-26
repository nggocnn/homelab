#!/usr/bin/env bash
# Run OpenTofu with credentials and state encryption pulled from SOPS.
#
#   ./tofu.sh init | plan | apply | destroy
set -euo pipefail
cd "$(dirname "$0")"

export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
[ -f "$SOPS_AGE_KEY_FILE" ] || { echo "age key not found: $SOPS_AGE_KEY_FILE" >&2; exit 1; }

# PROXMOX_VE_* for the provider, TF_STATE_PASSPHRASE for state encryption.
eval "$(sops -d ../../secrets/tofu.sops.yaml | python3 -c '
import sys, yaml, shlex
for k, v in yaml.safe_load(sys.stdin).items():
    print(f"export {k}={shlex.quote(str(v))}")
')"

# PBS credentials become TF_VAR_* so they never appear as literals in the config.
if [ -f ../../secrets/pbs.sops.yaml ]; then
  eval "$(sops -d ../../secrets/pbs.sops.yaml | python3 -c '
import sys, yaml, shlex
for k, v in yaml.safe_load(sys.stdin).items():
    print(f"export TF_VAR_{k}={shlex.quote(str(v))}")
')"
fi

# State and plan files are encrypted at rest.
export TF_ENCRYPTION="
key_provider \"pbkdf2\" \"main\" {
  passphrase = \"${TF_STATE_PASSPHRASE}\"
}
method \"aes_gcm\" \"main\" {
  keys = key_provider.pbkdf2.main
}
state { method = method.aes_gcm.main }
plan  { method = method.aes_gcm.main }
"

exec tofu "$@"
