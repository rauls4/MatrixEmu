import Foundation

/// Bundled MatrixEmu animation images (ESP segment at 0x3FC00000).
/// Authored for a 64×32 panel. Smaller controllers clip them.
struct SampleAnimation: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String
    var resource: String { id }
}

enum SampleLibrary {
    static let all: [SampleAnimation] = [
        SampleAnimation(
            id: "rainbow-sweep",
            name: "Rainbow sweep",
            detail: "A 4-pixel bar walks left to right through red, orange, yellow, green, cyan, blue, and purple."
        ),
        SampleAnimation(
            id: "bouncing-dot",
            name: "Bouncing dot",
            detail: "A 2×2 white dot bounces inside the 64×32 panel."
        ),
        SampleAnimation(
            id: "scrolling-hello",
            name: "Scrolling HELLO",
            detail: "Cyan HELLO marquee. Drawn for 64×32."
        ),
        SampleAnimation(
            id: "sparkle",
            name: "Sparkle",
            detail: "A short burst of colored dots, then the loop starts over."
        ),
        SampleAnimation(
            id: "checker-fade",
            name: "Checker fade",
            detail: "8×8 cells swap bright and dim red and blue."
        ),
        SampleAnimation(
            id: "dancing-bears",
            name: "Dancing Bears",
            detail: "Six Grateful Dead bears in red, orange, yellow, green, blue, and purple. Two-step loop."
        ),
        SampleAnimation(
            id: "nyan-cat",
            name: "Nyan Cat",
            detail: "Pop-tart body, gray cat head, and a rainbow trail that scrolls. \"Raul needs to sleep!\" marches across the top. 24 frames."
        ),
    ]
}
