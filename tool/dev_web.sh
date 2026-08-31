#!/usr/bin/env bash
# Levanta el proxy OAuth (tool/start_oauth_proxy.sh) y, en cuanto responde,
# arranca Flutter en Chrome apuntando a él. Al cerrar Flutter (Ctrl+C o "q"),
# el proxy se detiene solo.
#
# Ver tool/start_oauth_proxy.sh para cómo se resuelve el client secret.
set -euo pipefail

cd "$(dirname "$0")/.."

./tool/start_oauth_proxy.sh &
proxy_pid=$!

cleanup() {
  echo "Deteniendo proxy OAuth (pid $proxy_pid)..."
  kill "$proxy_pid" 2>/dev/null || true
}
trap cleanup EXIT

# Espera a que el proxy esté escuchando antes de arrancar Flutter.
for _ in $(seq 1 20); do
  if curl -s -o /dev/null "http://127.0.0.1:8787/health"; then
    break
  fi
  sleep 0.5
done

flutter run -d chrome --web-port 8080 \
  --dart-define=OAUTH_PROXY_URL=http://localhost:8787/oauth/token
