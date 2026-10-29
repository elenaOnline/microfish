#!/bin/zsh
# Local end-to-end proof that Sparkle updates Microfish the way CONTRACT.md says, without any UI.
#
#   app/Tests/update-e2e/run.sh [--evidence DIR]
#
# Builds a probe app (net.webreceptor.microfish.updateprobe, LSUIElement: no Dock icon, no window, no sound,
# no notification) that compiles the app's real app/Sources/Updates.swift + UpdateModel.swift and drives them
# with a headless SPUUserDriver. Three versions use the CONTRACT version numbers:
#   v1 1.0.0 (1000099) stable   v2 1.1.0 (1010099) stable   v3 1.2.0-beta.1 (1020001) beta channel
# They are signed (Developer ID when MICROFISH_SIGN_IDENTITY works non-interactively, else ad hoc), zipped with
# ditto, and published through a throwaway appcast on 127.0.0.1 signed with a throwaway EdDSA key
# (Sparkle account microfish-test; deleted again at the end). The probe fakes the engine with a child
# process, so "the engine was stopped before the bundle was replaced" is observable.
#
# Scenarios (each starts from a fresh install in the scratch directory):
#   A  v1, beta off: updates to v2, not v3          B  engine stopped before the bundle was replaced
#   C  relaunch as 1.1.0 with a new PID             D  v1, beta on: updates to v3
#   E  v3, beta turned off: no downgrade            F  tampered zip / item signed with another key: rejected
#   G  engine can't be stopped: nothing installed   H  automatic download installs on quit, engine stopped first
#   I  Settings controls reach Sparkle and persist (Info.plist SUEnableAutomaticChecks = YES)
#
# Safety: kills only PIDs it started (the HTTP server, the watcher, probe copies and their fake engines, each
# checked against the scratch path / command line first); the live Microfish install is never touched;
# nothing is shown on screen, and a read-only window watcher records any window Sparkle's helpers create (and whether it overlaps a display).
set -u
here=${0:A:h}
app=${here:h:h}
sparkle=$app/Vendor/Sparkle
evidence=""
[[ "${1:-}" == --evidence ]] && evidence=${2:?}

S=$(mktemp -d /tmp/mf-update-e2e-XXXXXX)
S=$(cd $S && pwd -P)   # /private/tmp/...: what ps and proc_pidpath report for relaunched copies
[[ -n $evidence ]] || evidence=$S/evidence
mkdir -p $evidence $S/build $S/stage $S/feed $S/install $S/work $S/keys
chmod 700 $S/keys
install=$S/install/MicrofishUpdateProbe.app
work=$S/work
events=$work/events.jsonl
id=net.webreceptor.microfish.updateprobe
evq=(/usr/bin/python3 -I $here/evq.py)
pass=0; fail=0; results=()
server_pid=""; watcher_pid=""; probe_pids=()

note() { print -r -- "$*"; }
check() {   # check <label> <command string, evaluated here>
  local label=$1; shift
  if eval "$*" >/dev/null 2>&1; then pass=$((pass+1)); results+=("PASS  $label"); note "  PASS  $label"
  else fail=$((fail+1)); results+=("FAIL  $label"); note "  FAIL  $label"; fi
}

