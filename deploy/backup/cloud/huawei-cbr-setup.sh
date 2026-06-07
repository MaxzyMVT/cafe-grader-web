#!/usr/bin/env bash
#
# Cafe-Grader — Huawei Cloud CBR (Cloud Backup & Recovery) setup.
#
# Creates ONE server-backup vault, attaches all 3 ECS instances (web+db + 2
# workers), and binds a DAILY backup policy with retention. CBR then takes
# whole-VM (disk) snapshots automatically — this is the crash-recovery layer.
#
# Run this ONCE from a machine with KooCLI (hcloud) installed & authenticated:
#     hcloud configure init        # enter AK/SK + region
#     hcloud configure list
#
# NOTE: CBR CLI parameter names can vary slightly by region/version. If a call
# is rejected, inspect the exact schema with:  hcloud CBR <Api> --help
# The Console click-path in README.md is the reliable fallback.
#
# Requires: hcloud (KooCLI), jq.

set -euo pipefail

# ----------------------------------------------------------------------------
# CONFIG — EDIT THESE.
# ----------------------------------------------------------------------------
REGION="${REGION:-ap-southeast-2}"        # <-- your Huawei region (check console)
VAULT_NAME="${VAULT_NAME:-cafe-grader-vault}"
VAULT_SIZE_GB="${VAULT_SIZE_GB:-500}"     # vault capacity; >= sum of all disk usage
POLICY_NAME="${POLICY_NAME:-cafe-daily-0200ict}"
RETENTION_COUNT="${RETENTION_COUNT:-28}"  # keep last N backups (28 = ~7 days at 4/day)
# Comma list of local hours to snapshot. "2" = daily 02:00; "2,8,14,20" = every 6h.
BACKUP_HOURS_LOCAL="${BACKUP_HOURS_LOCAL:-2,8,14,20}"
TIMEZONE="${TIMEZONE:-UTC+07:00}"
CONSISTENT_LEVEL="${CONSISTENT_LEVEL:-crash_consistent}"  # app_consistent needs the CBR agent

# VM public IPs to back up — provided at runtime, never hardcoded. Priority:
#   ./huawei-cbr-setup.sh <ip1> <ip2> <ip3>      (positional args), or
#   SERVER_IPS="ip1 ip2 ip3" ./huawei-cbr-setup.sh (env var), or
#   run with none and you'll be prompted interactively.
SERVER_IPS="${SERVER_IPS:-}"
# ----------------------------------------------------------------------------

command -v hcloud >/dev/null || { echo "hcloud (KooCLI) not found"; exit 1; }
command -v jq >/dev/null || { echo "jq not found"; exit 1; }
R=(--cli-region="$REGION")

# Resolve target IPs: CLI args take priority, then $SERVER_IPS, else prompt.
if [ "$#" -gt 0 ]; then SERVER_IPS="$*"; fi
if [ -z "${SERVER_IPS// /}" ]; then
  read -rp "Enter VM public IPs to back up (space-separated): " SERVER_IPS
fi
[ -n "${SERVER_IPS// /}" ] || { echo "No IPs provided — aborting"; exit 1; }

echo "==> Resolving ECS server IDs from IPs"
SERVER_IDS=()
for ip in $SERVER_IPS; do
  id="$(hcloud ECS ListServersDetails "${R[@]}" --ip="$ip" \
        | jq -r '.servers[0].id // empty')"
  [ -n "$id" ] || { echo "  !! no server found for IP $ip — add it manually in console"; continue; }
  echo "  $ip -> $id"
  SERVER_IDS+=("$id")
done
[ "${#SERVER_IDS[@]}" -gt 0 ] || { echo "No servers resolved; aborting"; exit 1; }

echo "==> Creating vault: $VAULT_NAME"
VAULT_BODY="$(jq -n \
  --arg name "$VAULT_NAME" --arg cl "$CONSISTENT_LEVEL" --argjson size "$VAULT_SIZE_GB" '
  {vault:{name:$name,billing:{consistent_level:$cl,object_type:"server",
   protect_type:"backup",size:$size,charging_mode:"post_paid",cloud_type:"public"}}}')"
VAULT_ID="$(hcloud CBR CreateVault "${R[@]}" --cli-jsonInput="$VAULT_BODY" \
            | jq -r '.vault.id')"
echo "  vault_id=$VAULT_ID"

echo "==> Attaching servers to vault"
RES_JSON="$(printf '%s\n' "${SERVER_IDS[@]}" \
  | jq -R '{id:.,type:"OS::Nova::Server"}' | jq -s '{resources:.}')"
hcloud CBR AddVaultResource "${R[@]}" --vault_id="$VAULT_ID" --cli-jsonInput="$RES_JSON" >/dev/null
echo "  attached ${#SERVER_IDS[@]} server(s)"

echo "==> Creating daily backup policy: $POLICY_NAME"
POLICY_BODY="$(jq -n \
  --arg name "$POLICY_NAME" --arg tz "$TIMEZONE" \
  --argjson keep "$RETENTION_COUNT" --arg hours "$BACKUP_HOURS_LOCAL" '
  {policy:{name:$name,operation_type:"backup",enabled:true,
   operation_definition:{retention_duration_count:$keep,timezone:$tz},
   trigger:{properties:{pattern:["FREQ=DAILY;INTERVAL=1;BYHOUR=\($hours);BYMINUTE=0"]}}}}')"
POLICY_ID="$(hcloud CBR CreatePolicy "${R[@]}" --cli-jsonInput="$POLICY_BODY" \
             | jq -r '.policy.id')"
echo "  policy_id=$POLICY_ID"

echo "==> Binding policy to vault"
hcloud CBR AssociateVaultPolicy "${R[@]}" --vault_id="$VAULT_ID" \
  --cli-jsonInput="$(jq -n --arg p "$POLICY_ID" '{policy_id:$p}')" >/dev/null

cat <<EOF

DONE.
  Vault : $VAULT_NAME ($VAULT_ID)
  Policy: $POLICY_NAME ($POLICY_ID) — hours [${BACKUP_HOURS_LOCAL}] $TIMEZONE, keep $RETENTION_COUNT
  Servers attached: ${SERVER_IDS[*]}

Verify in console: CBR > Cloud Server Backup > Vaults.
Trigger an immediate first backup (optional):
  hcloud CBR CreateCheckpoint ${R[*]} --cli-jsonInput='{"checkpoint":{"vault_id":"$VAULT_ID","parameters":{"auto_trigger":false}}}'
EOF
