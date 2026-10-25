//
//  FileFinderTests.swift
//  leanring-buddyTests
//
//  `find_file` (owner's ruling 2026-10-12): a local Spotlight lookup by NAME
//  whose matching PATHS — at most 20, never under a Library, system or hidden
//  folder — go to the model. G09 failed because Finder's own search matches
//  file contents and never showed the folder. The live half (`mdfind`) is
//  proven by running it; these prove the boundary, the ranking, the query
//  check, mdfind's output format and the tool's wiring.
//

import Foundation
import Testing
@testable import Clicky

struct FileFinderTests {

    /// mdfind's own output, as measured 2026-10-12: `-0` ends each record with
    /// NUL, `-attr` appends three spaces and "kMDItemContentType = <type>".
    private func output(_ records: [(String, String?)]) -> Data {
        Data(records.map { path, type in type.map { "\(path)   kMDItemContentType = \($0)" } ?? path }
            .map { $0 + "\0" }.joined().utf8)
    }

    private let measured: [(String, String?)] = [
        ("/Applications/Journey of pro/Heyclicky", "public.folder"),
        ("/Users/mybookpro/Library/Application Support/Cursor/User/globalStorage/anysphere.cursor-agent-worker/worker-data/"
            + "cursor-agent-worker-41af0e52a1/projects/Applications-Journey-of-pro-Heyclicky", "public.folder"),
        ("/Applications/HeyClicky.app", "com.apple.application-bundle")
    ]

    // MARK: The coordinator's measurement

    @Test func theMeasuredHeyclickyLookupKeepsTheTwoOutsideLibraryFolderFirst() {
        let result = FileFinder.toolResult(name: "Heyclicky", run: { _ in .init(data: output(measured)) })
        #expect(result["ok"] as? Bool == true)
        let paths = result["paths"] as? [[String: String]] ?? []
        #expect(paths.map { $0["path"] } == ["/Applications/Journey of pro/Heyclicky", "/Applications/HeyClicky.app"])
        #expect(paths.map { $0["kind"] } == ["folder", "app"])
        #expect(result["more"] as? Int == 0)
    }

