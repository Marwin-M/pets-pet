#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
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
  -I "$check_binary_dir/Modules" Sources/PetsPet/Overlay.swift Sources/PetsPet/PetMonitor.swift \
  Sources/PetsPet/SidebarQuotaRenderer.swift Tests/PetsPetSidebarLifecycleTests/QuotaRendererChecks.swift \
  "${core_check_objects[@]}" -o "$check_binary_dir/PetsPetSidebarQuotaChecks"
"$check_binary_dir/PetsPetSidebarQuotaChecks" "$@"
