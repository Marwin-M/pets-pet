#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release --target PetsPetCore --disable-sandbox --scratch-path .build --cache-path .build/package-cache --config-path .build/config --security-path .build/security
preview_binary_dir=$(swift build -c release --show-bin-path --scratch-path .build)
preview_objects=("$preview_binary_dir"/PetsPetCore.build/*.swift.o)
swiftc -parse-as-library -target "$(uname -m)-apple-macosx13.0" -module-cache-path .build/preview-module-cache \
  -I "$preview_binary_dir/Modules" Sources/PetsPet/Overlay.swift Sources/PetsPet/PetMonitor.swift Sources/PetsPet/SidebarQuotaRenderer.swift Tools/Preview.swift \
  "${preview_objects[@]}" -o .build/preview-renderer
.build/preview-renderer "$@"
cp Resources/Artwork/AppIcon.png Previews/Assets/app-icon.png
cp Resources/Artwork/MenuBarIcon.png Previews/Assets/menu-icon.png
cp Resources/Artwork/icon-reference.png Previews/Assets/icon-reference.png
