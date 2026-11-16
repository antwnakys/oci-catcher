#!/usr/bin/env bash
# Keeps asking Oracle Cloud for a free Ampere A1 server (1 OCPU / 6 GB) until it
# gets one. Runs inside GitHub Actions; all account details come from secrets.
# Retries every 120s (measured sweet spot: faster triggers rate limiting).
set -uo pipefail
export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True SUPPRESS_LABEL_WARNING=True

OCI="${OCI:-oci}"
WAIT=120
DEADLINE=${DEADLINE:-20400}   # stop cleanly after 5h40m; the next run takes over
SIZE='{"ocpus":1,"memoryInGBs":6}'

caught() { echo "caught=true" >> "${GITHUB_OUTPUT:-/dev/null}"; }

existing=$("$OCI" compute instance list -c "$OCI_TENANCY" --display-name minecraft \
  --query 'data[?"lifecycle-state"!=`TERMINATED`].id | [0]' --raw-output 2>/dev/null)
if [[ "$existing" == ocid1.instance.* ]]; then
  echo "A 'minecraft' server already exists. Nothing to do."; caught; exit 0
fi

attempt=0; checks=0; slowdowns=0; backoff=180
while (( SECONDS < DEADLINE )); do
  attempt=$((attempt + 1))
  out=$("$OCI" compute instance launch \
      --compartment-id "$OCI_TENANCY" \
      --availability-domain "$OCI_AD" \
      --display-name minecraft \
      --shape VM.Standard.A1.Flex \
      --shape-config "$SIZE" \
      --image-id "$OCI_IMAGE" \
      --boot-volume-size-in-gbs 100 \
      --subnet-id "$OCI_SUBNET" \
      --assign-public-ip true \
      --ssh-authorized-keys-file "$HOME/ssh_key.pub" \
      --no-retry \
      --query 'data.id' --raw-output 2>&1)
  rc=$?
  ts=$(TZ=Europe/Athens date '+%Y-%m-%d %H:%M:%S')

  if [[ $rc -eq 0 && "$out" == ocid1.instance.* ]]; then
    echo "$ts  SUCCESS on attempt $attempt: server is being created"; caught; exit 0
  fi

  if grep -qi "capacity" <<<"$out"; then
    checks=$((checks + 1)); backoff=180
    echo "$ts  attempt $attempt: out of capacity [real checks: $checks, slow-downs: $slowdowns], retrying in ${WAIT}s"
    sleep "$WAIT"
  elif grep -qi "TooManyRequests\|429" <<<"$out"; then
    slowdowns=$((slowdowns + 1))
    echo "$ts  attempt $attempt: Oracle says slow down, waiting $((backoff / 60)) min"
    sleep "$backoff"; backoff=$(( backoff * 2 > 900 ? 900 : backoff * 2 ))
  elif grep -qi "LimitExceeded\|QuotaExceeded" <<<"$out"; then
    echo "$ts  attempt $attempt: limit exceeded - stopping"
    grep -E '"(code|message)"' <<<"$out"
    exit 1
  else
    echo "$ts  attempt $attempt: other error, retrying in 2 min"
    grep -E '"(code|message|status)"' <<<"$out" | head -3
    found=$("$OCI" compute instance list -c "$OCI_TENANCY" --display-name minecraft \
      --query 'data[?"lifecycle-state"!=`TERMINATED`].id | [0]' --raw-output 2>/dev/null)
    if [[ "$found" == ocid1.instance.* ]]; then
      echo "$ts  SUCCESS: a 'minecraft' server exists after all"; caught; exit 0
    fi
    sleep 120
  fi
done
echo "Run time limit reached after $attempt attempts; the next scheduled run continues."
