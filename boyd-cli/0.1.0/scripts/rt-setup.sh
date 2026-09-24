#!/usr/bin/env bash
# Boyd environment access on a Mac, in one command. Safe to re-run any time.
#
# Run it as `boyd setup` / `boyd status` (scripts/boyd), which also installs `boyd` on PATH.
#
#   rt-setup.sh           install/configure anything missing, refresh SSO, print status
#   rt-setup.sh status    print status only, change nothing
#
# Covers: CLIs, Identity Center profiles in ~/.aws/config, SSO login, kubeconfig
# for demo/staging/prod, AWS VPN Client + staging/prod VPN profiles, env CA trust.
# You still approve the browser SSO page, the Entra login on first VPN connect,
# and any macOS password prompt (VPN Client install, keychain trust).
set -uo pipefail

SSO_SESSION=ronintech
SSO_START_URL=https://d-9a675c82c8.awsapps.com/start
REGION=us-east-2

# env:account:cluster:vpn_endpoint ("-" = none)
ENVS=(
  "demo:390736325367:demo:-"
  "staging:934405942806:staging:cvpn-endpoint-013893772ee4841df"
  "prod:638846893607:prod:cvpn-endpoint-0d71d1f897c82ab61"
  "platform:142366490018:-:-"
  "mgmt:071495507193:-:-"
)

STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/boyd"
AWS_CFG="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
VPN_DIR="$HOME/.config/AWSVPNClient"
VPN_APP="/Applications/AWS VPN Client/AWS VPN Client.app"
VPN_PKG_URL="https://d20adtppz83p9s.cloudfront.net/OSX/latest/AWS_VPN_Client.pkg"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# Stale exported keys or another client's profile would shadow the SSO profiles.
unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

MODE="${1:-setup}"
INTERACTIVE=0
[[ -t 0 && -t 1 ]] && INTERACTIVE=1

say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }

field() { local IFS=:; read -r -a f <<<"$1"; echo "${f[$2]}"; }

sso_ok() { aws sts get-caller-identity --profile rt-demo >/dev/null 2>&1; }

