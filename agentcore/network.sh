#!/usr/bin/env bash
# Source from task agentcore bootstrap and V2 verification so both use the same
# requested network configuration and validate the same Terraform outputs.
AGENTCORE_NETWORK_MODE="${AGENTCORE_NETWORK_MODE:-PUBLIC}"
AGENTCORE_SUBNETS='[]'
AGENTCORE_SECURITY_GROUPS='[]'
case "$AGENTCORE_NETWORK_MODE" in
  PUBLIC) ;;
  VPC)
    NETWORK_TF="$(dirname "${BASH_SOURCE[0]}")/../infrastructure/terraform"
    SUBNET_JSON="$(terraform -chdir="$NETWORK_TF" output -json private_subnet_ids)"
    SG="$(terraform -chdir="$NETWORK_TF" output -raw agentcore_security_group_id)"
    [ -n "$SG" ] && [ "$SG" != null ] && [ "$SG" != None ] || { echo 'ERROR: no AgentCore security group; enable_agentcore_vpc must be true' >&2; return 1; }
    AGENTCORE_SUBNETS="$(printf '%s' "$SUBNET_JSON" | python3 -c 'import json,sys; a=json.load(sys.stdin); print(json.dumps(a) if isinstance(a,list) and a else "")' 2>/dev/null || true)"
    [ -n "$AGENTCORE_SUBNETS" ] || { echo 'ERROR: no private subnets in terraform output private_subnet_ids' >&2; return 1; }
    AGENTCORE_SECURITY_GROUPS="$(python3 -c 'import json,sys;print(json.dumps([sys.argv[1]]))' "$SG")"
    ;;
  *) echo 'ERROR: AGENTCORE_NETWORK_MODE must be PUBLIC or VPC' >&2; return 1;;
esac
export AGENTCORE_NETWORK_MODE AGENTCORE_SUBNETS AGENTCORE_SECURITY_GROUPS