    @Test func mdfindsRecordsAreParsedWithOrWithoutAContentType() {
        let found = FileFinder.parse(output([("/Applications/Notes.app", "com.apple.application-bundle"),
                                             ("/Users/o/Projects/report.pdf", "com.adobe.pdf"),
                                             ("/Users/o/Projects/thing.bundle", "com.apple.package"),
                                             ("/Users/o/Projects/notes.txt", "(null)"),
                                             ("/Users/o/Projects/scripts", nil),
                                             ("/Users/o/Projects/Other.app", nil)]))
        #expect(found.map(\.path) == ["/Applications/Notes.app", "/Users/o/Projects/report.pdf", "/Users/o/Projects/thing.bundle",
                                      "/Users/o/Projects/notes.txt", "/Users/o/Projects/scripts", "/Users/o/Projects/Other.app"])
        #expect(found.map(\.kind) == ["app", "file", "package", "file or package", "folder or file", "app"])
        #expect(FileFinder.parse(Data()).isEmpty)
    }

    // MARK: The boundary

    @Test func libraryHiddenSystemAndBundleInsidesNeverLeave() {
        let refused = [
            "/Users/o/Library/Mail/V10", "/Library/Preferences/x", "/System/Applications/Notes.app", "/private/var/db/x",
            "/var/folders/x", "/tmp/x", "/Users/o/.ssh/id_ed25519", "/Users/o/Projects/.git/config", "/Volumes/Backup/.Trashes/x",
            "/Users/o/.config", "/Applications/Xcode.app/Contents/Developer", "/Users/o/Projects/app/node_modules/left-pad",
            "/Users/o/Projects/DerivedData/Build", "/Volumes/Mac/Users/o/Library/Keychains", "/Volumes/Mac/System/Library",
            "relative/path", "", "/Users/o/a\nb", "/Users/o/sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789AbCdEfGh"
        ]
        for path in refused { #expect(!FileFinder.isAllowed(path), "\(path.debugDescription)") }
        for path in ["/Applications/Journey of pro/Heyclicky/scripts", "/Applications/HeyClicky.app", "/Users/o/Downloads/report.pdf",
                     "/Volumes/USB/Photos", "/opt/homebrew"] {
            #expect(FileFinder.isAllowed(path), "\(path)")
        }
    }

    @Test func exactNamesComeFirstThenShorterPathsAndTwentyAtMost() {
        var records: [(String, String?)] = (1...30).map { ("/Users/o/Projects/deep/sub\($0)/scripts-old\($0)", "public.folder") }
        records.append(("/Users/o/Projects/very/long/path/to/the/repo/scripts", "public.folder"))
        records.append(("/Users/o/scripts.txt", "public.plain-text"))
        let result = FileFinder.toolResult(name: "scripts", run: { _ in .init(data: output(records)) })
        let paths = (result["paths"] as? [[String: String]] ?? []).compactMap { $0["path"] }
        #expect(paths.count == FileFinder.maximumPaths)
        #expect(paths.first == "/Users/o/Projects/very/long/path/to/the/repo/scripts", "an exact name beats a shorter partial one")
        #expect(result["more"] as? Int == 32 - FileFinder.maximumPaths)
        let lengths = paths.dropFirst().map(\.count)
        #expect(lengths == lengths.sorted(), "then shorter paths first")
    }

    /// Unseen I10 2026-10-25: `mdfind -name Xcode.app` finds nothing (it matches the display name, "Xcode"), and the
    /// agent told the owner Xcode was not installed. An ".app" name is asked without it; the exact app still ranks first.
    @Test func anAppNameIsAskedByItsDisplayName() {
        var asked: String?
        let result = FileFinder.toolResult(name: "Xcode.app", run: { name in
            asked = name
            return .init(data: output([("/Applications/Journey of pro/xcode.py", "public.python-script"),
                                       ("/Applications/Xcode.app", "com.apple.application-bundle")]))
        })
        #expect(asked == "Xcode")
        #expect((result["paths"] as? [[String: String]])?.first?["path"] == "/Applications/Xcode.app")
    }

    @Test func nothingFoundIsOkWithNoPathsAndATimeoutIsAFailure() {
        let none = FileFinder.toolResult(name: "zzqx", run: { _ in .init(data: Data()) })
        #expect(none["ok"] as? Bool == true)
        #expect((none["paths"] as? [Any])?.isEmpty == true)
        let slow = FileFinder.toolResult(name: "zzqx", run: { _ in .init(data: Data(), timedOut: true) })
        #expect(slow["ok"] as? Bool == false)
        #expect(slow["error"] as? String == "findFileTimedOut")
        #expect(JarvisNotchReason.byErrorCode["findFileTimedOut"] != nil)
    }

    // MARK: The query

    @Test func aNameIsOneToAHundredCharactersNoSlashNoControlNoSecret() {
        for name in ["Heyclicky", "scripts", "Q3 report", String(repeating: "a", count: 100)] {
            #expect(FileFinder.queryProblem(name) == nil, "\(name)")
        }
        for name in ["", "   ", String(repeating: "a", count: 101), "a/b", "/Applications", "a\nb", "a\tb",
                     "sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789AbCdEfGh"] {
            #expect(FileFinder.queryProblem(name) != nil, "\(name.debugDescription)")
        }
        var ran = false
        let refused = FileFinder.toolResult(name: "a/b", run: { _ in ran = true; return .init(data: Data()) })
        #expect(refused["ok"] as? Bool == false)
        #expect(refused["error"] as? String == "findFileBadName")
        #expect(!ran, "a refused name never reaches mdfind")
    }

    // MARK: The tool

    @MainActor @Test func findFileIsAReadOnlyReadingToolTakingAName() async {
        #expect(RealtimeVoiceVerbs.allToolNames.contains("find_file"))
        #expect(!RealtimeVoiceVerbs.isActingTool("find_file"))
        #expect(AgentLoop.readingTools.contains("find_file"))
        #expect(AgentPlan.isReading("find_file"))
        #expect(!RealtimeHeardCheck.appliesTo(toolName: "find_file"), "it names a file, not an app")
        let call = RealtimeToolCall.parsed(callID: "f", name: "find_file", arguments: ["name": " Heyclicky "])
        #expect(call.text == "Heyclicky")
        #expect(call.appName == nil)
        #expect(AgentPlan.precheck([["tool": "find_file"]]) != nil)
        #expect(AgentPlan.precheck([["tool": "find_file", "name": "Heyclicky"]]) == nil)
        let declared = RealtimeVoiceVerbs.anthropicDeclarations().first { $0["name"] as? String == "find_file" }
        #expect((declared?["description"] as? String)?.contains("go_to_folder") == true)
        // Read-only tasks may call it: it sends no harness request, so nothing reaches readOnlyGuardedAnswer.
        let refused = await RealtimeOpenAppTool.dispatch(RealtimeToolCall.parsed(callID: "f", name: "find_file", arguments: [:]),
                                                         answer: { _ in Issue.record("find_file must never reach the harness"); return "" })
        #expect(refused.result["error"] as? String == "findFileBadName")
    }

    @MainActor @Test func thePromptSendsAnUnknownFolderThroughFindFileThenGoToFolder() {
        let prompt = AgentLoop.systemPrompt
        #expect(prompt.contains("To look inside a folder: when you know its path (~/Downloads, /Applications), call go_to_folder; "
            + "otherwise find_file the folder's name, pick the folder's path from its result and go_to_folder it; Finder's own search "
            + "only as a last resort."))
        #expect(!prompt.contains("otherwise find it (File > Find), then press_element its name"))
    }
}
