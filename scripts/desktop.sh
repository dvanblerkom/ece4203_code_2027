#!/bin/bash
# ECE4203 desktop helper: TigerVNC (:1, port 5901) + noVNC (port 6080).
#
#   desktop.sh status    show what is running, the URL, and recent log lines
#   desktop.sh ensure    start/repair the desktop only if it is not healthy (idempotent;
#                        run by postStartCommand)
#   desktop.sh restart   stop everything and start fresh
#   desktop.sh stop      stop VNC + noVNC
#   desktop.sh logs      print the tail of every desktop log
#   desktop.sh url       print the browser URL
#
# Normally the desktop-lite devcontainer feature starts the desktop from the
# container entrypoint (/usr/local/share/desktop-init.sh). If that script is not
# present (an image without the feature), this script falls back to starting
# TigerVNC + websockify itself ("legacy" mode).
#
# Everything is started with setsid+nohup so it is not killed when the calling
# shell or lifecycle command exits.

set -u

DISPLAY_NUM="${DISPLAY_NUM:-1}"
VNC_PORT="${VNC_PORT:-5901}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
VNC_RESOLUTION="${VNC_RESOLUTION:-1600x900x24}"
INIT_SCRIPT=/usr/local/share/desktop-init.sh
LOG_DIR="${HOME}/.cache/ece4203-desktop"
LOG="${LOG_DIR}/desktop.log"
XSTARTUP="${HOME}/.vnc/xstartup"
XSTARTUP_MARK="# managed-by: ece4203 scripts/desktop.sh"

mkdir -p "$LOG_DIR"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

# sudo without ever prompting (a prompt would hang postStartCommand).
asroot() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo -n "$@" 2>/dev/null || "$@"; fi
}

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

http_code() {
    local c
    c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${NOVNC_PORT}/vnc.html" 2>/dev/null)"
    echo "${c:-000}"
}

vnc_ok()     { port_open "$VNC_PORT"; }
web_ok()     { [ "$(http_code)" = "200" ]; }
healthy()    { vnc_ok && web_ok; }
session_ok() { pgrep -u "$(id -u)" -x xfce4-session >/dev/null || pgrep -u "$(id -u)" -x fluxbox >/dev/null; }

desktop_url() {
    local q="vnc.html?autoconnect=true&resize=remote"
    if [ -n "${CODESPACE_NAME:-}" ]; then
        echo "https://${CODESPACE_NAME}-${NOVNC_PORT}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-app.github.dev}/${q}"
    else
        echo "http://localhost:${NOVNC_PORT}/${q}"
    fi
}

# XFCE session inside TigerVNC. Only (re)written if missing or ours, so a
# student's own ~/.vnc/xstartup is left alone. Returns 0 if the file changed.
write_xstartup() {
    if [ -f "$XSTARTUP" ] && ! grep -qF "$XSTARTUP_MARK" "$XSTARTUP"; then
        return 1
    fi
    local tmp
    tmp="$(mktemp)"
    cat > "$tmp" <<EOF
#!/bin/sh
$XSTARTUP_MARK
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
command -v vncconfig >/dev/null 2>&1 && vncconfig -nowin &
if command -v startxfce4 >/dev/null 2>&1; then
    exec dbus-launch --exit-with-session startxfce4
fi
exec startfluxbox
EOF
    mkdir -p "$(dirname "$XSTARTUP")"
    if cmp -s "$tmp" "$XSTARTUP" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$XSTARTUP"
    chmod 755 "$XSTARTUP"
    log "wrote $XSTARTUP (XFCE session)"
    return 0
}

wait_healthy() {
    local secs="${1:-30}" i
    for ((i = 0; i < secs; i++)); do
        healthy && return 0
        sleep 1
    done
    return 1
}

wait_xfce() {
    local secs="${1:-15}" i
    for ((i = 0; i < secs; i++)); do
        pgrep -u "$(id -u)" -x xfce4-session >/dev/null && return 0
        sleep 1
    done
    return 1
}