install_tools() {
  say "CLIs"
  command -v brew >/dev/null || { note "Homebrew missing: https://brew.sh"; return 1; }
  local missing=() pair
  for pair in aws:awscli kubectl:kubernetes-cli helm:helm argocd:argocd kind:kind jq:jq; do
    command -v "${pair%%:*}" >/dev/null || missing+=("${pair#*:}")
  done
  if ((${#missing[@]})); then
    brew install "${missing[@]}"
  else
    note "all present"
  fi
}

write_aws_config() {
  say "AWS profiles ($AWS_CFG)"
  mkdir -p "$(dirname "$AWS_CFG")"
  touch "$AWS_CFG"
  local added=0 e name acct
  if ! grep -q "^\[sso-session $SSO_SESSION\]" "$AWS_CFG"; then
    cp "$AWS_CFG" "$AWS_CFG.bak-$(date +%Y%m%d%H%M%S)"
    printf '\n# Ronintech Identity Center (boyd-infra scripts/rt-setup.sh)\n[sso-session %s]\nsso_start_url = %s\nsso_region = %s\nsso_registration_scopes = sso:account:access\n' \
      "$SSO_SESSION" "$SSO_START_URL" "$REGION" >>"$AWS_CFG"
    added=1
  fi
  for e in "${ENVS[@]}"; do
    name=$(field "$e" 0) acct=$(field "$e" 1)
    grep -q "^\[profile rt-$name\]" "$AWS_CFG" && continue
    printf '\n[profile rt-%s]\nsso_session = %s\nsso_account_id = %s\nsso_role_name = AdministratorAccess\nregion = %s\n' \
      "$name" "$SSO_SESSION" "$acct" "$REGION" >>"$AWS_CFG"
    added=1
  done
  ((added)) && note "added missing profiles" || note "already configured"
}

sso_login() {
  say "AWS SSO"
  if sso_ok; then note "session valid"; return; fi
  note "approve the login in your browser"
  aws sso login --sso-session "$SSO_SESSION"
}

write_kubeconfig() {
  say "kubeconfig"
  local cur e name cluster
  cur=$(kubectl config current-context 2>/dev/null || true)
  for e in "${ENVS[@]}"; do
    name=$(field "$e" 0) cluster=$(field "$e" 2)
    [[ $cluster == - ]] && continue
    aws eks update-kubeconfig --name "$cluster" --profile "rt-$name" --region "$REGION" --alias "$name" >/dev/null &&
      note "context $name"
  done
  if [[ -n $cur ]] && kubectl config get-contexts -o name | grep -qxF "$cur"; then
    kubectl config use-context "$cur" >/dev/null
  else
    kubectl config use-context demo >/dev/null
  fi
}

fetch_ca() {
  # Root of the env's internal CA, from the chain on the wildcard ACM cert.
  local env=$1 arn chain
  arn=$(aws acm list-certificates --profile "rt-$env" --region "$REGION" \
    --includes keyTypes=RSA_2048,RSA_3072,RSA_4096,EC_prime256v1,EC_secp384r1 \
    --query "CertificateSummaryList[?DomainName=='*.${env}.boyd.internal'].CertificateArn | [0]" --output text 2>/dev/null)
  [[ -z $arn || $arn == None ]] && return 1
  chain=$(aws acm get-certificate --certificate-arn "$arn" --profile "rt-$env" --region "$REGION" \
    --query CertificateChain --output text 2>/dev/null)
  [[ -z $chain || $chain == None ]] && return 1
  mkdir -p "$STATE_DIR"
  awk '/BEGIN CERT/{buf=""} {buf=buf $0 "\n"} /END CERT/{last=buf} END{printf "%s", last}' <<<"$chain" >"$STATE_DIR/ca-$env.pem"
}

ca_cn() { openssl x509 -in "$1" -noout -subject -nameopt multiline 2>/dev/null | awk -F'= ' '/commonName/{print $2; exit}'; }
ca_trusted() { local cn; cn=$(ca_cn "$1"); [[ -n $cn ]] && security dump-trust-settings 2>/dev/null | grep -qF "$cn"; }

trust_cas() {
  say "Env CA trust"
  local e name vpn pem
  for e in "${ENVS[@]}"; do
    name=$(field "$e" 0) vpn=$(field "$e" 3)
    [[ $vpn == - ]] && continue
    pem="$STATE_DIR/ca-$name.pem"
    if ! fetch_ca "$name"; then note "$name: couldn't read the CA from ACM"; continue; fi
    if ca_trusted "$pem"; then note "$name: trusted"; continue; fi
    note "$name: adding to login keychain (macOS will ask for your password)"
    security add-trusted-cert -r trustRoot -k "$LOGIN_KEYCHAIN" "$pem" && note "$name: trusted"
  done
}

install_vpn_client() {
  say "AWS VPN Client"
  if [[ -d $VPN_APP ]]; then note "installed"; return; fi
  if ((INTERACTIVE)); then
    brew install --cask aws-vpn-client
  else
    mkdir -p "$STATE_DIR"
    curl -fsSL -o "$STATE_DIR/AWS_VPN_Client.pkg" "$VPN_PKG_URL" && open "$STATE_DIR/AWS_VPN_Client.pkg"
    note "installer opened, click through it, then re-run boyd setup to add the VPN profiles"
  fi
}

vpn_profile_present() { [[ -f $VPN_DIR/ConnectionProfiles ]] && jq -e --arg n "boyd-$1" '.ConnectionProfiles[]? | select(.ProfileName == $n)' "$VPN_DIR/ConnectionProfiles" >/dev/null 2>&1; }

add_vpn_profiles() {
  say "VPN profiles"
  [[ -d $VPN_APP ]] || { note "skipped until the VPN Client is installed"; return; }
  if pgrep -xq "AWS VPN Client"; then
    note "quit AWS VPN Client and re-run to add profiles (it rewrites its profile list on exit)"
    return
  fi
  mkdir -p "$VPN_DIR/OpenVpnConfigs"
  local profiles="$VPN_DIR/ConnectionProfiles" e name vpn ovpn
  [[ -s $profiles ]] || echo '{"Version":"1","LastSelectedProfileIndex":0,"ConnectionProfiles":[]}' >"$profiles"
  for e in "${ENVS[@]}"; do
    name=$(field "$e" 0) vpn=$(field "$e" 3)
    [[ $vpn == - ]] && continue
    if vpn_profile_present "$name"; then note "boyd-$name present"; continue; fi
    ovpn="$VPN_DIR/OpenVpnConfigs/boyd-$name"
    aws ec2 export-client-vpn-client-configuration --client-vpn-endpoint-id "$vpn" \
      --profile "rt-$name" --region "$REGION" --query ClientConfiguration --output text >"$ovpn" || { note "boyd-$name: export failed"; continue; }
    cp "$profiles" "$profiles.bak"
    jq --arg n "boyd-$name" --arg p "$ovpn" --arg id "$vpn" --arg r "$REGION" \
      '.ConnectionProfiles += [{ProfileName:$n, OvpnConfigFilePath:$p, CvpnEndpointId:$id, CvpnEndpointRegion:$r, CompatibilityVersion:"2", FederatedAuthType:1}]' \
      "$profiles.bak" >"$profiles" && note "boyd-$name added"
  done
}

status() {
  say "Status"
  local e name cluster vpn pem sso_state=fail
  sso_ok && sso_state=ok
  printf '    %-26s %s\n' "boyd CLI" "$(command -v boyd >/dev/null && echo ok || echo "missing (boyd-infra/scripts/boyd install)")"
  printf '    %-26s %s\n' "AWS SSO ($SSO_SESSION)" "$sso_state"
  printf '    %-26s %s\n' "AWS VPN Client" "$([[ -d $VPN_APP ]] && echo ok || echo missing)"
  for e in "${ENVS[@]}"; do
    name=$(field "$e" 0) cluster=$(field "$e" 2) vpn=$(field "$e" 3)
    [[ $cluster == - ]] && continue
    if kubectl --context "$name" --request-timeout=6s get --raw /readyz >/dev/null 2>&1; then
      printf '    %-26s %s\n' "kubectl $name" ok
    elif [[ $vpn != - ]]; then
      printf '    %-26s %s\n' "kubectl $name" "unreachable (connect VPN boyd-$name)"
    else
      printf '    %-26s %s\n' "kubectl $name" fail
    fi
    [[ $vpn == - ]] && continue
    printf '    %-26s %s\n' "VPN profile boyd-$name" "$(vpn_profile_present "$name" && echo ok || echo missing)"
    pem="$STATE_DIR/ca-$name.pem"
    printf '    %-26s %s\n' "CA $name" "$([[ -f $pem ]] && ca_trusted "$pem" && echo trusted || echo missing)"
    if curl -fsS --max-time 5 --cacert "$pem" "https://boyd.$name.boyd.internal/api/health" >/dev/null 2>&1; then
      printf '    %-26s %s\n' "boyd.$name.boyd.internal" ok
    else
      printf '    %-26s %s\n' "boyd.$name.boyd.internal" "unreachable (VPN?)"
    fi
  done
  cat <<EOF

    boyd vpn staging        connect (Entra login), then kubectl and *.staging.boyd.internal work
    boyd open staging       Boyd app      boyd argo staging [login]   Argo CD
    boyd kube staging       kubectl context (demo needs no VPN)
    boyd help               everything else
EOF
}

case "$MODE" in
  status) status ;;
  setup)
    install_tools
    write_aws_config
    sso_login || { note "SSO login failed, fix that and re-run"; exit 1; }
    write_kubeconfig
    install_vpn_client
    add_vpn_profiles
    trust_cas
    status
    ;;
  -h|--help|help) sed -n '2,12p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//' ;;
  *) echo "usage: boyd setup | boyd status" >&2; exit 2 ;;
esac
