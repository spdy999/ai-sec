#!/bin/sh
#
# Fetch the listener's key pair, then become uvicorn.
#
# This exists because uvicorn wants --ssl-keyfile and --ssl-certfile as paths
# before any application code runs, so the certificate cannot be fetched from
# inside the app the way the signing key is. The files are written to /tmp,
# which is a memory-backed emptyDir with a size limit -- they never touch a
# disk and do not survive the pod.
#
# TLS_SECRET_ARN unset means the local provider, which has no Secrets Manager
# and terminates TLS elsewhere. Then this is a no-op passthrough.
set -eu

if [ -n "${TLS_SECRET_ARN:-}" ]; then
  umask 077
  mkdir -p /tmp/tls

  python - <<'PY'
import json
import os
import pathlib

from mediation import secrets

material = secrets.secret_json(os.environ["TLS_SECRET_ARN"], os.environ.get("AWS_REGION", "eu-central-1"))

for field, filename in (("certificate", "tls.crt"), ("private_key", "tls.key")):
    value = material.get(field)
    if not value:
        raise SystemExit(f"TLS secret has no {field!r}; refusing to start without a listener certificate")
    pathlib.Path("/tmp/tls", filename).write_text(value)
PY

  set -- "$@" --ssl-keyfile /tmp/tls/tls.key --ssl-certfile /tmp/tls/tls.crt
fi

exec "$@"
