#!/usr/bin/env bash
# Build the emulator image inside the cluster and deploy it.
#
# Assumes you are logged in with `oc` and the internal image registry is
# Managed. Creates the namespace if it is missing.
#
# Usage:
#   AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... \
#   CLUSTER_TAG=kubernetes.io/cluster/<infra-id>=owned \
#   REGION=us-east-1 ./build-and-deploy.sh
set -euo pipefail

NS="${NS:-sushy-emulator}"
REGION="${REGION:-us-east-1}"
CLUSTER_TAG="${CLUSTER_TAG:?set CLUSTER_TAG, e.g. kubernetes.io/cluster/mycluster-abcde=owned}"
: "${AWS_ACCESS_KEY_ID:?}" "${AWS_SECRET_ACCESS_KEY:?}"
SRC="${SRC:-$(pwd)/sushy-tools}"

oc get namespace "$NS" >/dev/null 2>&1 || oc create namespace "$NS"

if [ ! -d "$SRC/.git" ]; then
  echo "Cloning the driver branch into $SRC"
  git clone -b aws-systems-driver https://github.com/RanWurmbrand/sushy-tools "$SRC"
fi

# Build the wheel from the git checkout. This has to happen here, not in the
# container: sushy-tools uses pbr, which reads git metadata to decide which
# non-Python files belong in the package. Build without .git and all the
# Jinja templates are silently dropped, and the emulator 500s on its first
# request.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
python3 -m pip wheel --no-deps -w "$WORK" "$SRC"
cp "$(dirname "$0")/Dockerfile" "$WORK/"

# Self-signed cert. fence_redfish only speaks HTTPS, so TLS is not optional;
# the agent is pointed at it with --ssl-insecure.
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout "$WORK/tls.key" -out "$WORK/tls.crt" \
  -subj "/CN=sushy-emulator.$NS.svc" \
  -addext "subjectAltName=DNS:sushy-emulator.$NS.svc,DNS:sushy-emulator.$NS.svc.cluster.local"

oc create secret generic sushy-aws-creds -n "$NS" \
  --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  --dry-run=client -o yaml | oc apply -f -

oc create secret tls sushy-emulator-tls -n "$NS" \
  --cert="$WORK/tls.crt" --key="$WORK/tls.key" \
  --dry-run=client -o yaml | oc apply -f -

oc create configmap sushy-emulator-config -n "$NS" --from-literal=aws.conf="\
SUSHY_EMULATOR_AWS_DRIVER = True
SUSHY_EMULATOR_AWS_REGION = '$REGION'
SUSHY_EMULATOR_AWS_TAG = '$CLUSTER_TAG'
SUSHY_EMULATOR_LISTEN_IP = '0.0.0.0'
SUSHY_EMULATOR_LISTEN_PORT = 8000
SUSHY_EMULATOR_SSL_CERT = '/etc/sushy/tls/tls.crt'
SUSHY_EMULATOR_SSL_KEY = '/etc/sushy/tls/tls.key'
" --dry-run=client -o yaml | oc apply -f -

oc get buildconfig sushy-emulator -n "$NS" >/dev/null 2>&1 || \
  oc new-build --binary --name=sushy-emulator --strategy=docker -n "$NS"
oc start-build sushy-emulator --from-dir="$WORK" --follow -n "$NS"

sed -e "s|__NAMESPACE__|$NS|g" -e "s|value: us-east-1|value: $REGION|" \
  "$(dirname "$0")/10-emulator.yaml" | oc apply -f -
oc rollout restart deploy/sushy-emulator -n "$NS"
oc rollout status deploy/sushy-emulator -n "$NS"

echo
echo "Emulator is up. Check it sees your instances:"
echo "  oc run curltest --rm -i --restart=Never -n $NS \\"
echo "    --image=registry.access.redhat.com/ubi9/ubi-minimal -- \\"
echo "    curl -sk https://sushy-emulator.$NS.svc:8000/redfish/v1/Systems"
