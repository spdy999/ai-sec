# Three stages. The React bundle is built here rather than fetched at runtime:
# this VPC has no route to the internet, so a CDN reference would render a blank
# page in the cluster and work perfectly on a laptop.
FROM node:22-slim AS web

WORKDIR /web
COPY web/package.json web/package-lock.json ./
RUN npm ci

COPY web/ ./
RUN npm run build

# Python dependencies, so the shipped image carries no compiler and no package
# index. A build toolchain in a running container is a build toolchain an
# attacker has.
FROM python:3.12-slim AS deps

WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim

# Non-root by UID, not by name. The pod's runAsUser is a number, and a username
# resolved inside the image is not something admission control can check.
RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin mediation

COPY --from=deps /install /usr/local
COPY mediation /app/mediation

# The guard ships in the same image and runs from the same layers. Two images
# would drift, and the guard is small enough that carrying it costs nothing --
# the manifests choose which process starts by overriding the entrypoint.
COPY guard /app/guard

COPY --from=web /web/dist /app/mediation/static

WORKDIR /app
USER 10001

# The root filesystem is read-only at runtime; nothing below writes to it.
#
# TLS terminates in the pod, not at an ingress. Traffic between the jump host
# and this service crosses the cluster network, and "it is inside the VPC" has
# never been a reason to send a bearer token in clear text. The key pair is
# mounted from a Secret; see docs/RUNBOOK.md for how it is created.
EXPOSE 8443

ENTRYPOINT ["uvicorn", "mediation.main:app", \
  "--host", "0.0.0.0", "--port", "8443", \
  "--ssl-keyfile", "/etc/mediation-tls/tls.key", \
  "--ssl-certfile", "/etc/mediation-tls/tls.crt"]
