import AppKit
import SwiftUI

/// Zed's GitHub Dark Tritanopia (dark) and Ayu Light (light) colors, the
/// same values as data/style/palette-*.css in the Linux app.
struct Palette {
    let bg: Color
    let panel: Color
    let border: Color
    let hover: Color
    let active: Color
    let text: Color
    let muted: Color
    let faint: Color
    let accent: Color
    let blue: Color
    let green: Color
    let red: Color
    let purple: Color
    let amber: Color
    let add: Color
    let del: Color
    let shadow: Color

    static let dark = Palette(
        bg: Color(hex: 0x0d1117),
        panel: Color(hex: 0x010409),
        border: Color(hex: 0x3d444d),
        hover: Color(hex: 0x656c76, opacity: 0.16),
        active: Color(hex: 0x656c76, opacity: 0.28),
        text: Color(hex: 0xf0f6fc),
        muted: Color(hex: 0x9198a1),
        faint: Color(hex: 0x656c76),
        accent: Color(hex: 0x4493f8),
        blue: Color(hex: 0x58a6ff),
        green: Color(hex: 0x3fb950),
        red: Color(hex: 0xf85149),
        purple: Color(hex: 0xbe8fff),
        amber: Color(hex: 0xd29922),
        add: Color(hex: 0x58a6ff),
        del: Color(hex: 0xf85149),
        shadow: Color(hex: 0x010409, opacity: 0.45)
    )

    static let light = Palette(
        bg: Color(hex: 0xfcfcfc),
        panel: Color(hex: 0xf3f4f5),
        border: Color(hex: 0xd8dce0),
        hover: Color(hex: 0x56728f, opacity: 0.08),
        active: Color(hex: 0x56728f, opacity: 0.15),
        text: Color(hex: 0x5c6166),
        muted: Color(hex: 0x8a9199),
        faint: Color(hex: 0xadaeb1),
        accent: Color(hex: 0x399ee6),
        blue: Color(hex: 0x399ee6),
        green: Color(hex: 0x6cbf43),
        red: Color(hex: 0xe65050),
        purple: Color(hex: 0xa37acc),
        amber: Color(hex: 0xe59645),
        add: Color(hex: 0x6cbf43),
        del: Color(hex: 0xe65050),
        shadow: Color(hex: 0x000000, opacity: 0.14)
    )

    static func current(_ scheme: ColorScheme) -> Palette {
        scheme == .dark ? .dark : .light
    }

    /// Zed's `search.match_background`.
    static let searchMatch = Color(hex: 0xf2cc60, opacity: 0.35)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: opacity
        )
    }
}

/// Zed's UI font (IBM Plex Sans) and buffer font (Lilex), bundled in the app.
enum Fonts {
    static func register() {
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        for file in files where file.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        // PostScript names as stored in the bundled files.
        let name = switch weight {
        case .medium: "IBMPlexSans-Medm"
        case .semibold, .bold: "IBMPlexSans-SmBld"
        default: "IBMPlexSans"
        }
        return .custom(name, fixedSize: size)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(weight == .medium ? "Lilex-Medium" : "Lilex-Regular", fixedSize: size)
    }
}

/// Octicons, shipped as PDFs and drawn as template images so they take the
/// surrounding foreground color.
enum Icons {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String) -> NSImage {
        if let cached = cache[name] {
            return cached
        }
        let url = Bundle.main.resourceURL?.appendingPathComponent("Icons/\(name).pdf")
        let image = url.flatMap(NSImage.init(contentsOf:)) ?? NSImage()
        image.isTemplate = true
        cache[name] = image
        return image
    }
}

struct Icon: View {
    let name: String
    var size: CGFloat = 14

    init(_ name: String, size: CGFloat = 14) {
        self.name = name
        self.size = size
    }

    var body: some View {
        Image(nsImage: Icons.image(name))
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}
