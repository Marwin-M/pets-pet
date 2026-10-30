// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PetsPet",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "PetsPet", targets: ["PetsPet"])],
    targets: [
        .target(name: "PetsPetCore"),
        .target(name: "PetsPetSidebar", resources: [.copy("Sidebar.js")], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "PetsPet", dependencies: ["PetsPetCore", "PetsPetSidebar"], resources: [.copy("DefaultStartup.html"), .copy("DefaultStartupDark.html"), .copy("StartupSacredLight.wav"), .copy("StartupSacredDark.wav")]),
        .executableTarget(name: "PetsPetChecks", dependencies: ["PetsPetCore"], path: "Tests/PetsPetCoreTests"),
        .executableTarget(name: "PetsPetSidebarChecks", dependencies: ["PetsPetSidebar"], path: "Tests/PetsPetSidebarTests", exclude: ["fixture.py"])
    ],
    swiftLanguageModes: [.v5]
)