stop_desktop() {
    log "stopping desktop"
    # Kill desktop-lite's keep-alive loops first so they do not respawn anything.
    # The [P] keeps pkill from matching its own sudo command line.
    asroot pkill -f '[P]rocess started.*(tigervncserver|novnc_proxy|launch.sh)' || true
    asroot pkill -f '[e]ce4203-desktop-loop' || true
    command -v tigervncserver >/dev/null && tigervncserver -kill ":${DISPLAY_NUM}" >/dev/null 2>&1
    pkill -u "$(id -u)" -x Xtigervnc 2>/dev/null || true
    asroot pkill -f '[n]ovnc_proxy' || true
    asroot pkill -f '[w]ebsockify' || true
    sleep 1
    asroot rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}"
    rm -f "${HOME}"/.vnc/*":${DISPLAY_NUM}.pid"
}

start_feature() {
    log "starting desktop via $INIT_SCRIPT"
    VNC_RESOLUTION="$VNC_RESOLUTION" setsid nohup "$INIT_SCRIPT" \
        >>"${LOG_DIR}/desktop-init.log" 2>&1 </dev/null &
}

# Fallback for images without the desktop-lite feature: same idea, our own loops.
start_legacy() {
    log "desktop-lite not installed; starting legacy TigerVNC + websockify"
    local geom="${VNC_RESOLUTION%x*}" depth="${VNC_RESOLUTION##*x}" web=/usr/share/novnc
    [ -d /usr/local/novnc ] && web="$(ls -d /usr/local/novnc/noVNC-* | head -1)"
    asroot mkdir -p /tmp/.X11-unix
    asroot chmod 1777 /tmp/.X11-unix
    setsid nohup bash -c "while :; do echo \"[\$(date)] ece4203-desktop-loop vnc start\";
        tigervncserver :${DISPLAY_NUM} -fg -localhost yes -rfbport ${VNC_PORT} \
            -geometry ${geom} -depth ${depth} -SecurityTypes VncAuth;
        sleep 3; done" >>"${LOG_DIR}/vnc.log" 2>&1 </dev/null &
    setsid nohup bash -c "while :; do echo \"[\$(date)] ece4203-desktop-loop websockify start\";
        websockify --web ${web} ${NOVNC_PORT} localhost:${VNC_PORT};
        sleep 3; done" >>"${LOG_DIR}/novnc.log" 2>&1 </dev/null &
}

start_desktop() {
    write_xstartup || true
    if [ -x "$INIT_SCRIPT" ]; then start_feature; else start_legacy; fi
    if wait_healthy 45; then
        log "desktop is up: $(desktop_url)"
    else
        log "ERROR: desktop did not come up within 45 s. Run: bash $0 logs"
        return 1
    fi
}

# Shell setup for terminals opened inside the noVNC desktop, via a block in ~/.bashrc.
#
# 1. PATH and tool variables. The container entrypoint starts the desktop through
#    `sudo -u user`, and sudo replaces PATH with its secure_path and drops the image's
#    ENV (PDK_ROOT, FLOW_HOME, ...). Every terminal opened in the desktop then lacks the
#    ORFS tools (openroad, yosys, sta) and the OSS CAD Suite (iverilog, vvp, gtkwave).
#    VS Code terminals are unaffected (login shells read /etc/profile.d/ece4203.sh).
#    Same order as the image: ORFS tools first, OSS CAD Suite last.
# 2. Working directory. Terminals there also start in $HOME; make an interactive shell
#    that starts in $HOME begin in the repo checkout instead (/workspaces/<repo name>;
#    the name varies for forks, so the first non-hidden directory is used).
#
# Rewritten on every start (replacing the old "workdir" block too), so changes to the
# block below reach existing Codespaces.
install_shell_hook() {
    local rc="${HOME}/.bashrc"
    [ -w "$rc" ] || [ ! -e "$rc" ] || return 0
    touch "$rc"
    sed -i -e '\|# >>> ece4203 workdir >>>|,\|# <<< ece4203 workdir <<<|d' \
           -e '\|# >>> ece4203 shell >>>|,\|# <<< ece4203 shell <<<|d' "$rc"
    cat >> "$rc" <<'HOOK'
# >>> ece4203 shell >>>
for _p in /OpenROAD-flow-scripts/tools/install/kepler-formal/bin \
          /OpenROAD-flow-scripts/tools/install/yosys/bin \
          /OpenROAD-flow-scripts/tools/install/OpenROAD/bin; do
    case ":$PATH:" in *":$_p:"*) ;; *) [ -d "$_p" ] && PATH="$_p:$PATH" ;; esac
done
case ":$PATH:" in
    *:/opt/oss-cad-suite/bin:*) ;;
    *) [ -d /opt/oss-cad-suite/bin ] && PATH="$PATH:/opt/oss-cad-suite/bin" ;;
esac
unset _p
export PATH PDK_ROOT="${PDK_ROOT:-/opt/pdk}" PDK="${PDK:-sky130A}" \
       FLOW_HOME="${FLOW_HOME:-/OpenROAD-flow-scripts/flow}"
# A desktop terminal starts in the session's cwd: $HOME or the image's WORKDIR.
if { [ "$PWD" = "$HOME" ] || [ "$PWD" = /OpenROAD-flow-scripts ]; } && [ -z "${ECE4203_CD_DONE:-}" ]; then
    export ECE4203_CD_DONE=1
    for _d in /workspaces/*/; do
        [ -d "$_d" ] && { cd "${_d%/}" || true; break; }
    done
    unset _d
