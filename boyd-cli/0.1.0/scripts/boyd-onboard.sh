#!/usr/bin/env bash
# Workspace clone + GitHub preflight for new engineers. Sourced by scripts/boyd.
set -euo pipefail

BOYD_WORK_ROOT="${BOYD_WORK_ROOT:-$HOME/work/ronintech}"
GITHUB_ORG=ronintech-ai
MANIFEST="${BOYD_ONBOARD_MANIFEST:-$SCRIPTS/onboard-repos.txt}"

maybe_git_ssh() {
  [[ -n ${GIT_SSH_COMMAND:-} ]] && return
  if [[ -f $HOME/ronintech.pem ]]; then
    export GIT_SSH_COMMAND="ssh -i $HOME/ronintech.pem -o IdentitiesOnly=yes"
  fi
}

onboard_say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
onboard_note() { printf '    %s\n' "$*"; }

github_help() {
  cat <<'EOF'
Fix GitHub access, then re-run:

  1. Accept the invite to the ronintech-ai GitHub org (check your email).
  2. Create an SSH key if you do not have one:
       ssh-keygen -t ed25519 -f ~/.ssh/ronintech_github -C "you@ronintech.ai"
  3. Add it to GitHub (pick one):
       gh auth login          # GitHub.com, SSH, add key when prompted
       gh ssh-key add ~/.ssh/ronintech_github.pub -t "Ronintech Mac"
  4. Optional dedicated key for Ronintech clones:
       export GIT_SSH_COMMAND='ssh -i ~/.ssh/ronintech_github -o IdentitiesOnly=yes'
       (add that line to ~/.zshrc if you use multiple GitHub keys)
  5. Verify:
       ssh -T git@github.com
       git ls-remote git@github.com:ronintech-ai/boyd.git HEAD

Org membership and AWS Identity Center are separate: ask Dan if clone still says "Repository not found".
EOF
}

cmd_github() {
  maybe_git_ssh
  onboard_say "GitHub preflight"
  local missing=()
  command -v git >/dev/null || missing+=("git (brew install git)")
  command -v gh >/dev/null || missing+=("gh (brew install gh)")
  if ((${#missing[@]})); then
    onboard_note "missing: ${missing[*]}"
    exit 1
  fi

  if ! git ls-remote "git@github.com:${GITHUB_ORG}/boyd.git" HEAD >/dev/null 2>&1; then
    onboard_note "cannot read ronintech-ai/boyd (SSH key, org invite, or wrong GitHub account)"
    github_help
    exit 1
  fi
  onboard_note "ronintech-ai/boyd: ok"

  local ssh_out ssh_rc=0
  if [[ -n ${GIT_SSH_COMMAND:-} ]]; then
    # shellcheck disable=SC2086
    ssh_out=$(eval "$GIT_SSH_COMMAND -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com" 2>&1) || ssh_rc=$?
  else
    ssh_out=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1) || ssh_rc=$?
  fi
  if [[ $ssh_rc -eq 1 ]]; then
    onboard_note "SSH: $(printf '%s' "$ssh_out" | tr -d '\r' | head -1)"
  elif [[ $ssh_rc -ne 0 ]]; then
    onboard_note "ssh -T failed (exit $ssh_rc) but git ls-remote succeeded"
  fi

  if command -v gh >/dev/null && gh auth status -h github.com >/dev/null 2>&1; then
    onboard_note "gh: logged in to github.com"
  else
    onboard_note "gh: not logged in (optional; run gh auth login for PRs)"
  fi
}

clone_one() {
  local dir=$1 repo=$2 required=$3
  local dest="$BOYD_WORK_ROOT/$dir" url="git@github.com:${GITHUB_ORG}/${repo}.git"
  if [[ -d $dest/.git ]]; then
    onboard_note "skip (exists): $dir"
    return 0
  fi
  onboard_note "clone → $dir"
  mkdir -p "$BOYD_WORK_ROOT"
  if git clone "$url" "$dest"; then
    return 0
  fi
  if [[ $required == 1 ]]; then
    onboard_note "required clone failed: $repo"
    github_help
    return 1
  fi
  onboard_note "optional clone failed (skipped): $repo"
  rmdir "$dest" 2>/dev/null || true
  return 0
}

cmd_clone() {
  maybe_git_ssh
  onboard_say "Clone repos into $BOYD_WORK_ROOT"
  [[ -f $MANIFEST ]] || { onboard_note "missing manifest: $MANIFEST"; exit 1; }
  local dir repo req
  while read -r dir repo req _; do
    [[ -z ${dir:-} || $dir == \#* ]] && continue
    clone_one "$dir" "$repo" "${req:-1}" || return 1
  done <"$MANIFEST"
}

write_workspace_envrc() {
  local envrc="$BOYD_WORK_ROOT/.envrc"
  [[ -f $envrc ]] && return 0
  onboard_say "Workspace .envrc"
  mkdir -p "$BOYD_WORK_ROOT"
  cat >"$envrc" <<'EOF'
export DEV_CONTEXT=ronintech
# Use GIT_SSH_COMMAND in your shell if you need a dedicated Ronintech GitHub key.
export AWS_PROFILE=rt-unclass
export AWS_REGION=us-east-2
export AWS_DEFAULT_REGION=us-east-2
EOF
  onboard_note "wrote $envrc (direnv allow ~/work/ronintech if you use direnv)"
}

boyd_from_brew() {
  command -v brew >/dev/null || return 1
  local prefix
  prefix=$(brew --prefix boyd 2>/dev/null) || return 1
  [[ -n $prefix && -d $prefix ]]
}

cmd_onboard() {
  cmd_github
  write_workspace_envrc
  cmd_clone
  onboard_say "Environment access (AWS SSO, kubectl, VPN, CA)"
  "$SETUP" setup
  if boyd_from_brew; then
    onboard_note "boyd CLI installed via Homebrew (no symlink)"
  else
    cmd_install
  fi
  onboard_say "Onboard complete"
  onboard_note "Next: cd $BOYD_WORK_ROOT/boyd && read docs/engineer-setup.md"
  onboard_note "VPN/Entra: if VPN connect is refused, Entra group assignment is still pending (separate ticket)."
}
