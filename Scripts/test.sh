#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-module-cache"
swift run --disable-sandbox --scratch-path .build --cache-path .build/package-cache --config-path .build/config --security-path .build/security PetsPetChecks
swift run --disable-sandbox --scratch-path .build --cache-path .build/package-cache --config-path .build/config --security-path .build/security PetsPetSidebarChecks
check_binary_dir=$(swift build --show-bin-path --scratch-path .build)
sidebar_check_objects=("$check_binary_dir"/PetsPetSidebar.build/*.swift.o)
swiftc -parse-as-library -swift-version 5 -module-cache-path .build/check-module-cache \
  -I "$check_binary_dir/Modules" Sources/PetsPet/SidebarController.swift Tests/PetsPetSidebarLifecycleTests/Checks.swift \
  "${sidebar_check_objects[@]}" -lsqlite3 -o "$check_binary_dir/PetsPetSidebarLifecycleChecks"
"$check_binary_dir/PetsPetSidebarLifecycleChecks"
core_check_objects=("$check_binary_dir"/PetsPetCore.build/*.swift.o)
swiftc -parse-as-library -swift-version 5 -module-cache-path .build/check-module-cache \
  -I "$check_binary_dir/Modules" Sources/PetsPet/UpdateChecker.swift Tests/PetsPetUpdateTests/Checks.swift \
  "${core_check_objects[@]}" -o "$check_binary_dir/PetsPetUpdateChecks"
"$check_binary_dir/PetsPetUpdateChecks"
swiftc -parse-as-library -swift-version 5 -module-cache-path .build/check-module-cache \
  -I "$check_binary_dir/Modules" Sources/PetsPet/Overlay.swift Sources/PetsPet/PetMonitor.swift \
  Sources/PetsPet/SidebarQuotaRenderer.swift Tests/PetsPetSidebarLifecycleTests/QuotaRendererChecks.swift \
  "${core_check_objects[@]}" -o "$check_binary_dir/PetsPetSidebarQuotaChecks"
"$check_binary_dir/PetsPetSidebarQuotaChecks" "$@"
swiftc -parse-as-library -swift-version 5 -module-cache-path .build/check-module-cache \
  -I "$check_binary_dir/Modules" Sources/PetsPet/CodexStartupController.swift Sources/PetsPet/CodexClientLifecycle.swift Sources/PetsPet/StartupMediaStore.swift Sources/PetsPet/StartupAnimation.swift Sources/PetsPet/StartupSoundtrack.swift Sources/PetsPet/StartupHTMLPlayer.swift \
  Tests/PetsPetStartupTests/Checks.swift "${core_check_objects[@]}" -o "$check_binary_dir/PetsPetStartupChecks"
"$check_binary_dir/PetsPetStartupChecks"
swiftc -parse-as-library -swift-version 5 -module-cache-path .build/check-module-cache \
  -I "$check_binary_dir/Modules" Sources/PetsPet/StartupHTMLPlayer.swift Sources/PetsPet/StartupMediaStore.swift Sources/PetsPet/StartupAnimation.swift Sources/PetsPet/StartupSoundtrack.swift \
  Sources/PetsPet/CodexStartupController.swift Tests/PetsPetStartupTests/HTMLChecks.swift "${core_check_objects[@]}" \
  -o "$check_binary_dir/PetsPetHTMLChecks"
"$check_binary_dir/PetsPetHTMLChecks" "$@"
swiftc -parse-as-library -swift-version 5 -module-cache-path .build/check-module-cache \
  Sources/PetsPet/ApplicationTerminationController.swift Sources/PetsPet/CodexClientLifecycle.swift Tests/PetsPetStartupTests/TerminationChecks.swift \
  -o "$check_binary_dir/PetsPetTerminationChecks"
python3 - "$check_binary_dir/PetsPetTerminationChecks" <<'PY'
import subprocess, sys, time
for arguments in [[], ['--stalled'], ['--client-exit'], ['--client-exit-disabled']]:
    started = time.monotonic()
    result = subprocess.run([sys.argv[1]] + arguments, timeout=3, check=True, capture_output=True, text=True)
    assert result.stdout.count('termination requested') == 1, 'duplicate requests must not re-enter native termination'
    assert result.stdout.count('termination finished') == 1, 'the real AppKit process must reach its termination callback'
    assert ('cleanup completed' in result.stdout) == ('--stalled' not in arguments), 'normal cleanup must run; stalled cleanup must hit the deadline'
    assert ('disabled follow-exit retained process' in result.stdout) == ('--client-exit-disabled' in arguments), 'disabled follow-exit must retain the app until a manual quit'
    assert time.monotonic() - started < 2, 'native deferred termination must complete promptly'
print('Termination checks passed: normal/stalled cleanup and enabled/disabled follow-exit through real native AppKit processes; no real client changes.')
PY
