#!/bin/bash
# Isolated regression checks for cleanup_daemon_mode and broken-link hygiene.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/docker/scripts/update_helper.sh"
FAILS=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log_message() { printf '[%s] %s\n' "$2" "$1" >> "$CASE_LOG"; }
source "$HELPER"

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }

make_state() {
    local root="$1"
    mkdir -p "$root/steamcmd" "$root/Steam" "$root/steamapps"
    printf 'keep\n' > "$root/steamcmd/tool"
    printf 'keep\n' > "$root/Steam/state"
    printf 'keep\n' > "$root/steamapps/appmanifest_730.acf"
}

state_exists() {
    local root="$1"
    [[ -f "$root/steamcmd/tool" && -f "$root/Steam/state" && -f "$root/steamapps/appmanifest_730.acf" ]]
}

run_preserve_without_evidence() {
    local root="$TMP/no-evidence/home/container"
    CASE_LOG="$TMP/no-evidence.log"; : > "$CASE_LOG"
    make_state "$root"
    SRCDS_STOP_UPDATE=1; unset DAEMON_EVIDENCE_FOUND
    cleanup_daemon_mode "$root"
    if state_exists "$root" && grep -q 'preserving local SteamCMD state' "$CASE_LOG"; then
        pass 'standalone SRCDS_STOP_UPDATE=1 preserves all local SteamCMD state'
    else
        fail 'standalone SRCDS_STOP_UPDATE=1 preserves all local SteamCMD state'
    fi
}

run_preserve_false_evidence() {
    local root="$TMP/false-evidence/home/container"
    CASE_LOG="$TMP/false-evidence.log"; : > "$CASE_LOG"
    make_state "$root"
    SRCDS_STOP_UPDATE=1; DAEMON_EVIDENCE_FOUND=yes
    cleanup_daemon_mode "$root"
    if state_exists "$root"; then
        pass 'non-exact daemon evidence remains fail-closed'
    else
        fail 'non-exact daemon evidence remains fail-closed'
    fi
}

run_daemon_cleanup() {
    local root="$TMP/daemon/home/container"
    CASE_LOG="$TMP/daemon.log"; : > "$CASE_LOG"
    make_state "$root"
    SRCDS_STOP_UPDATE=1; DAEMON_EVIDENCE_FOUND=1
    cleanup_daemon_mode "$root"
    if [[ ! -e "$root/steamcmd" && ! -e "$root/Steam" && ! -e "$root/steamapps" ]] \
        && grep -q 'Daemon mode active' "$CASE_LOG"; then
        pass 'observed daemon retains existing cleanup behavior'
    else
        fail 'observed daemon retains existing cleanup behavior'
    fi
}

run_update_enabled_preserve() {
    local root="$TMP/update-enabled/home/container"
    CASE_LOG="$TMP/update-enabled.log"; : > "$CASE_LOG"
    make_state "$root"
    SRCDS_STOP_UPDATE=0; DAEMON_EVIDENCE_FOUND=1
    cleanup_daemon_mode "$root"
    if state_exists "$root"; then
        pass 'cleanup is inactive while updates are enabled'
    else
        fail 'cleanup is inactive while updates are enabled'
    fi
}

run_broken_link_hygiene() {
    local game="$TMP/game"
    CASE_LOG="$TMP/broken-link.log"; : > "$CASE_LOG"
    mkdir -p "$game/csgo"
    printf 'vpk\n' > "$game/csgo/real.vpk"
    ln -s "$TMP/missing.vpk" "$game/csgo/broken.vpk"
    GAME_DIR="$game"; SRCDS_STOP_UPDATE=0
    cleanup_broken_vpk_symlinks
    if [[ -f "$game/csgo/real.vpk" && ! -L "$game/csgo/broken.vpk" ]]; then
        pass 'broken VPK cleanup removes only dangling symlinks'
    else
        fail 'broken VPK cleanup removes only dangling symlinks'
    fi

    ln -s "$TMP/still-missing.vpk" "$game/csgo/stopped.vpk"
    SRCDS_STOP_UPDATE=1
    cleanup_broken_vpk_symlinks
    if [[ -L "$game/csgo/stopped.vpk" ]]; then
        pass 'broken VPK cleanup remains disabled in stop-update mode'
    else
        fail 'broken VPK cleanup remains disabled in stop-update mode'
    fi
}

run_preserve_without_evidence
run_preserve_false_evidence
run_daemon_cleanup
run_update_enabled_preserve
run_broken_link_hygiene

if ((FAILS > 0)); then
    printf '\n%d cleanup regression case(s) failed\n' "$FAILS"
    exit 1
fi
printf '\nAll cleanup preservation cases passed\n'
