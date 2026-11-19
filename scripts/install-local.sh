#!/bin/zsh -f
# Build this fork and install it as the Mac's apw, without touching the running daemon.
#   scripts/install-local.sh            build + test + install to $APW_PREFIX (default ~/.local/opt/apw/bin)
#   --link                              also point /opt/homebrew/bin/apw at it (brew unlink apw first; undo: brew link apw)
# Installs launchd job com.lod.apw-pinread (on demand: the daemon kickstarts it when apw is unpaired).
# The daemon job com.lod.apw is never restarted here: `launchctl kickstart -k gui/$(id -u)/com.lod.apw` does that.
set -euo pipefail
cd "${0:A:h}/.."
prefix=${APW_PREFIX:-$HOME/.local/opt/apw/bin}
label=${APW_PINREAD_LABEL:-com.lod.apw-pinread}
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

plist=$HOME/Library/LaunchAgents/$label.plist
mkdir -p "$HOME/skill-logs/apw"
cat > "$plist.new" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>ProgramArguments</key>
	<array>
		<string>$prefix/apw-pinread</string>
	</array>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardErrorPath</key>
	<string>$HOME/skill-logs/apw/log.md</string>
	<key>StandardOutPath</key>
	<string>$HOME/skill-logs/apw/log.md</string>
</dict>
</plist>
PLIST
plutil -lint -s "$plist.new"
if ! cmp -s "$plist.new" "$plist" 2>/dev/null; then
  mv -f "$plist.new" "$plist"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
else
  rm -f "$plist.new"
  launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 || launchctl bootstrap "gui/$(id -u)" "$plist"
fi

if [[ ${1:-} == --link ]]; then
  brew_apw=$(brew --prefix)/bin/apw
  if [[ -L $brew_apw && $(readlink "$brew_apw") == *Cellar/apw/* ]]; then brew unlink apw >/dev/null; fi
  ln -sfn "$prefix/apw" "$brew_apw"
  print "linked $brew_apw -> $prefix/apw"
fi
print "installed $prefix/apw and $prefix/apw-pinread; launchd $label loaded"
