#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Keep a route to the robot's subnet on your LAN interface across reboots (macOS).
#
# A TUN-mode proxy (Clash and similar) can take the return traffic for a subnet that is not
# the computer's own, and the robot's WebSocket then drops every few seconds. A static route
# through your router fixes that, but `route add` is lost at reboot. This installs a launchd
# daemon that re-adds the route at boot.
#
#   sudo ./install_lan_route_macos.sh install   <subnet/prefix> <router-ip>
#   sudo ./install_lan_route_macos.sh uninstall <subnet/prefix>
#   ./install_lan_route_macos.sh print          <subnet/prefix> <router-ip>   # show the plist only
#
# Example: sudo ./install_lan_route_macos.sh install 192.168.19.0/24 192.168.8.1
# Check it:  route -n get <robot IP> | grep interface    (should be your LAN interface, not utun*)

set -euo pipefail

action="${1:-}"
subnet="${2:-}"
router="${3:-}"

usage() {
    sed -n '4,16p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

[[ -n "$action" && -n "$subnet" ]] || usage
[[ "$subnet" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] || { echo "subnet must look like 192.168.19.0/24" >&2; exit 2; }
if [[ "$action" != "uninstall" ]]; then
    [[ "$router" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "router must be an IPv4 address" >&2; exit 2; }
fi

label="local.groki.lanroute.${subnet//[\/.]/-}"
plist="/Library/LaunchDaemons/${label}.plist"

render_plist() {
    # The interface may not be up yet at boot, so retry for a minute.
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>-c</string>
        <string>for i in \$(seq 1 30); do /sbin/route -n add -net ${subnet} ${router} &amp;&amp; exit 0; /sbin/route -n change -net ${subnet} ${router} &amp;&amp; exit 0; sleep 2; done; exit 1</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF
}

case "$action" in
print)
    render_plist
    ;;
install)
    [[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
    render_plist >"$plist"
    chown root:wheel "$plist"
    chmod 644 "$plist"
    plutil -lint "$plist"
    launchctl bootout system "$plist" 2>/dev/null || true
    launchctl bootstrap system "$plist"
    echo "installed $plist"
    route -n get "${subnet%/*}" | grep -E "gateway|interface" || true
    ;;
uninstall)
    [[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
    launchctl bootout system "$plist" 2>/dev/null || true
    rm -f "$plist"
    /sbin/route -n delete -net "$subnet" 2>/dev/null || true
    echo "removed $plist"
    ;;
*)
    usage
    ;;
esac
