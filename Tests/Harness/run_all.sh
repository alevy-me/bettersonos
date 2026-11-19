#!/bin/zsh
# Fake-server tests for BonTon. Builds BetterSonosCore and each test program from the current
# sources into a temporary folder, starts the fake servers, and runs every test with a 90 s
# timeout. A test that fails to build is reported and skipped, never run from a stale binary.
#
# Usage: Tests/Harness/run_all.sh        (from anywhere; macOS with Xcode and python3)

H=${0:A:h}
R=${H:h:h}
W=$(mktemp -d -t bonton-harness)
trap 'kill ${pids[@]} 2>/dev/null; rm -rf $W' EXIT
cd $W

mkdir mod
swiftc -parse-as-library -emit-library -emit-module -module-name BetterSonosCore \
    -emit-module-path mod/BetterSonosCore.swiftmodule $R/Packages/BetterSonosCore/Sources/BetterSonosCore/*.swift \
    -o mod/libBetterSonosCore.dylib -Xlinker -install_name -Xlinker @rpath/libBetterSonosCore.dylib 2>&1 | grep " error: " && { echo "BetterSonosCore failed to build"; exit 1; }
L=(-I mod -L mod -lBetterSonosCore -Xlinker -rpath -Xlinker $W/mod)

# App sources under test, with the bundle-ID loggers made host-safe.
strip() { sed -e 's/Bundle.main.bundleIdentifier ?? "BetterSonosWatch"/"test"/; s/Bundle.main.bundleIdentifier!/"test"/' "$1"; }
strip $R/BetterSonos/SonosViewModel.swift > SonosViewModel.swift
strip $R/BetterSonosWatch/WatchNetworkController.swift > WatchNetworkController.swift
cp $R/BetterSonosWatch/WatchDiagnostics.swift WatchDiagnostics.swift
INTENTS=($R/Shared/Intents/SonosDirectory.swift $R/Shared/Intents/SonosEntities.swift $R/Shared/Intents/SonosIntents.swift)

failed=0
build() { local out=$1; shift
          local err=$(swiftc ${L[@]} "$@" -o $out 2>&1 | grep " error: " | head -3)
          [ -n "$err" ] && { echo "BUILD FAILED $out:\n$err"; failed=1; rm -f $out; } }
build models        $H/models/main.swift
build vm            SonosViewModel.swift $H/stub.swift $H/discovery-stub.swift $H/shim.swift $H/vm/main.swift
build watch         WatchNetworkController.swift WatchDiagnostics.swift $H/stub.swift $H/watch/main.swift
build watch-local   WatchNetworkController.swift WatchDiagnostics.swift $H/stub.swift $H/watch-local/main.swift
build watch-dealloc WatchNetworkController.swift WatchDiagnostics.swift $H/stub.swift $H/watch-dealloc/main.swift
build sole-playing  WatchNetworkController.swift WatchDiagnostics.swift $H/stub.swift $H/sole-playing/main.swift
build presets       WatchNetworkController.swift WatchDiagnostics.swift $H/stub.swift $H/presets/main.swift
build radio-watch   WatchNetworkController.swift WatchDiagnostics.swift $H/stub.swift $H/radio-watch/main.swift
build intents       ${INTENTS[@]} $H/stub.swift $H/intents/main.swift
build intents-local ${INTENTS[@]} $H/stub.swift $H/intents-local/main.swift
build radio-siri    ${INTENTS[@]} $H/stub.swift $H/radio-siri/main.swift
build now-playing   $H/now-playing/main.swift
build direct        $H/direct/main.swift
build direct-commands $H/direct-commands/main.swift
build direct-presets $H/direct-presets/main.swift
build hybrid        $H/hybrid/main.swift
build vm-local      SonosViewModel.swift $H/stub.swift $H/discovery-stub.swift $H/shim.swift $H/vm-local/main.swift
strip $R/BetterSonos/SonosDiscovery.swift > SonosDiscovery.swift
strip $R/BetterSonos/DiscoveryCoordinator.swift > DiscoveryCoordinator.swift
build discovery     SonosDiscovery.swift DiscoveryCoordinator.swift $H/shim.swift $H/discovery/main.swift
build merge         SonosDiscovery.swift DiscoveryCoordinator.swift $H/shim.swift $H/merge/main.swift

pids=()
serve() { python3 -I $H/servers/$1 $2 "${@:3}" >/dev/null 2>&1 & pids+=($!); }
serve basic.py 18801 ok /dev/null
serve grouped.py 18802 /dev/null
serve grouped.py 18803 /dev/null
serve two-groups.py 18804 /dev/null
serve two-groups.py 18805 /dev/null
serve presets.py 18806 /dev/null
serve radio.py 18807 /dev/null
serve two-groups.py 18808 /dev/null
serve two-groups.py 18809 /dev/null
serve radio.py 18810 /dev/null
serve speaker.py 18820 /dev/null       # players on 18820-18827
serve speaker.py 18830 /dev/null       # players on 18830-18837
serve grouped.py 18840 /dev/null
serve speaker.py 18850 /dev/null       # players on 18850-18857
serve speaker.py 18860 /dev/null       # players on 18860-18867
serve speaker.py 18870 /dev/null       # players on 18870-18877
serve speaker.py 18880 /dev/null       # players on 18880-18887
serve two-groups.py 18890 /dev/null
serve hang.py 18899
serve refuse.py 18898 $W/refuse.log
serve speaker.py 18900 /dev/null       # players on 18900-18908
serve grouped.py 18910 /dev/null
serve two-groups.py 18911 /dev/null
serve two-groups.py 18912 /dev/null
sleep 1

run() { local name=$1; shift; echo "== $name"
        [ -x ./$1 ] || { echo "SKIPPED (did not build)"; failed=1; return; }
        local out; out=$(perl -e 'alarm shift; exec @ARGV' 90 ./"$@" 2>/dev/null); local code=$?
        print -r -- "$out" | grep -E "PASS|FAIL|ALL |MATCH|status:|deallocated"
        # A crash loses buffered output, so a missing FAIL line proves nothing: the exit status decides.
        if [ $code -eq 142 ]; then echo "TIMED OUT"; failed=1
        elif [ $code -ne 0 ]; then echo "CRASHED (exit $code)"; failed=1; fi
        print -r -- "$out" | grep -qE "FAIL|MISMATCHED" && failed=1 }
run "model logic"                   models
run "iOS view model"                vm 18801
run "watch controller"              watch 18802
run "watch deallocation"            watch-dealloc 18803
run "only one group playing"        sole-playing 18804 18805
run "watch presets"                 presets 18806
run "stopped radio, watch"          radio-watch 18807
run "Siri intents"                  intents 18808 18809
run "stopped radio, Siri"           radio-siri 18810
run "now playing, captured states"  now-playing $H/fixtures/captured-states.jsonl
run "direct backend"                direct 18820
run "direct commands"               direct-commands 18850
run "direct presets"                direct-presets 18860
run "watch, local network"          watch-local 18870 18899 18898 $W/refuse.log
run "Siri, local network"           intents-local 18880 18890
run "iOS view model, local network" vm-local 18830
run "discovery triggers"            discovery 18840
run "hybrid backend"                hybrid 18900 18910
run "merging server and local"      merge 18911 18912

echo
[ $failed -eq 0 ] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