# --- cleanup: only what this script started -----------------------------------------------------------
own_pid() {   # own_pid <pid>: is it one of ours (scratch path or the fake engine command)?
  local cmd; cmd=$(/bin/ps -p $1 -o command= 2>/dev/null) || return 1
  [[ $cmd == $S/* || $cmd == "/bin/sleep 3000" || $cmd == */Library/Caches/$id/* ]]
}
cleanup() {
  [[ -n $server_pid ]] && kill $server_pid 2>/dev/null
  [[ -n $watcher_pid ]] && kill $watcher_pid 2>/dev/null
  collect_pids
  for p in $probe_pids; do own_pid $p && kill $p 2>/dev/null; done
  sleep 0.5
  for p in $probe_pids; do own_pid $p && kill -9 $p 2>/dev/null; done
  for acct in microfish-test microfish-test-other; do
    security delete-generic-password -s "https://sparkle-project.org" -a $acct >/dev/null 2>&1
  done
  defaults delete $id >/dev/null 2>&1
  rm -rf "$HOME/Library/Caches/$id" "$HOME/Library/Caches/org.sparkle-project.Sparkle" 2>/dev/null
  rm -rf $S/keys
  note "scratch directory kept for inspection: $S (delete it when done)"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
collect_pids() { probe_pids=($(cat $S/pids.txt 2>/dev/null | sort -u)); }
remember_pids() {   # append this scenario's PIDs to the list used by cleanup
  [[ -f $events ]] || return 0
  /usr/bin/python3 -I -c '
import json,sys
for l in open(sys.argv[1]):
    try: e=json.loads(l)
    except ValueError: continue
    if e["event"]=="launch": print(e["pid"])
    if e["event"]=="engine-start": print(e["enginePid"])
' $events >> $S/pids.txt 2>/dev/null
}

# --- signing identity ----------------------------------------------------------------------------------
identity=${MICROFISH_SIGN_IDENTITY:--}
sign_mode="Developer ID (MICROFISH_SIGN_IDENTITY)"
if [[ $identity != - ]]; then
  cp /bin/echo $S/build/signtest
  if ! /usr/bin/codesign --force --options runtime --timestamp --sign "$identity" $S/build/signtest >$S/build/signtest.log 2>&1; then
    note "Developer ID signing failed non-interactively; falling back to ad hoc"; identity=-
  fi
fi
[[ $identity == - ]] && sign_mode="ad hoc ('-')"
note "signing: $sign_mode"
ts=(--timestamp); [[ $identity == - ]] && ts=()
ent=()
if [[ $identity == - ]]; then   # ad hoc has no team id, so hardened runtime needs library validation off
  cat > $S/build/probe.entitlements <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.cs.disable-library-validation</key><true/></dict></plist>
EOF
  ent=(--entitlements $S/build/probe.entitlements)
fi

# --- keys (throwaway; the real release key, account "microfish", is never touched) ---------------------
note "keys: throwaway Sparkle accounts microfish-test and microfish-test-other"
for acct in microfish-test microfish-test-other; do
  $sparkle/bin/generate_keys --account $acct >/dev/null 2>&1 || { note "generate_keys failed for $acct"; exit 2; }
  ( umask 077; $sparkle/bin/generate_keys --account $acct -x $S/keys/$acct.key >/dev/null 2>&1 ) || { note "key export failed"; exit 2; }
done
pubkey=$($sparkle/bin/generate_keys --account microfish-test -p 2>/dev/null)
note "public key (microfish-test): $pubkey"

# --- build ---------------------------------------------------------------------------------------------
port=$(/usr/bin/python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
if lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; then note "port $port busy"; exit 2; fi
feed=http://127.0.0.1:$port
note "building probe (swiftc) ..."
swiftc -O -suppress-warnings -F $sparkle -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -framework AppKit -framework SwiftUI -o $S/build/MicrofishUpdateProbe \
  $app/Sources/Updates.swift $app/Sources/UpdateModel.swift $here/probe/main.swift || { note "probe build failed"; exit 2; }
swiftc -O -o $S/build/watcher $here/watcher.swift || { note "watcher build failed"; exit 2; }

make_app() {   # make_app <dir> <short> <build> [feed url] [auto-checks YES|NO]
  local dir=$1 short=$2 bld=$3 feedurl=${4:-$feed/appcast.xml} autochk=${5:-false}
  local a=$dir/MicrofishUpdateProbe.app
  rm -rf $dir; mkdir -p $a/Contents/MacOS $a/Contents/Frameworks
  cp $S/build/MicrofishUpdateProbe $a/Contents/MacOS/
  /usr/bin/ditto $sparkle/Sparkle.framework $a/Contents/Frameworks/Sparkle.framework
  cat > $a/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
 <key>CFBundleExecutable</key><string>MicrofishUpdateProbe</string>
 <key>CFBundleIdentifier</key><string>$id</string>
 <key>CFBundleName</key><string>MicrofishUpdateProbe</string>
 <key>CFBundlePackageType</key><string>APPL</string>
 <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
 <key>CFBundleShortVersionString</key><string>$short</string>
 <key>CFBundleVersion</key><string>$bld</string>
 <key>LSMinimumSystemVersion</key><string>14.0</string>
 <key>LSUIElement</key><true/>
 <key>NSPrincipalClass</key><string>NSApplication</string>
 <key>SUFeedURL</key><string>$feedurl</string>
 <key>SUPublicEDKey</key><string>$pubkey</string>
 <key>SUEnableAutomaticChecks</key><$autochk/>
</dict></plist>
EOF
  $app/Scripts/sign-sparkle.sh $a/Contents/Frameworks/Sparkle.framework $identity >$dir/sign.log 2>&1 || { note "sign-sparkle failed"; cat $dir/sign.log; exit 2; }
  /usr/bin/codesign --force --options runtime $ts $ent --sign $identity $a >>$dir/sign.log 2>&1 || { note "app signing failed"; cat $dir/sign.log; exit 2; }
  /usr/bin/codesign --verify --strict --deep $a || { note "signature verify failed"; exit 2; }
}
make_app $S/stage/v1 1.0.0 1000099
make_app $S/stage/v2 1.1.0 1010099
make_app $S/stage/v3 1.2.0-beta.1 1020001
make_app $S/stage/v1cfg 1.0.0 1000099 http://127.0.0.1:1/never.xml true
note "built v1 1.0.0 (1000099), v2 1.1.0 (1010099), v3 1.2.0-beta.1 (1020001), signed with $sign_mode"
note "Sparkle framework signature: $(/usr/bin/codesign -dvv $S/stage/v1/MicrofishUpdateProbe.app/Contents/Frameworks/Sparkle.framework 2>&1 | grep -E '^Authority=|Signature=adhoc' | head -1 | sed 's/:.*//')"

zipapp() { ( cd $S/stage/$1 && /usr/bin/ditto -c -k --sequesterRsrc --keepParent MicrofishUpdateProbe.app $2 ); }
zipapp v2 $S/feed/Probe-1.1.0.zip
zipapp v3 $S/feed/Probe-1.2.0-beta.1.zip
sign() { $sparkle/bin/sign_update --ed-key-file $S/keys/$2.key $1; }   # prints sparkle:edSignature="…" sparkle:length="…"

item() {   # item <title> <short> <build> <zipname> <signature-attrs> [channel]
  local chan=""; [[ -n ${6:-} ]] && chan="<sparkle:channel>$6</sparkle:channel>"
  cat <<EOF
  <item>
   <title>$1</title>
   <sparkle:version>$3</sparkle:version>
   <sparkle:shortVersionString>$2</sparkle:shortVersionString>
   <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
   $chan
   <enclosure url="$feed/$4" $5 type="application/octet-stream"/>
  </item>
EOF
}
appcast() { { echo '<?xml version="1.0" encoding="utf-8"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Microfish probe</title>'; cat; echo '</channel></rss>'; } > $S/feed/appcast.xml; }
sig_v2=$(sign $S/feed/Probe-1.1.0.zip microfish-test)
sig_v3=$(sign $S/feed/Probe-1.2.0-beta.1.zip microfish-test)
{ item "1.1.0" 1.1.0 1010099 Probe-1.1.0.zip "$sig_v2"; item "1.2.0-beta.1" 1.2.0-beta.1 1020001 Probe-1.2.0-beta.1.zip "$sig_v3" beta; } | appcast
cp $S/feed/appcast.xml $evidence/appcast-main.xml

# tampered zip (same length, one byte flipped, original signature) and a zip signed by another key
cp $S/feed/Probe-1.1.0.zip $S/feed/Probe-1.1.0-tampered.zip
/usr/bin/python3 -I -c '
import sys
p=sys.argv[1]; b=bytearray(open(p,"rb").read()); i=len(b)//2; b[i]^=0xFF; open(p,"wb").write(b)' $S/feed/Probe-1.1.0-tampered.zip
cp $S/feed/Probe-1.1.0.zip $S/feed/Probe-1.1.0-otherkey.zip
sig_other=$(sign $S/feed/Probe-1.1.0-otherkey.zip microfish-test-other)
item "1.1.0" 1.1.0 1010099 Probe-1.1.0-tampered.zip "$sig_v2" > $S/feed/tampered.item
item "1.1.0" 1.1.0 1010099 Probe-1.1.0-otherkey.zip "$sig_other" > $S/feed/otherkey.item

# --- feed server (127.0.0.1 only, own PID) -------------------------------------------------------------
( cd $S/feed && exec /usr/bin/python3 -I -m http.server $port --bind 127.0.0.1 >$S/server.log 2>&1 ) &
server_pid=$!
for i in {1..50}; do /usr/bin/curl -sf $feed/appcast.xml >/dev/null && break; sleep 0.1; done
/usr/bin/curl -sf $feed/appcast.xml >/dev/null || { note "feed server did not start"; exit 2; }
note "feed: $feed/appcast.xml (server pid $server_pid)"

# --- scenario helpers ----------------------------------------------------------------------------------
control() { print -r -- "$1" > $work/control.json; }
start_watcher() {
  $S/build/watcher $install $S $work/watcher.log & watcher_pid=$!
  sleep 0.3
}
stop_watcher() { if [[ -n $watcher_pid ]]; then kill $watcher_pid 2>/dev/null; wait $watcher_pid 2>/dev/null; fi; watcher_pid=""; }
fresh() {   # fresh <stage dir name> <control json>
  stop_watcher
  [[ -n ${launched_pid:-} ]] && own_pid $launched_pid && kill $launched_pid 2>/dev/null
  rm -rf $S/install; mkdir -p $S/install; rm -f $work/*(N)
  defaults delete $id >/dev/null 2>&1; rm -rf "$HOME/Library/Caches/$id" 2>/dev/null
  /usr/bin/ditto $S/stage/$1 $S/install
  control "$2"
  start_watcher
  $install/Contents/MacOS/MicrofishUpdateProbe >$work/stdout.log 2>&1 & launched_pid=$!
  echo $launched_pid >> $S/pids.txt
}
finish() {   # finish <scenario name>: save evidence, stop everything this scenario started
  remember_pids
  sleep 0.5
  stop_watcher
  mkdir -p $evidence/$1
  cp $work/events.jsonl $work/watcher.log $work/stdout.log $evidence/$1/ 2>/dev/null
  $evq list $evidence/$1/events.jsonl > $evidence/$1/events.txt 2>/dev/null
  for p in $(cat $S/pids.txt 2>/dev/null | sort -u); do own_pid $p && kill $p 2>/dev/null; done
  sleep 0.5
  launched_pid=""
}
ev() { $evq has $events "$@"; }
evget() { $evq get $events "$@"; }
wait_ev() { $evq wait $events "$@" >/dev/null; }
installed_version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $install/Contents/Info.plist 2>/dev/null; }
exec_hash() { /usr/bin/shasum -a 256 $install/Contents/MacOS/MicrofishUpdateProbe 2>/dev/null | cut -d' ' -f1; }
watcher_t() { awk -v pat="$1" '$0 ~ pat { print $1; exit }' $work/watcher.log; }
alive() { kill -0 $1 2>/dev/null; }

# ============================ A, B, C: stable update, beta off ===========================================
note ""; note "== A/B/C: v1 (beta off) -> v2"
fresh v1 '{"check":true,"beta":false,"prepare":"ok","prepareDelay":1.5}'
pid1=$launched_pid
wait_ev 60 event=launch version=1.1.0 || true
sleep 1
check "A: v1 with beta off found 1.1.0" 'ev event=driver:update-found found=1.1.0'
check "A: ... and never 1.2.0-beta.1" '! ev found=1.2.0-beta.1'
check "A: installed bundle is 1.1.0" 'test "$(installed_version)" = 1.1.0'
check "A: installed bundle still validates (codesign --verify --strict --deep)" '/usr/bin/codesign --verify --strict --deep $install'
t_prep_begin=$(evget t event=prepare-begin); t_prep_end=$(evget t event=prepare-end); t_swap=$(watcher_t "bundle-version 1.1.0")
check "B: prepare hook ran and the engine was gone when it finished" 'ev event=prepare-end engineGone=True'
check "B: prepare finished before the bundle was replaced (prepare-end $t_prep_end < bundle swap $t_swap)" "/usr/bin/python3 -I -c \"import sys; sys.exit(0 if float('${t_prep_end:-1}') < float('${t_swap:-0}') else 1)\""
check "B: Sparkle waited for the hook (>= 1.4 s from prepare-begin to prepare-end)" "/usr/bin/python3 -I -c \"import sys; sys.exit(0 if float('${t_prep_end:-0}')-float('${t_prep_begin:-0}') >= 1.4 else 1)\""
engine1=$(evget enginePid event=prepare-begin)
check "B: the old engine process ($engine1) is gone" 'test -n "$engine1" && ! alive $engine1'
check "B: terminate went terminate-request -> terminate-now without a second quit sequence" 'ev event=terminate-now && ! ev event=quit-engine-stopped'
check "B: the old process (pid $pid1) is gone" '! alive $pid1'
pid2=$(evget pid event=launch version=1.1.0)
check "C: relaunched as 1.1.0 with a new PID ($pid1 -> $pid2)" 'test -n "$pid2" -a "$pid2" != "$pid1"'
check "C: the relaunched app started its own engine again" 'ev event=engine-start pid=$pid2'
check "C: update-cycle-ended did not fire before the app terminated" "/usr/bin/python3 -I -c \"
import json,sys
ev=[json.loads(l) for l in open('$events')]
te=[e['t'] for e in ev if e['event']=='terminate-now'][0]
ce=[e['t'] for e in ev if e['event']=='update-cycle-ended' and e['pid']==$pid1]
sys.exit(0 if all(t>=te for t in ce) else 1)\""
finish A

# ============================ D: beta on =================================================================
note ""; note "== D: v1 (beta on) -> v3"
fresh v1 '{"check":true,"beta":true,"prepare":"ok","prepareDelay":0.5}'
pid1=$launched_pid
wait_ev 60 event=launch version=1.2.0-beta.1 || true
sleep 1
check "D: v1 with beta on found 1.2.0-beta.1 (the newest, not 1.1.0)" 'ev event=driver:update-found found=1.2.0-beta.1'
check "D: ... from the beta channel" 'ev event=driver:update-found found=1.2.0-beta.1 channel=beta'
check "D: installed bundle is 1.2.0-beta.1" 'test "$(installed_version)" = 1.2.0-beta.1'
pidb=$(evget pid event=launch version=1.2.0-beta.1)
check "D: relaunched as the beta with a new PID ($pid1 -> $pidb)" 'test -n "$pidb" -a "$pidb" != "$pid1"'
check "D: engine stopped before the swap" 'ev event=prepare-end engineGone=True'
finish D

# ============================ E: v3, beta turned off =====================================================
note ""; note "== E: v3, beta turned off -> no downgrade"
fresh v3 '{"check":true,"beta":false}'
pid3=$launched_pid
wait_ev 40 event=driver:no-update || wait_ev 5 event=driver:update-found || true
sleep 3
check "E: v3 with beta off: Sparkle reports no update" 'ev event=driver:no-update'
check "E: no update was offered (1.1.0 is older than the installed beta)" '! ev event=driver:update-found'
check "E: still 1.2.0-beta.1 in the same process (pid $pid3)" 'test "$(installed_version)" = 1.2.0-beta.1 && alive $pid3'
check "E: the toggle went through setBeta (persist + reset update cycle)" 'ev event=updates-log "message=beta updates off"'
finish E

# ============================ F: tampered / wrong key ====================================================
for kind in tampered otherkey; do
  note ""; note "== F: $kind item"
  cp $S/feed/appcast.xml $S/feed/appcast-main.xml
  cat $S/feed/$kind.item | appcast
  fresh v1 '{"check":true,"beta":false}'
  pid1=$launched_pid; hash_before=$(exec_hash)
  wait_ev 60 event=driver:updater-error || wait_ev 5 event=driver:installing || true
  sleep 3
  errtext=$(evget error event=driver:updater-error | cut -c1-100)
  check "F($kind): the update was offered, then rejected" 'ev event=driver:update-found found=1.1.0 && ev event=driver:updater-error'
  note "      Sparkle said: $errtext"
  check "F($kind): installed app is still 1.0.0, byte for byte" 'test "$(installed_version)" = 1.0.0 -a "$(exec_hash)" = "$hash_before"'
  check "F($kind): installed app still validates" '/usr/bin/codesign --verify --strict --deep $install'
  check "F($kind): app untouched (pid $pid1 alive, no prepare, no relaunch)" 'alive $pid1 && ! ev event=prepare-begin && ! ev event=launch version=1.1.0'
  finish F-$kind
  cp $S/feed/appcast-main.xml $S/feed/appcast.xml
done

# ============================ G: engine will not stop ====================================================
note ""; note "== G: engine can't be stopped"
fresh v1 '{"check":true,"beta":false,"prepare":"fail"}'
pid1=$launched_pid
wait_ev 60 event=problem-reported || true
sleep 6
check "G: the stop hook was asked and failed" 'ev event=prepare-failed'
check "G: the user was told plainly" 'ev event=problem-reported'
check "G: nothing installed (still 1.0.0), app not terminated (pid $pid1 alive)" 'test "$(installed_version)" = 1.0.0 && alive $pid1'
eng=$(evget enginePid event=engine-start)
check "G: the engine was left running (pid $eng)" 'test -n "$eng" && alive $eng'
note "   asking the app to quit the way Quit Microfish would, to see whether the held update installs on that quit ..."
control '{"quitNow":true,"prepare":"ok"}'
sleep 12
if [[ "$(installed_version)" == 1.1.0 ]]; then g_quit="installed on the following quit (now 1.1.0)"; else g_quit="NOT installed on the following quit (still $(installed_version))"; fi
note "   G follow-up: $g_quit"
mkdir -p $evidence; echo "$g_quit" > $evidence/G-followup.txt
finish G

# ============================ H: install on quit =========================================================
note ""; note "== H: automatic download, install on quit"
fresh v1 '{"mode":"background","quitAfterWillInstall":true,"beta":false}'
pid1=$launched_pid
wait_ev 60 event=quit-engine-stopped || true
sleep 12
check "H: Sparkle staged the update and told the app it installs on quit" 'ev event=updates-log "message=1.1.0 will install when Microfish quits"'
check "H: the quit stopped the engine first (terminate-request -> quit-engine-stopped, engineGone)" 'ev event=quit-engine-stopped engineGone=True'
t_stop=$(evget t event=quit-engine-stopped); t_swap=$(watcher_t "bundle-version 1.1.0")
check "H: bundle replaced after the engine was stopped (stop $t_stop < swap $t_swap)" "/usr/bin/python3 -I -c \"import sys; sys.exit(0 if float('${t_stop:-1}') < float('${t_swap:-0}') else 1)\""
check "H: installed bundle is 1.1.0" 'test "$(installed_version)" = 1.1.0'
check "H: process $pid1 exited" '! alive $pid1'
note "   H relaunch after install-on-quit: $(ev event=launch version=1.1.0 && echo relaunched || echo 'not relaunched (the user quit)')"
finish H

# ============================ I: settings controls =======================================================
note ""; note "== I: Settings controls reach Sparkle"
fresh v1cfg '{"mode":"roundtrip"}'
wait_ev 30 event=roundtrip-done || true
check "I: Info.plist SUEnableAutomaticChecks=YES starts automatic checks on" 'ev event=roundtrip-initial autoChecks=True'
check "I: 'Automatically check' off reaches Sparkle and the model" 'ev event=roundtrip-checks-off autoChecks=False modelChecks=False'
check "I: 'check' + 'download and install' on reach Sparkle" 'ev event=roundtrip-all-on autoChecks=True autoDownloads=True modelDownloads=True'
check "I: beta on persists in defaults and selects the beta channel" 'ev event=roundtrip-beta-on beta=True persisted=1 channels=beta'
check "I: beta off returns to no channel" 'ev event=roundtrip-beta-off beta=False channels='
finish I

# ============================ windows ====================================================================
note ""; note "== windows seen during every scenario (read-only watcher)"
winlines=$(cat $evidence/*/watcher.log 2>/dev/null | grep " window " | sed -E 's/^[0-9.]+ //' | sort | uniq -c)
if [[ -z $winlines ]]; then note "  none: no process from the scratch tree or Sparkle's installer created any window"; echo "no windows" > $evidence/windows.txt
else note "$winlines"; echo "$winlines" > $evidence/windows.txt; fi
check "no window from the probe or from Sparkle's installer/Updater was ever on screen" 'test -z "$(cat $evidence/*/watcher.log | grep " window " | grep "ondisplay=true")"'

# ============================ summary ====================================================================
note ""
{ echo "signing: $sign_mode"; echo "Sparkle: $(cat $sparkle/VERSION)"; echo "pass=$pass fail=$fail"; printf '%s\n' "${results[@]}"; } > $evidence/results.txt
note "pass=$pass fail=$fail   (results: $evidence/results.txt)"
[[ $fail -eq 0 ]]
