#!/usr/bin/env bash
set -euo pipefail

record_fatal_error() {
    local msg="$1"
    if [ ! -s /run/fatal-error ]; then
        printf '%s\n' "$msg" > /run/fatal-error || true
    fi
    printf '%s\n' "$msg" >&2 || true
}

trap 'status=$?; trap - EXIT; if [ "$status" -ne 0 ] && [ ! -s /run/fatal-error ]; then if [ -n "${step:-}" ]; then record_fatal_error "Unattended step failed: ${step#root:}. Please consult logs (ctrl+alt+f1)."; else record_fatal_error "Unattended mode failed. Please consult logs (ctrl+alt+f1)."; fi; fi; exit "$status"' EXIT

IFS=',' read -ra steps <<< "${STEPS}"
total=${#steps[@]}
chvt 2

# Initial setup - only once
clear
width=$(tput cols)
lines=$(tput lines)

# Set up colors and scroll region once
tput csr 3 "$lines"
tput cup 3 0
tput setaf 0
tput setab 7
tput ed

update_header() {
    local current=$1 step=$2
    local divider=$(printf '─%.0s' $(seq 1 "$width"))
    # Save cursor, exit scroll region temporarily
    tput sc
    tput csr 0 "$lines"
    # Draw header
    tput cup 0 0
    tput setaf 7; tput setab 4
    printf "%-${width}s" "$divider"
    printf "%-${width}s" " $current/$total: $step"
    printf "%-${width}s" "$divider"
    # Restore scroll region and cursor
    tput csr 3 "$lines"
    tput rc
    tput setaf 0; tput setab 7
}

for i in "${!steps[@]}"; do
    step="${steps[$i]}"
    current=$((i + 1))

    update_header "$current" "$step"

    # Print step divider in scroll area (so prior steps are delineated)
    printf '\n%s\n' "── Step $current: $step ──"

    cmd="${step#root:}"
    if [[ "$step" == root:* ]]; then
        cmd="doas $cmd"
    fi
    script -q -c "$cmd" /dev/null 2>&1 | tee >(systemd-cat -t "step-$current")

    tput setaf 0
    tput setab 7
done

tput csr 0 "$lines"
tput sgr0
tput cup "$lines" 0
chvt 1
systemctl poweroff --no-block --force
