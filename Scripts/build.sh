#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release --product PetsPet --disable-sandbox --scratch-path .build --cache-path .build/package-cache --config-path .build/config --security-path .build/security
binary_dir=$(swift build -c release --show-bin-path --scratch-path .build)
app="${PETSPET_BUILD_DEST:-$PWD/dist/PetsPet.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/PetsPet" "$app/Contents/MacOS/PetsPet"
cp Resources/Info.plist "$app/Contents/Info.plist"
zsh Scripts/icons.sh
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarIcon.png "$app/Contents/Resources/MenuBarIcon.png"
cp Sources/PetsPetSidebar/Sidebar.js "$app/Contents/Resources/"
cp Sources/PetsPet/DefaultStartup.html "$app/Contents/Resources/"
codesign --force --sign - --identifier com.marwin.petspet "$app"
codesign --verify --strict "$app"
print "Built: $app"
