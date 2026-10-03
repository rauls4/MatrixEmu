import Foundation

/// Host-side Arduino compile. iOS has no Xtensa toolchain and does not call this.
enum SketchCompiler {
    struct Output {
        /// Real application image, or nil when compile did not run.
        var bin: Data?
        var binName: String
        /// Where the .bin was written on this Mac, when one was produced.
        var binPath: String?
        var message: String
    }

    static let installMessage = """
    No ESP32-S3 .bin was produced.
    Install Arduino CLI and the esp32 core (the core is a large download; MatrixEmu will not install it):

      brew install arduino-cli
      arduino-cli core update-index
      arduino-cli core install esp32:esp32

    On macOS the core lives in ~/Library/Arduino15, not ~/.arduino15.
    idf.py does not compile an Arduino .ino. Prefer arduino-cli, board esp32:esp32:esp32s3.
    The same steps are in firmware/compile_ino.sh.
    """

    /// True only on macOS, where Process can run a host compiler.
    static var compilesOnThisDevice: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    static func compile(sketch: Data, suggestedName: String) -> Output {
        #if os(macOS)
        return compileMac(sketch: sketch, suggestedName: suggestedName)
        #else
        return Output(
            bin: nil,
            binName: "",
            binPath: nil,
            message: "This iPhone cannot compile Xtensa. Share the .ino and run firmware/compile_ino.sh on a Mac."
        )
        #endif
    }

    #if os(macOS)
    private static func compileMac(sketch: Data, suggestedName: String) -> Output {
        let fileStem = safeStem(suggestedName)
        let fileName = fileStem + ".ino"
        guard String(data: sketch, encoding: .utf8) != nil else {
            return Output(bin: nil, binName: fileName, binPath: nil, message: "Sketch is not UTF-8 text. No .bin was produced.")
        }

        let cli = locate("arduino-cli")
        let idf = locate("idf.py")
        guard let cli else {
            var msg = installMessage
            if let idf {
                msg = "Found idf.py at \(idf), but ESP-IDF does not compile an Arduino .ino into a firmware image by itself.\n" + installMessage
            }
            return Output(bin: nil, binName: fileName, binPath: nil, message: msg)
        }

        let core = run(executable: cli, arguments: ["core", "list"])
        let hasCore = core.combined.split(whereSeparator: \.isNewline).contains { line in
            line.split(whereSeparator: \.isWhitespace).first == "esp32:esp32"
        }
        if !hasCore {
            let detail = core.combined.trimmingCharacters(in: .whitespacesAndNewlines)
            var msg = "arduino-cli is at \(cli) but core esp32:esp32 is not installed.\n" + installMessage
            if !detail.isEmpty {
                msg += "\n\ncore list:\n" + detail
            }
            return Output(bin: nil, binName: fileName, binPath: nil, message: msg)
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("MatrixEmuCompile", isDirectory: true)
            .appendingPathComponent(fileStem, isDirectory: true)
        let sketchDir = root.appendingPathComponent(fileStem, isDirectory: true)
        let buildDir = root.appendingPathComponent("build", isDirectory: true)
        do {
            if fm.fileExists(atPath: root.path) {
                try fm.removeItem(at: root)
            }
            try fm.createDirectory(at: sketchDir, withIntermediateDirectories: true)
            try sketch.write(to: sketchDir.appendingPathComponent(fileName), options: .atomic)
            try fm.createDirectory(at: buildDir, withIntermediateDirectories: true)
        } catch {
            return Output(bin: nil, binName: fileName, binPath: nil, message: "Could not stage the sketch: \(error.localizedDescription)")
        }

        let fqbn = "esp32:esp32:esp32s3"
        let compile = run(
            executable: cli,
            arguments: ["compile", "-b", fqbn, "--output-dir", buildDir.path, sketchDir.path]
        )
        let appURL = buildDir.appendingPathComponent("\(fileStem).ino.bin")
        guard compile.status == 0, let data = try? Data(contentsOf: appURL), !data.isEmpty else {
            let tail = compile.combined.suffix(4000)
            return Output(
                bin: nil,
                binName: fileName,
                binPath: nil,
                message: "arduino-cli failed (exit \(compile.status)). No .bin was produced.\n\(tail)"
            )
        }
        guard data.first == 0xE9 else {
            return Output(
                bin: nil,
                binName: fileName,
                binPath: nil,
                message: "arduino-cli wrote \(appURL.path) but it does not start with ESP magic 0xE9. It was not loaded."
            )
        }

        let kept = fm.temporaryDirectory.appendingPathComponent("\(fileStem).bin")
        do {
            if fm.fileExists(atPath: kept.path) {
                try fm.removeItem(at: kept)
            }
            try data.write(to: kept, options: .atomic)
        } catch {
            return Output(
                bin: data,
                binName: "\(fileStem).bin",
                binPath: appURL.path,
                message: "Compiled \(data.count) bytes but could not copy the .bin out of the build folder: \(error.localizedDescription)"
            )
        }

        return Output(
            bin: data,
            binName: "\(fileStem).bin",
            binPath: kept.path,
            message: "Compiled \(kept.path) (\(data.count) bytes) with \(cli) -b \(fqbn). This is a real ESP32-S3 application image, not a MatrixEmu animation."
        )
    }

    private static func safeStem(_ suggestedName: String) -> String {
        var stem = (suggestedName as NSString).deletingPathExtension
        if stem.isEmpty { stem = "Sketch" }
        let cleaned = stem.unicodeScalars.filter { ch in
            CharacterSet.alphanumerics.contains(ch) || ch == "_" || ch == "-"
        }
        let safe = String(String.UnicodeScalarView(cleaned))
        return safe.isEmpty ? "Sketch" : safe
    }

    private static func locate(_ name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let which = run(executable: "/bin/zsh", arguments: ["-lc", "command -v \(name)"])
        let path = which.combined.trimmingCharacters(in: .whitespacesAndNewlines)
        if which.status == 0, path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private struct RunResult {
        var status: Int32
        var combined: String
    }

    private static func run(executable: String, arguments: [String]) -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        let prefix = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let path = env["PATH"], !path.isEmpty {
            env["PATH"] = prefix + ":" + path
        } else {
            env["PATH"] = prefix
        }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return RunResult(status: 127, combined: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return RunResult(status: process.terminationStatus, combined: text)
    }
    #endif
}
