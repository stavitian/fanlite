// swift-tools-version:5.10
import PackageDescription

// FanLite: un solo binario, sin helper, sin daemon.
//
//   CSMC     capa C: struct SMC de 80 bytes con asserts de layout + cliente AppleSMC.
//            Copiada de FanPilot (MIT, https://github.com/zyvren/FanPilot) tal cual: esa parte
//            ya está probada en hardware y no quería reescribir el protocolo a mano.
//   FanLite  la app entera: lectura de sensores, curva, control y UI de barra de menú.
//
// El modo de lenguaje queda en Swift 5 a propósito: evita el ruido de strict concurrency en
// código que habla con APIs C y GCD.

let ioKitLinking: [LinkerSetting] = [
    .linkedFramework("IOKit"),
    .linkedFramework("CoreFoundation"),
]

let package = Package(
    name: "FanLite",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FanLite", targets: ["FanLite"]),
    ],
    targets: [
        .target(
            name: "CSMC",
            path: "Sources/CSMC",
            publicHeadersPath: "include",
            linkerSettings: ioKitLinking
        ),
        .executableTarget(
            name: "FanLite",
            dependencies: ["CSMC"],
            path: "Sources/FanLite",
            linkerSettings: ioKitLinking
        ),
    ],
    swiftLanguageVersions: [.v5]
)
