#!/usr/bin/env bash
# Arranca tool/oauth_proxy.dart leyendo el client secret, en este orden:
#   1. De la variable de entorno OAUTH_CLIENT_SECRET si ya está exportada.
#   2. Del fichero tool/oauth_secret.local (una sola línea, ignorado por git).
#
# Usado tanto por tool/dev_web.sh (terminal) como por la tarea de VS Code
# que precede al debug de Flutter (.vscode/tasks.json).
set -euo pipefail

cd "$(dirname "$0")/.."

SECRET_FILE="tool/oauth_secret.local"

if [[ -z "${OAUTH_CLIENT_SECRET:-}" ]]; then
  if [[ -f "$SECRET_FILE" ]]; then
    OAUTH_CLIENT_SECRET="$(tr -d '[:space:]' < "$SECRET_FILE")"
  else
    echo "Falta OAUTH_CLIENT_SECRET." >&2
    echo "Guárdalo en $SECRET_FILE (una línea, sin comillas) o expórtalo antes de llamar a este script." >&2
    exit 64
  fi
fi
export OAUTH_CLIENT_SECRET

echo "Arrancando proxy OAuth..."
exec dart run tool/oauth_proxy.dart
