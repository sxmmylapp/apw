#!/bin/zsh -f
# Build this fork and install it as the Mac's apw, without touching the running daemon.
#   scripts/install-local.sh            build + test + install to $APW_PREFIX (default ~/.local/opt/apw/bin)
#   --link                              also point /opt/homebrew/bin/apw at it (brew unlink apw first; undo: brew link apw)
# Installs launchd jobs com.lod.apw-pinread (on demand: the daemon kickstarts it when apw is unpaired) and
# com.lod.apw-chromepair (always on: types the iCloud Passwords code into the everyday Chrome, see pinread/chrome.swift).
# The daemon job com.lod.apw is never restarted here: `launchctl kickstart -k gui/$(id -u)/com.lod.apw` does that.
set -euo pipefail
cd "${0:A:h}/.."
prefix=${APW_PREFIX:-$HOME/.local/opt/apw/bin}
label=${APW_PINREAD_LABEL:-com.lod.apw-pinread}
chrome_label=${APW_CHROMEPAIR_LABEL:-com.lod.apw-chromepair}
identity=${APW_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}

deno task test
deno task compile
# A real signing identity gives apw-pinread a designated requirement that survives rebuilds, so its
# Accessibility grant stays valid. Ad hoc (no identity) works but every rebuild needs a new grant.
if [[ -n $identity ]]; then
  codesign -f -s "$identity" -i "$label" -o runtime pinread/apw-pinread
else
  print -u2 "warning: no Apple Development identity; apw-pinread is ad-hoc signed (re-grant Accessibility after each build)"
  codesign -f -s - -i "$label" pinread/apw-pinread
fi

mkdir -p "$prefix"
for bin in apw pinread/apw-pinread; do
  # Same-file replace keeps the path (and its grant) while the old binary keeps running.
  cp "$bin" "$prefix/${bin:t}.new" && mv -f "$prefix/${bin:t}.new" "$prefix/${bin:t}"
done
[[ $identity == "" ]] || codesign -v "$prefix/apw-pinread"

mkdir -p "$HOME/skill-logs/apw"
# install_job <label> <keepalive true|false> <args...>: write the plist, (re)load it only when it changed.
install_job() {
  local job=$1 keep=$2; shift 2
  local plist=$HOME/Library/LaunchAgents/$job.plist a args="" extra=""
  for a in "$@"; do args+="		<string>$a</string>
"; done
  [[ $keep == true ]] && extra="	<key>KeepAlive</key>
	<true/>
	<key>RunAtLoad</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>10</integer>
"
  cat > "$plist.new" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$job</string>
	<key>ProgramArguments</key>
	<array>
$args	</array>
	<key>ProcessType</key>
	<string>Interactive</string>
$extra	<key>StandardErrorPath</key>
	<string>$HOME/skill-logs/apw/log.md</string>
	<key>StandardOutPath</key>
	<string>$HOME/skill-logs/apw/log.md</string>
</dict>
</plist>
PLIST
  plutil -lint -s "$plist.new"
  if ! cmp -s "$plist.new" "$plist" 2>/dev/null; then
    mv -f "$plist.new" "$plist"
    launchctl bootout "gui/$(id -u)/$job" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$plist"
  else
    rm -f "$plist.new"
    if launchctl print "gui/$(id -u)/$job" >/dev/null 2>&1; then
      # Same plist, new binary: a running watcher restarts onto it.
      [[ $keep == true ]] && launchctl kickstart -k "gui/$(id -u)/$job"
    else
      launchctl bootstrap "gui/$(id -u)" "$plist"
    fi
  fi
}
# On demand: the daemon kickstarts it when apw is unpaired.
install_job "$label" false "$prefix/apw-pinread"
# Always on: keeps the everyday Google Chrome's iCloud Passwords extension paired (pinread/chrome.swift).
# Same binary as apw-pinread, so it runs under apw-pinread's Accessibility grant.
install_job "$chrome_label" true "$prefix/apw-pinread" --watch-chrome

if [[ ${1:-} == --link ]]; then
  brew_apw=$(brew --prefix)/bin/apw
  if [[ -L $brew_apw && $(readlink "$brew_apw") == *Cellar/apw/* ]]; then brew unlink apw >/dev/null; fi
  ln -sfn "$prefix/apw" "$brew_apw"
  print "linked $brew_apw -> $prefix/apw"
fi
print "installed $prefix/apw and $prefix/apw-pinread; launchd $label and $chrome_label loaded"
