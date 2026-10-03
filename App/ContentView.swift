import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

struct ContentView: View {
    @StateObject private var model = EmulatorModel()
    private enum ImportKind {
        case bin, gif, sketch
    }

    @State private var importing = false
    @State private var importKind: ImportKind = .bin
    @State private var shareItems: [Any] = []
    @State private var showingShare = false
    @State private var sketchNote: String?
    @State private var compiling = false

    // Text composer
    @State private var message = "HELLO"
    @State private var defaultColor = TextFirmware.RGB.white
    @State private var letterColors: [TextFirmware.RGB] = Array(repeating: .white, count: 64)
    @State private var textEffect: TextFirmware.Effect = .scroll
    @State private var selectedLetter = 0

    // Flip-book editor
    @State private var bookFrames: [[UInt8]] = [
        [UInt8](repeating: 0, count: 64 * 32 * 3)
    ]
    @State private var bookIndex = 0
    @State private var paintColor = TextFirmware.RGB.red
    @State private var frameDelayMs = 100
    @State private var showEditor = false

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.05).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    LEDPanelView(
                        rgb: model.frame,
                        width: model.controller.width,
                        height: model.controller.height,
                        rotation: model.rotation
                    )
                        .aspectRatio(panelAspect, contentMode: .fit)
                        .padding(.horizontal, 8)
                    status
                    controllerPicker
                    controls
                    samplesSection
                    compileSketch
                    textComposer
                    flipBookSection
                    if let errorText = model.errorText {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 16)
                    }
                    pinout
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { model.start() }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: importContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        #if os(iOS)
        .sheet(isPresented: $showingShare) {
            ActivityView(items: shareItems)
        }
        #endif
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 760)
        #endif
    }

    private var shareCaption: String {
        "MatrixEmu animation image (animation.bin) for the firmware/player sketch on the Waveshare ESP32-S3-RGB-Matrix. Not a stock ESP-IDF application — only the MatrixEmu player runs this bytecode."
    }

    private var importContentTypes: [UTType] {
        switch importKind {
        case .gif:
            return [.gif, .image]
        case .bin:
            return [.data, .item]
        case .sketch:
            var types: [UTType] = [.sourceCode, .plainText, .text]
            if let ino = UTType(filenameExtension: "ino") {
                types.insert(ino, at: 0)
            }
            return types
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let name = url.lastPathComponent
                switch importKind {
                case .gif:
                    model.loadGIF(data: data, name: name)
                case .bin:
                    model.load(data: data, name: name)
                case .sketch:
                    #if os(macOS)
                    compileSketchOnMac(data: data, name: name)
                    #else
                    try storeSketch(data: data, suggestedName: name)
                    #endif
                }
            } catch {
                model.errorText = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        case .failure(let error):
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError {
                return
            }
            model.errorText = error.localizedDescription
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Matrix")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            Text(model.controller.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color(white: 0.82))
            Text(model.controller.subtitle)
                .font(.caption)
                .foregroundStyle(Color(white: 0.55))
        }
        .padding(.horizontal, 16)
    }

    private var status: some View {
        HStack {
            Text(model.firmwareName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(statusLine)
        }
        .font(.caption.monospaced())
        .foregroundStyle(Color(white: 0.72))
        .padding(.horizontal, 16)
    }

    private var panelAspect: CGFloat {
        let w = CGFloat(max(model.controller.width, 1))
        let h = CGFloat(max(model.controller.height, 1))
        switch model.rotation {
        case .deg90, .deg270:
            return h / w
        case .deg0, .deg180:
            return w / h
        }
    }

    private var statusLine: String {
        let clock = String(format: "%.0f ms", model.virtualMs)
        return model.controller.status(
            clock: clock,
            running: model.running,
            speed: model.speed,
            addr: model.scanAddr,
            oeBlanked: model.oeBlanked,
            halted: model.halted
        )
    }

    private var controllerPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Controller")
                .font(.headline)
                .foregroundStyle(.white)
            Picker("Controller", selection: Binding(
                get: { model.controller },
                set: { next in
                    model.applyController(next)
                    let n = next.width * next.height * 3
                    bookFrames = [[UInt8](repeating: 0, count: n)]
                    bookIndex = 0
                }
            )) {
                ForEach(MatrixController.allCases) { item in
                    Text("\(item.title) \(item.width)×\(item.height)").tag(item)
                }
            }
            .pickerStyle(.menu)
            .tint(.white)
            Text("GIF, text, and flip-book use this size. Samples are 64×32 and clip on a smaller panel. Not every LED controller.")
                .font(.caption2)
                .foregroundStyle(Color(white: 0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
    }

    private var samplesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Samples")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Tap to load and play. Share animation exports the sample that is loaded. Samples are 64×32 MatrixEmu animation images.")
                .font(.caption2)
                .foregroundStyle(Color(white: 0.5))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(SampleLibrary.all) { sample in
                Button {
                    model.loadSample(sample)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sample.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text(sample.detail)
                            .font(.caption2)
                            .foregroundStyle(Color(white: 0.62))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(white: 0.12))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(model.running ? "Pause" : "Play") {
                    model.toggleRun()
                }
                .buttonStyle(.borderedProminent)
                .tint(model.running ? Color(white: 0.25) : Color(red: 0.2, green: 0.75, blue: 0.45))

                Button("Reset") { model.reset() }
                    .buttonStyle(.bordered)
                    .tint(.white)

                Picker("Speed", selection: $model.speed) {
                    Text("1×").tag(1)
                    Text("4×").tag(4)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 120)
            }
            HStack(spacing: 10) {
                Button(model.muted ? "Unmute" : "Mute") {
                    model.setMuted(!model.muted)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                Picker("Rotation", selection: $model.rotation) {
                ForEach(PanelRotation.allCases) { turn in
                    Text(turn.label).tag(turn)
                }
            }
            .pickerStyle(.segmented)
            }
            Text("Rotation changes how the panel is drawn. The framebuffer stays \(model.controller.width)×\(model.controller.height).")
                .font(.caption2)
                .foregroundStyle(Color(white: 0.5))
            HStack(spacing: 10) {
                Button("Load .bin") { importKind = .bin; importing = true }
                    .buttonStyle(.bordered)
                    .tint(.white)
                Button("Import GIF") { importKind = .gif; importing = true }
                    .buttonStyle(.bordered)
                    .tint(.white)
                Button("Share animation") { shareAnimation() }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
            Text("Share exports animation.bin for the MatrixEmu player on the board — not a flashable ESP-IDF app by itself.")
                .font(.caption2)
                .foregroundStyle(Color(white: 0.5))
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 16)
    }

    private var compileSketch: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compile sketch")
                .font(.headline)
                .foregroundStyle(.white)
            Text(compileBlurb)
                .font(.caption2)
                .foregroundStyle(Color(white: 0.5))
                .fixedSize(horizontal: false, vertical: true)
            Button(compiling ? "Compiling…" : "Compile sketch") {
                importKind = .sketch
                importing = true
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .disabled(compiling)
            if let sketchNote {
                Text(sketchNote)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Color(white: 0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 16)
    }

    private var compileBlurb: String {
        #if os(macOS)
        return "Runs on this Mac. Picks an .ino and compiles it with arduino-cli (or reports that idf.py cannot compile a sketch). Board esp32:esp32:esp32s3. If the tool or the esp32 core is missing, no .bin is invented — the install steps are shown. A real ESP32-S3 image is loaded afterward; this emulator only executes bytecode at 0x3FC00000, so a normal Arduino binary will not light the panel."
        #else
        return "Saves an Arduino .ino and opens the share sheet. This iPhone does not compile Xtensa or run ESP-IDF. On a Mac, firmware/compile_ino.sh uses arduino-cli and board esp32:esp32:esp32s3. That .bin is flashable firmware, not an animation this emulator runs."
        #endif
    }

    private var textComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Text on matrix")
                .font(.headline)
                .foregroundStyle(.white)
            TextField("Message", text: $message)
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                #endif
                .disableAutocorrection(true)
                .padding(8)
                .background(Color(white: 0.12))
                .cornerRadius(8)
                .foregroundStyle(.white)
                .onChange(of: message) { _, newValue in
                    if newValue.count > letterColors.count {
                        letterColors.append(
                            contentsOf: Array(
                                repeating: defaultColor,
                                count: newValue.count - letterColors.count
                            )
                        )
                    }
                    if selectedLetter >= newValue.count {
                        selectedLetter = max(0, newValue.count - 1)
                    }
                }

            Text("Default color")
                .font(.caption)
                .foregroundStyle(Color(white: 0.55))
            colorRow(selected: defaultColor) { c in
                defaultColor = c
            }

            if !message.isEmpty {
                Text("Letter color (tap a character, then a swatch)")
                    .font(.caption)
                    .foregroundStyle(Color(white: 0.55))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(message.enumerated()), id: \.offset) { i, ch in
                            let col = i < letterColors.count ? letterColors[i] : defaultColor
                            Text(String(ch))
                                .font(.system(.body, design: .monospaced).weight(.bold))
                                .foregroundStyle(Color(
                                    red: Double(col.r) / 255,
                                    green: Double(col.g) / 255,
                                    blue: Double(col.b) / 255
                                ))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(selectedLetter == i ? Color.white : Color.clear, lineWidth: 1)
                                )
                                .onTapGesture { selectedLetter = i }
                        }
                    }
                }
                colorRow(selected: selectedLetter < letterColors.count
                         ? letterColors[selectedLetter]
                         : defaultColor) { c in
                    while letterColors.count <= selectedLetter {
                        letterColors.append(defaultColor)
                    }
                    letterColors[selectedLetter] = c
                }
            }

            Picker("Effect", selection: $textEffect) {
                ForEach(TextFirmware.Effect.allCases) { e in
                    Text(e.rawValue).tag(e)
                }
            }
            .pickerStyle(.segmented)

            Button("Show") {
                // Fill missing letter colors with default.
                var cols = letterColors
                while cols.count < message.count {
                    cols.append(defaultColor)
                }
                model.loadText(
                    text: message,
                    colors: cols,
                    defaultColor: defaultColor,
                    effect: textEffect
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.25, green: 0.55, blue: 1))
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private func colorRow(selected: TextFirmware.RGB, onPick: @escaping (TextFirmware.RGB) -> Void) -> some View {
        HStack(spacing: 8) {
            ForEach(TextFirmware.RGB.palette, id: \.name) { item in
                Circle()
                    .fill(Color(
                        red: Double(item.color.r) / 255,
                        green: Double(item.color.g) / 255,
                        blue: Double(item.color.b) / 255
                    ))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Circle().stroke(
                            selected == item.color ? Color.white : Color(white: 0.25),
                            lineWidth: selected == item.color ? 2 : 1
                        )
                    )
                    .onTapGesture { onPick(item.color) }
            }
        }
    }

    private var flipBookSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Flip-book")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Button(showEditor ? "Hide editor" : "Edit frames") {
                    showEditor.toggle()
                }
                .font(.subheadline.weight(.medium))
            }

            if showEditor {
                Text("Paint on the \(model.controller.width)×\(model.controller.height) grid. Play builds an animation.bin. The Waveshare player is still 64×32.")
                    .font(.caption2)
                    .foregroundStyle(Color(white: 0.5))

                FlipBookCanvas(
                    pixels: bindingCurrentFrame(),
                    width: model.controller.width,
                    height: model.controller.height,
                    paint: paintColor
                )
                .aspectRatio(2, contentMode: .fit)
                .background(Color.black)
                .cornerRadius(6)

                colorRow(selected: paintColor) { paintColor = $0 }

                HStack(spacing: 8) {
                    Button("Prev") {
                        bookIndex = max(0, bookIndex - 1)
                    }
                    .disabled(bookIndex == 0)
                    Text("Frame \(bookIndex + 1)/\(bookFrames.count)")
                        .font(.caption.monospaced())
                        .foregroundStyle(Color(white: 0.7))
                    Button("Next") {
                        bookIndex = min(bookFrames.count - 1, bookIndex + 1)
                    }
                    .disabled(bookIndex >= bookFrames.count - 1)
                    Button("Add") {
                        bookFrames.append([UInt8](repeating: 0, count: model.controller.width * model.controller.height * 3))
                        bookIndex = bookFrames.count - 1
                    }
                    Button("Delete") {
                        guard bookFrames.count > 1 else { return }
                        bookFrames.remove(at: bookIndex)
                        bookIndex = min(bookIndex, bookFrames.count - 1)
                    }
                    Button("Clear") {
                        bookFrames[bookIndex] = [UInt8](repeating: 0, count: model.controller.width * model.controller.height * 3)
                    }
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .font(.caption.weight(.medium))

                HStack {
                    Text("Delay \(frameDelayMs) ms")
                        .font(.caption)
                        .foregroundStyle(Color(white: 0.6))
                    Slider(
                        value: Binding(
                            get: { Double(frameDelayMs) },
                            set: { frameDelayMs = Int($0) }
                        ),
                        in: 20...500,
                        step: 10
                    )
                }

                Button("Play flip-book") {
                    playFlipBook()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.85, green: 0.45, blue: 0.15))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private func bindingCurrentFrame() -> Binding<[UInt8]> {
        Binding(
            get: {
                if bookIndex < bookFrames.count { return bookFrames[bookIndex] }
                return [UInt8](repeating: 0, count: model.controller.width * model.controller.height * 3)
            },
            set: { newValue in
                if bookIndex < bookFrames.count {
                    bookFrames[bookIndex] = newValue
                }
            }
        )
    }

    private func playFlipBook() {
        let data = FlipBookFirmware.convert(frames: bookFrames, delayMs: frameDelayMs, width: model.controller.width, height: model.controller.height)
        model.load(data: data, name: "flipbook.bin")
    }

    private func shareAnimation() {
        do {
            let url = try model.exportAnimationURL()
            shareItems = [url, shareCaption]
            presentShare()
        } catch {
            model.errorText = (error as? FirmwareError)?.message ?? error.localizedDescription
        }
    }

    /// Store a sketch and share the source. Does not compile.
    private func storeSketch(data: Data, suggestedName: String) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw SketchStoreError("Sketch is not UTF-8 text. This iPhone does not compile binaries.")
        }
        var stem = (suggestedName as NSString).deletingPathExtension
        if stem.isEmpty || stem == suggestedName && !suggestedName.lowercased().hasSuffix(".ino") {
            // deletingPathExtension on a name with no dot returns the name; keep it.
        }
        if stem.isEmpty { stem = "Sketch" }
        // Drop path-like characters from a picker name.
        let cleaned = stem.unicodeScalars.filter { ch in
            CharacterSet.alphanumerics.contains(ch) || ch == "_" || ch == "-" || ch == "."
        }
        let safe = String(String.UnicodeScalarView(cleaned))
        let fileStem = safe.isEmpty ? "Sketch" : safe
        let fileName = fileStem + ".ino"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatrixEmuSketch", isDirectory: true)
            .appendingPathComponent(fileStem, isDirectory: true)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent(fileName)
        try data.write(to: fileURL, options: .atomic)

        let looks = text.contains("void setup") && text.contains("void loop")
        let extra = looks
            ? ""
            : " No void setup/void loop in this file; arduino-cli will fail until it is a sketch."
        sketchNote = "Saved \(fileName) (\(data.count) bytes) and opened the share sheet. This iPhone cannot compile it. On a Mac, from the MatrixEmu repo: firmware/compile_ino.sh \(fileName) \(fileStem).bin\(extra)"
        shareItems = [
            fileURL,
            "Arduino sketch \(fileName) from MatrixEmu. Not compiled on the phone. On a Mac with arduino-cli and core esp32:esp32: firmware/compile_ino.sh \(fileName) \(fileStem).bin"
        ]
        presentShare()
    }

    #if os(macOS)
    private func compileSketchOnMac(data: Data, name: String) {
        compiling = true
        sketchNote = "Compiling \(name) with arduino-cli on this Mac. This can take a few minutes. No .bin is written until the compiler succeeds."
        model.errorText = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let output = SketchCompiler.compile(sketch: data, suggestedName: name)
            DispatchQueue.main.async {
                compiling = false
                if let bin = output.bin {
                    model.load(data: bin, name: output.binName)
                    if let err = model.errorText {
                        sketchNote = output.message + "\nThe emulator did not run it: " + err
                    } else {
                        sketchNote = output.message + "\nLoaded into the emulator."
                    }
                } else {
                    sketchNote = output.message
                    model.errorText = "Compile sketch did not produce a .bin."
                }
            }
        }
    }
    #endif

    private func presentShare() {
        #if os(iOS)
        showingShare = true
        #elseif os(macOS)
        let picker = NSSharingServicePicker(items: shareItems)
        guard let view = NSApp.keyWindow?.contentView else {
            model.errorText = "Could not open the share sheet."
            return
        }
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        #endif
    }

    private var pinout: some View {
        Text(model.controller.pinNote)
            .font(.caption2.monospaced())
            .foregroundStyle(Color(white: 0.45))
            .padding(.horizontal, 16)
            .padding(.top, 4)
    }
}

