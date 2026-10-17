#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
cp Sources/PetsPetSidebar/Sidebar.js Previews/Assets/sidebar.js
print "Sidebar preview ready: Previews/sidebar.html (review fixtures only)."
