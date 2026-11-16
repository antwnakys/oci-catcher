#!/usr/bin/env bash
# Sets up the caught Minecraft server from GitHub Actions, so the Mac is not needed.
#   MODE=check  read-only: looks at the Oracle account and changes nothing
#   MODE=setup  reserves a fixed public IP, opens port 25565, installs Minecraft
# It logs in with the "cloud" SSH key (see cloud_key.py). Prints no OCIDs and no
# IP addresses: the repository and its logs are public.
set -uo pipefail
export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True SUPPRESS_LABEL_WARNING=True

MODE="${MODE:-check}"
C="$OCI_TENANCY"
KEY="$HOME/.ssh/cloud"
REPORT="${REPORT:-$HOME/report.md}"
PORT=25565
: > "$REPORT"

say()    { echo "$(TZ=Europe/Athens date '+%H:%M:%S')  $*"; }
note()   { say "$*"; echo "- $*" >> "$REPORT"; }
hide()   { [[ -n "${1:-}" && "$1" != null ]] && echo "::add-mask::$1"; return 0; }
fail()   { note "FAILED: $*"; exit 1; }
is_ocid() { [[ "${1:-}" == ocid1.* ]]; }
oci_err() { grep -E '"(code|message)"' <<<"$1" | head -2; }
SSHO=(-i "$KEY" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$HOME/.ssh/known_hosts_mc"
      -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR -o ServerAliveInterval=30)

say "Mode: $MODE"
[[ -f "$KEY" ]] || fail "cloud SSH key missing"
say "Cloud SSH key: $(ssh-keygen -lf "$KEY" | awk '{print $2}')"

# ---- 1. Find the server -------------------------------------------------------
inst=$(oci compute instance list -c "$C" --display-name minecraft \
  --query 'data[?"lifecycle-state"!=`TERMINATED`].id | [0]' --raw-output 2>/dev/null)
hide "$inst"
if ! is_ocid "$inst"; then
  [[ "$MODE" == check ]] || fail "no 'minecraft' server exists yet"
  note "No 'minecraft' server exists yet (expected while the catcher is still trying)."
fi

if is_ocid "$inst"; then
  for i in $(seq 1 60); do
    state=$(oci compute instance get --instance-id "$inst" --query 'data."lifecycle-state"' --raw-output 2>/dev/null)
    [[ "$state" == RUNNING || "$MODE" == check ]] && break
    if [[ "$state" == STOPPED ]]; then
      say "Server is stopped; starting it"
      oci compute instance action --instance-id "$inst" --action START >/dev/null 2>&1
    fi
    say "Server state: $state, waiting"; sleep 20
  done
  note "Server found, state: $state."
  [[ "$state" == RUNNING || "$MODE" == check ]] || fail "server did not reach RUNNING"
fi

# ---- 2. Fixed (reserved) public IP ---------------------------------------------
IP=""
if is_ocid "$inst" && [[ "$state" == RUNNING ]]; then
  vnic=$(oci compute instance list-vnics --instance-id "$inst" \
    --query 'data[?"is-primary"] | [0].id' --raw-output 2>/dev/null); hide "$vnic"
  priv=$(oci network private-ip list --vnic-id "$vnic" \
    --query 'data[?"is-primary"] | [0].id' --raw-output 2>/dev/null); hide "$priv"
  is_ocid "$priv" || fail "could not read the server's network card"

  pub_info() { oci network public-ip get --private-ip-id "$priv" \
    --query 'data.[id, lifetime, "ip-address"] | join(`" "`, @)' --raw-output 2>/dev/null; }
  read -r pub_id lifetime IP <<<"$(pub_info)"; hide "$pub_id"; hide "$IP"

  if [[ "$lifetime" == RESERVED ]]; then
    note "Public IP is already fixed (reserved)."
  elif [[ "$MODE" == check ]]; then
    note "Public IP is temporary (${lifetime:-none}); setup will make it fixed."
  else
    res=$(oci network public-ip list -c "$C" --scope REGION --lifetime RESERVED \
      --query 'data[?"display-name"==`minecraft-ip`] | [0].id' --raw-output 2>/dev/null); hide "$res"
    if ! is_ocid "$res"; then
      out=$(oci network public-ip create -c "$C" --lifetime RESERVED --display-name minecraft-ip \
        --query 'data.id' --raw-output 2>&1); res=$(grep -o 'ocid1[^"]*' <<<"$out" | head -1); hide "$res"
      is_ocid "$res" || { note "Could not reserve a fixed IP, keeping the temporary one:"; oci_err "$out"; }
    fi
    if is_ocid "$res"; then
      if is_ocid "$pub_id"; then
        oci network public-ip delete --public-ip-id "$pub_id" --force \
          --wait-for-state TERMINATED >/dev/null 2>&1 || true
      fi
      if oci network public-ip update --public-ip-id "$res" --private-ip-id "$priv" \
           --wait-for-state ASSIGNED >/dev/null 2>&1; then
        note "Public IP is now fixed (reserved). It changed once, just now."
      else
        note "Assigning the fixed IP failed; giving the server a temporary IP again."
        oci network public-ip create -c "$C" --lifetime EPHEMERAL --private-ip-id "$priv" >/dev/null 2>&1
      fi
      sleep 5
      read -r pub_id lifetime IP <<<"$(pub_info)"; hide "$pub_id"; hide "$IP"
    fi
  fi
  [[ -n "$IP" && "$IP" != null || "$MODE" == check ]] || fail "the server has no public IP"