fi
# <<< ece4203 shell <<<
HOOK
}

cmd_ensure() {
    local changed=1
    install_shell_hook
    write_xstartup && changed=0
    # On container start the entrypoint may still be starting the desktop.
    if wait_healthy 20; then
        if [ "$changed" -eq 0 ] && ! wait_xfce 15; then
            log "desktop up but not running the XFCE session; restarting once"
            stop_desktop
            start_desktop
            return
        fi
        log "desktop already healthy: $(desktop_url)"
        return 0
    fi
    log "desktop not healthy (vnc:$(vnc_ok && echo up || echo down) novnc-http:$(http_code)); repairing"
    stop_desktop
    start_desktop
}

cmd_status() {
    local yes="OK" no="--"
    echo "VNC server  :${DISPLAY_NUM} port ${VNC_PORT}   $(vnc_ok && echo $yes || echo $no)"
    echo "noVNC http  port ${NOVNC_PORT} /vnc.html   HTTP $(http_code)"
    echo "X session   $(session_ok && echo $yes || echo $no)  ($(pgrep -u "$(id -u)" -x xfce4-session >/dev/null && echo xfce || (pgrep -x fluxbox >/dev/null && echo fluxbox || echo none)))"
    echo "mode        $([ -x "$INIT_SCRIPT" ] && echo desktop-lite || echo legacy)"
    echo "URL         $(desktop_url)"
    echo
    echo "Processes:"
    ps -eo pid,user,etime,args | grep -E '[X]tigervnc|[n]ovnc_proxy|[w]ebsockify|[x]fce4-session|[f]luxbox' || echo "  (none)"
    echo
    echo "Last log lines ($LOG):"
    tail -n 5 "$LOG" 2>/dev/null || echo "  (no log yet)"
}

cmd_logs() {
    local f
    declare -A seen=()
    for f in "$LOG" "${LOG_DIR}"/*.log /tmp/container-init.log /tmp/Xtigervnc.log /tmp/noVNC.log \
             "${HOME}"/.vnc/*.log; do
        [ -f "$f" ] && [ -z "${seen[$f]:-}" ] || continue
        seen[$f]=1
        echo "===== $f ====="
        tail -n 40 "$f"
        echo
    done
}

case "${1:-status}" in
    status)  cmd_status ;;
    ensure)  cmd_ensure ;;
    restart) stop_desktop; start_desktop ;;
    stop)    stop_desktop ;;
    start)   healthy && log "already running" || start_desktop ;;
    logs)    cmd_logs ;;
    url)     desktop_url ;;
    *) sed -n '2,12p' "$0"; exit 2 ;;
esac