private struct SketchStoreError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

#if os(iOS)
/// UIKit share sheet wrapper. Not used on macOS.
struct ActivityView: UIViewControllerRepresentable {
    var items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

/// Simple 64×32 paint canvas for the flip-book.
struct FlipBookCanvas: View {
    @Binding var pixels: [UInt8]
    var width: Int
    var height: Int
    var paint: TextFirmware.RGB

    var body: some View {
        GeometryReader { geo in
            let cols = max(width, 1)
            let rows = max(height, 1)
            let cw = geo.size.width / CGFloat(cols)
            let ch = geo.size.height / CGFloat(rows)
            Canvas { ctx, _ in
                for y in 0..<rows {
                    for x in 0..<cols {
                        let i = (y * cols + x) * 3
                        let r = Double(pixels[i]) / 255
                        let g = Double(pixels[i + 1]) / 255
                        let b = Double(pixels[i + 2]) / 255
                        let lit = pixels[i] > 0 || pixels[i + 1] > 0 || pixels[i + 2] > 0
                        let rect = CGRect(x: CGFloat(x) * cw, y: CGFloat(y) * ch, width: cw, height: ch)
                        ctx.fill(
                            Path(rect),
                            with: .color(lit ? Color(red: r, green: g, blue: b) : Color(white: 0.08))
                        )
                    }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let x = Int(value.location.x / cw)
                        let y = Int(value.location.y / ch)
                        guard x >= 0, x < cols, y >= 0, y < rows else { return }
                        let i = (y * cols + x) * 3
                        var p = pixels
                        p[i] = paint.r
                        p[i + 1] = paint.g
                        p[i + 2] = paint.b
                        pixels = p
                    }
            )
        }
    }
}
