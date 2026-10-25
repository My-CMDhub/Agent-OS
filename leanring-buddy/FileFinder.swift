//
//  FileFinder.swift
//  leanring-buddy
//
//  `find_file`: a LOCAL Spotlight lookup by name (owner's ruling 2026-10-12).
//  G09 ("how many files and folders are directly inside the scripts folder of
//  the Heyclicky repo?") failed because Finder's own search matches file
//  CONTENTS and never showed the folder; with its path, `go_to_folder` reaches it.
//
//  PRIVACY: the paths found LEAVE THE MAC to the model, by that ruling — names
//  only, at most 20, never under a Library, system or hidden folder. `isAllowed`
//  is the boundary. Nothing here opens, reads, stats or resolves a found path
//  (no FileManager on results: a file under ~/Desktop or ~/Documents raises a
//  TCC prompt). The kind is mdfind's own `kMDItemContentType`, else the path's
//  shape. Measured 2026-10-12: `mdfind -0 -name X -attr kMDItemContentType` ends
//  each record with NUL and appends "   kMDItemContentType = <type>" (`-attr` is
//  not in man mdfind; the format was read off its output); stderr carries a
//  locale log line and is discarded.
//

import Foundation
import UniformTypeIdentifiers

nonisolated enum FileFinder {
    static let maximumPaths = 20
    static let timeoutSeconds: TimeInterval = 3
    /// ponytail: a one-letter name can match 100k+ files; past this the rest is
    /// dropped, ranked from what was read. Raise it if a real query is cut short.
    static let maximumOutputBytes = 2 << 20
    static let attributeSeparator = "   kMDItemContentType = "

    struct Found: Equatable {
        let path: String
        let kind: String
    }

    struct RunOutput {
        var data: Data
        var timedOut = false
        var launchFailed = false
    }

    // MARK: Pure

    /// A NAME, never a path: 1-100 characters, no control character, no "/",
    /// nothing shaped like a secret (`HarnessHelpSearch.queryProblem`).
    static func queryProblem(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "empty" }
        if name.contains("/") { return "a path, not a name" }
        return HarnessHelpSearch.queryProblem(name)
    }

    static func parse(_ output: Data) -> [Found] {
        String(decoding: output, as: UTF8.self).split(separator: "\0").compactMap { record in
            let record = String(record)
            guard let separator = record.range(of: attributeSeparator, options: .backwards) else {
                return record.isEmpty ? nil : Found(path: record, kind: kind(contentType: nil, path: record))
            }
            let path = String(record[..<separator.lowerBound])
            return Found(path: path, kind: kind(contentType: String(record[separator.upperBound...]), path: path))
        }
    }

    static func kind(contentType: String?, path: String) -> String {
        if let contentType, contentType != "(null)", let type = UTType(contentType) {
            if type.conforms(to: .application) { return "app" }
            if type.conforms(to: .package) { return "package" }
            if type.conforms(to: .folder) { return "folder" }
            return "file"
        }
        let last = (path as NSString).lastPathComponent
        if last.lowercased().hasSuffix(".app") { return "app" }
        return (last as NSString).pathExtension.isEmpty ? "folder or file" : "file or package"
    }

    private static let systemRoots: Set<String> = ["library", "system", "private", "var", "tmp", "etc", "usr", "bin", "sbin", "cores", "dev"]

    /// The privacy boundary: whether a path may be sent to the model.
    static func isAllowed(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        let parts = path.split(separator: "/").map { $0.lowercased() }
        guard !parts.isEmpty else { return false }
        if parts.contains(where: { $0.hasPrefix(".") || $0 == "library" || $0 == "deriveddata" || $0 == "node_modules" }) { return false }
        if systemRoots.contains(parts[0]) { return false }
        if parts[0] == "volumes", parts.count > 2, systemRoots.contains(parts[2]) { return false }
        // Inside an app bundle: its Contents, never the app.
        if parts.dropLast().contains(where: { $0.hasSuffix(".app") }) { return false }
        return SecretScanner.redact(path) == path
    }

    /// Allowed only; exact last component first (as written, then without
    /// ".app"), then shorter paths; at most `maximumPaths`, and how many more.
    static func ranked(_ found: [Found], query: String) -> (shown: [Found], more: Int) {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        func rank(_ found: Found) -> Int {
            let last = (found.path as NSString).lastPathComponent.lowercased()
            if last == query { return 0 }
            return last.hasSuffix(".app") && String(last.dropLast(4)) == query ? 1 : 2
        }
        let allowed = found.filter { isAllowed($0.path) }
            .sorted { (rank($0), $0.path.count, $0.path) < (rank($1), $1.path.count, $1.path) }
        return (Array(allowed.prefix(maximumPaths)), max(0, allowed.count - maximumPaths))
    }

    // MARK: The tool

    static func toolResult(name: String, run: (String) -> RunOutput = runSpotlight) -> [String: Any] {
        if let problem = queryProblem(name) {
            return RealtimeOpenAppTool.toolResult(for: RealtimeToolRefusal(error: "findFileBadName",
                message: "find_file needs a file, folder or app name (not a path): this one is \(problem)"))
        }
        let name = name.trimmingCharacters(in: .whitespaces)
        // `-name` matches the display name, which hides ".app": "Xcode.app" finds nothing (unseen I10 2026-10-25).
        let asked = name.lowercased().hasSuffix(".app") && name.count > 4 ? String(name.dropLast(4)) : name
        let output = run(asked)
        if output.launchFailed {
            return RealtimeOpenAppTool.toolResult(for: RealtimeToolRefusal(error: "findFileUnavailable", message: "Spotlight could not be asked"))
        }
        if output.timedOut {
            return RealtimeOpenAppTool.toolResult(for: RealtimeToolRefusal(error: "findFileTimedOut",
                message: "Spotlight did not answer in \(Int(timeoutSeconds)) s"))
        }
        let (shown, more) = ranked(parse(output.data), query: name)
        var result: [String: Any] = ["ok": true, "paths": shown.map { ["path": $0.path, "kind": $0.kind] }, "more": more]
        if shown.isEmpty { result["message"] = "nothing by that name outside system, Library and hidden folders" }
        return result
    }

    /// `mdfind -0 -name <name> -attr kMDItemContentType`, stdout only, killed at
    /// `timeoutSeconds`. Blocks: call it off main.
    static func runSpotlight(_ name: String) -> RunOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-0", "-name", name, "-attr", "kMDItemContentType"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return RunOutput(data: Data(), launchFailed: true) }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: deadline)
        var data = Data()
        var cut = false
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > maximumOutputBytes {
                cut = true
                process.terminate()
                break
            }
        }
        deadline.cancel()
        process.waitUntilExit()
        // Killed by the deadline, not by the cap: SIGTERM, and we did not cut it.
        let timedOut = !cut && process.terminationReason == .uncaughtSignal
        if cut, let lastRecord = data.lastIndex(of: 0) { data = data.prefix(through: lastRecord) }
        return RunOutput(data: timedOut ? Data() : data, timedOut: timedOut)
    }
}