fi

# ---- 3. Oracle firewall: open TCP 25565 ----------------------------------------
sls=$(oci network subnet get --subnet-id "$OCI_SUBNET" --query 'data."security-list-ids"' 2>/dev/null)
mapfile -t SL < <(jq -r '.[]?' <<<"$sls")
(( ${#SL[@]} )) || fail "could not read the subnet's security lists"
for s in "${SL[@]}"; do hide "$s"; done
OPEN_FILTER='[.[] | select(.source=="0.0.0.0/0" and (.protocol=="all" or (.protocol=="6" and
  (.["tcp-options"]==null or .["tcp-options"]["destination-port-range"]==null or
   (.["tcp-options"]["destination-port-range"].min<=25565 and .["tcp-options"]["destination-port-range"].max>=25565)))))] | length'
open=0
for s in "${SL[@]}"; do
  n=$(oci network security-list get --security-list-id "$s" --query 'data."ingress-security-rules"' 2>/dev/null | jq "$OPEN_FILTER")
  (( ${n:-0} > 0 )) && open=1
done
if (( open )); then
  note "Oracle firewall: port $PORT is already open."
elif [[ "$MODE" == check ]]; then
  note "Oracle firewall: port $PORT is closed; setup will open it."
else
  rules=$(oci network security-list get --security-list-id "${SL[0]}" --query 'data."ingress-security-rules"' 2>/dev/null)
  jq -e 'type=="array"' >/dev/null <<<"$rules" || fail "could not read the firewall rules"
  new=$(jq -c --argjson p "$PORT" '
    def camel: gsub("-(?<c>[a-z])"; .c | ascii_upcase);
    walk(if type=="object" then with_entries(.key |= camel) else . end)
    + [{"protocol":"6","source":"0.0.0.0/0","sourceType":"CIDR_BLOCK","isStateless":false,
        "description":"Minecraft","tcpOptions":{"destinationPortRange":{"min":$p,"max":$p}}}]' <<<"$rules")
  out=$(oci network security-list update --security-list-id "${SL[0]}" --ingress-security-rules "$new" --force 2>&1 >/dev/null) \
    || { oci_err "$out"; fail "could not open port $PORT in the Oracle firewall"; }
  note "Oracle firewall: opened port $PORT."
fi

if [[ "$MODE" == check ]]; then
  note "Check finished. Nothing was changed."
  exit 0
fi

# ---- 4. Log in -------------------------------------------------------------------
for i in $(seq 1 45); do
  ssh "${SSHO[@]}" "ubuntu@$IP" true 2>/dev/null && break
  say "Waiting for SSH ($i)"; sleep 20
done
ssh "${SSHO[@]}" "ubuntu@$IP" true 2>/dev/null \
  || fail "cannot log in with the cloud key. If the server was caught by the older catcher code, the Mac is needed once."
note "Logged in to the server with the cloud key."
ssh "${SSHO[@]}" "ubuntu@$IP" 'echo "    $(nproc) CPU core(s), $(free -g | awk "/Mem:/{print \$2}") GB RAM"'

# ---- 5. Install Minecraft ------------------------------------------------------
scp "${SSHO[@]}" -q -r server "ubuntu@$IP:" || fail "could not copy the setup files"
say "Running setup.sh (takes 5-15 minutes on 1 core)"
ssh "${SSHO[@]}" "ubuntu@$IP" '
  sudo cloud-init status --wait >/dev/null 2>&1 || true
  echo "DPkg::Lock::Timeout \"900\";" | sudo tee /etc/apt/apt.conf.d/99lock-timeout >/dev/null
  sudo EULA=yes NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive bash ~/server/setup.sh' \
  || fail "setup.sh stopped with an error (see the log above)"
note "setup.sh finished."

# ---- 6. Check it works ---------------------------------------------------------
ready=0
for i in $(seq 1 30); do
  if ssh "${SSHO[@]}" "ubuntu@$IP" 'systemctl is-active -q minecraft && sudo journalctl -u minecraft --no-pager | grep -q "Done ("'; then
    ready=1; break; fi
  say "Waiting for the world to load ($i)"; sleep 20
done
(( ready )) && note "Minecraft service is running and the world has loaded." \
            || fail "Minecraft did not finish starting (check: sudo journalctl -u minecraft)"
if timeout 10 bash -c ">/dev/tcp/$IP/$PORT" 2>/dev/null; then
  note "Port $PORT is reachable from the internet."
else
  fail "port $PORT is not reachable from the internet"
fi
note "Setup complete. The address is the public IP shown in the Oracle Cloud console (not posted here because this repository is public)."
