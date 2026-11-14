// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 TimmyTurner51
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// .wcp component packages for Madeira.
//
// A .wcp is a zstd-compressed tar carrying `profile.json` and the component's
// files. DroidDeck and GameNative use it for FEX, DXVK and vkd3d; this file
// teaches Madeira to import the two kinds Madeira can use:
//
//   * FEX  (profile type containing "FEXCore"): libarm64ecfex.dll replaces the
//     ARM64EC module (xtajit64.dll), libwow64fex.dll replaces the WOW64 module
//     (xtajit.dll). Linux-host .so libraries are kept in the package but not
//     linked: Madeira runs the ARM64EC/WOW64 PE modules natively.
//   * Wine (profile type containing "Wine" or "Proton"): DLLs are linked over
//     the matching prefix folder (arm64ec/x86_64 -> system32, aarch64 ->
//     system32 or sysaa64, i386 -> syswow64).
//
// Imported files live in Documents/Components/<id>/, which the app can write.
// WineProcessBridge.m links the enabled packages over the prefix at the start
// of every Windows session, after the bundle's own links, so an imported file
// wins. Nothing in the bundle or the code signature changes.
//
// A FEX module built for Android/Linux cannot run inside Madeira: Madeira's
// FEX is built with the iOS host layer (FEX_IOS_HOST_BUILD). Importing such a
// package is allowed, and it will be reported as a Linux-host package, but the
// module has to be rebuilt from its patches for iOS before it can boot a game.

import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Errors

enum WCPError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

// MARK: - Component model

/// One imported package. `layout` is what the native bridge reads: a source
/// file inside the package and the prefix folder it replaces.
struct WCPComponent: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case fex
        case wine

        var label: String {
            switch self {
            case .fex: return "FEX"
            case .wine: return "Wine"
            }
        }
    }

    struct LayoutItem: Codable, Equatable {
        /// Path inside the component's folder, e.g. "payload/files/.../libarm64ecfex.dll".
        var source: String
        /// Prefix-relative destination with a folder token, e.g. "${system32}/xtajit64.dll".
        var dest: String
    }

    var id: String
    var name: String
    var kind: Kind
    var type: String
    var versionName: String
    var versionCode: Int?
    var detail: String
    var enabled: Bool
    var installedAt: Double
    var sourceFile: String
    var fileCount: Int
    var layout: [LayoutItem]
    var environment: [String: String]
    var notes: [String]

    var versionLine: String {
        if let versionCode, versionCode > 0 { return "\(versionName) (\(versionCode))" }
        return versionName
    }
}

// MARK: - Tar reading

/// A streaming reader over the uncompressed tar inside a .wcp. Only regular
/// files are yielded; paths are normalised and checked before the caller uses
/// them. PAX `path`/`size` records and GNU long names are honoured.
struct WCPTarArchive {
    struct Entry {
        let path: String
        let size: UInt64
        let dataOffset: UInt64
    }

    private let handle: FileHandle
    private let fileSize: UInt64

    static func open(_ url: URL) throws -> WCPTarArchive {
        let handle = try FileHandle(forReadingFrom: url)
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        return WCPTarArchive(handle: handle, fileSize: size)
    }

    func close() {
        try? handle.close()
    }

    /// Regular files in archive order. `body` may throw to stop early.
    func forEachFile(_ body: (Entry) throws -> Void) throws {
        var offset: UInt64 = 0
        var longName: String?
        var pax: [String: String] = [:]

        while offset + 512 <= fileSize {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 512), header.count == 512 else { break }
            if header.allSatisfy({ $0 == 0 }) { break }   // end-of-archive blocks

            var raw = [UInt8](header)
            guard let storedChecksum = octalValue(raw, 148, 8) else {
                throw WCPError.message("The package's tar header is malformed.")
            }
            for i in 148..<156 { raw[i] = 0x20 }
            let actualChecksum = raw.reduce(UInt64(0)) { $0 + UInt64($1) }
            guard storedChecksum == actualChecksum else {
                throw WCPError.message("The package's tar header checksum does not match.")
            }

            let type = raw[156] == 0 ? "0" : String(UnicodeScalar(raw[156]))
            let size = numericValue(raw, 124, 12) ?? 0
            let dataOffset = offset + 512
            let padded = (size + 511) / 512 * 512

            switch type {
            case "x", "g":
                let data = try read(dataOffset: dataOffset, count: Int(min(size, UInt64(1 << 20))))
                let records = parsePax(data)
                if type == "x" { pax.merge(records) { _, new in new } }
            case "L":
                let data = try read(dataOffset: dataOffset, count: Int(min(size, UInt64(1 << 20))))
                longName = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
            case "K":
                break                                        // long link name: not used
            case "0", "\0", "7":
                let headerName = tarName(raw)
                let name = pax["path"] ?? longName ?? headerName
                let entrySize = pax["size"].flatMap { UInt64($0) } ?? size
                if let path = safePath(name) {
                    try body(Entry(path: path, size: entrySize, dataOffset: dataOffset))
                }
                pax.removeAll()
                longName = nil
            default:
                break                                        // directories, links, devices
            }
            offset = dataOffset + padded
        }
    }

    func read(_ entry: Entry, limit: Int) throws -> Data {
        guard entry.size <= UInt64(limit) else {
            throw WCPError.message("A file in the package is larger than expected (\(entry.path)).")
        }
        return try read(dataOffset: entry.dataOffset, count: Int(entry.size))
    }

    /// Copy a file out without holding it in memory.
    func copy(_ entry: Entry, to destination: URL) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var remaining = entry.size
        var offset = entry.dataOffset
        while remaining > 0 {
            let want = Int(min(remaining, 4 << 20))
            try handle.seek(toOffset: offset)
            guard let chunk = try handle.read(upToCount: want), !chunk.isEmpty else {
                throw WCPError.message("The package ended in the middle of \(entry.path).")
            }
            try output.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
            offset += UInt64(chunk.count)
        }
    }

    private func read(dataOffset: UInt64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        try handle.seek(toOffset: dataOffset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw WCPError.message("The package's tar data is truncated.")
        }
        return data
    }
}

// MARK: - Header helpers

private func tarName(_ raw: [UInt8]) -> String {
    func field(_ start: Int, _ length: Int) -> String {
        let slice = raw[start..<min(start + length, raw.count)]
        let bytes = slice.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
    let name = field(0, 100)
    let prefix = field(345, 155)
    return prefix.isEmpty ? name : prefix + "/" + name
}

private func octalValue(_ raw: [UInt8], _ start: Int, _ length: Int) -> UInt64? {
    numericValue(raw, start, length)
}

/// Tar numbers are octal text, but GNU writes large values in base-256 with
/// the top bit of the first byte set.
private func numericValue(_ raw: [UInt8], _ start: Int, _ length: Int) -> UInt64? {
    guard start + length <= raw.count else { return nil }
    let field = Array(raw[start..<(start + length)])
    if let first = field.first, first & 0x80 != 0 {
        var value: UInt64 = UInt64(first & 0x7f)
        for byte in field.dropFirst() { value = (value << 8) | UInt64(byte) }
        return value
    }
    var text = ""
    for byte in field {
        if byte == 0 || byte == 0x20 { if !text.isEmpty { break } else { continue } }
        text.append(Character(UnicodeScalar(byte)))
    }
    return text.isEmpty ? 0 : UInt64(text, radix: 8)
}

private func parsePax(_ data: Data) -> [String: String] {
    var result: [String: String] = [:]
    let bytes = [UInt8](data)
    var i = 0
    while i < bytes.count {
        var j = i
        while j < bytes.count, bytes[j] != 0x20 { j += 1 }
        guard j < bytes.count, let length = Int(String(decoding: bytes[i..<j], as: UTF8.self)),
              length > 0, i + length <= bytes.count else { break }
        let record = bytes[j + 1..<(i + length)]
        if let equals = record.firstIndex(of: 0x3d) {
            let key = String(decoding: record[record.startIndex..<equals], as: UTF8.self)
            var value = String(decoding: record[(equals + 1)...], as: UTF8.self)
            if value.last == "\n" { value.removeLast() }
            result[key] = value
        }
        i += length
    }
    return result
}

/// Reject absolute paths, `..`, empty components and control characters.
private func safePath(_ raw: String) -> String? {
    var path = raw.replacingOccurrences(of: "\\", with: "/")
    while path.hasPrefix("./") { path.removeFirst(2) }
    path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !path.isEmpty, !path.contains("\0"), path.utf8.count < 4096 else { return nil }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
    return path
}

// MARK: - Installer

enum WCPInstaller {
    /// Bounds for a package. Wine farms are a few hundred MB; FEX is a few MB.
    static let maxExpandedBytes: UInt64 = 6 << 30
    static let maxEntryBytes: UInt64 = 2 << 30
    static let maxFileCount = 100_000
    static let maxProfileBytes = 1 << 20

    static func kind(type: String, files: [String]) -> WCPComponent.Kind? {
        let lower = type.lowercased()
        if lower.contains("fex") { return .fex }
        if lower.contains("wine") || lower.contains("proton") { return .wine }
        // Unknown label: infer from what the package carries. A FEX package is
        // recognisable by its module's name, anything else with DLLs is Wine.
        if files.contains(where: { ($0 as NSString).lastPathComponent.lowercased() == "libarm64ecfex.dll" }) { return .fex }
        if files.contains(where: { ["dll", "drv"].contains(($0 as NSString).pathExtension.lowercased()) }) { return .wine }
        return nil
    }

    /// Map the package's files onto prefix folders. The bridge resolves the
    /// tokens: ${system32}, ${syswow64}, ${sysx64}, ${sysaa64}, and
    /// ${aarch64} (system32 in an aarch64 session, sysaa64 in an ARM64EC one).
    static func layout(kind: WCPComponent.Kind, files: [String]) throws -> [WCPComponent.LayoutItem] {
        var items: [WCPComponent.LayoutItem] = []
        var seen: Set<String> = []

        func add(_ source: String, _ dest: String) {
            guard !seen.contains(dest) else { return }
            seen.insert(dest)
            items.append(.init(source: "payload/" + source, dest: dest))
        }

        switch kind {
        case .fex:
            for file in files {
                let base = (file as NSString).lastPathComponent.lowercased()
                switch base {
                case "libarm64ecfex.dll", "xtajit64.dll":
                    add(file, "${system32}/xtajit64.dll")
                case "libwow64fex.dll", "xtajit.dll":
                    add(file, "${system32}/xtajit.dll")
                default:
                    continue
                }
            }
            guard seen.contains("${system32}/xtajit64.dll") else {
                throw WCPError.message("This FEX package has no ARM64EC module (libarm64ecfex.dll).")
            }
        case .wine:
            for file in files {
                let lower = file.lowercased()
                let ext = (file as NSString).pathExtension.lowercased()
                guard ["dll", "drv", "cpl"].contains(ext) else { continue }
                let base = (file as NSString).lastPathComponent
                guard !base.isEmpty else { continue }
                if lower.contains("/i386-windows/") || lower.contains("/i386-unix/") {
                    add(file, "${syswow64}/" + base)
                } else if lower.contains("/aarch64-windows/") || lower.contains("/arm64-windows/") {
                    add(file, "${aarch64}/" + base)
                } else {
                    add(file, "${system32}/" + base)
                }
            }
            guard !items.isEmpty else {
                throw WCPError.message("This Wine package has no Windows libraries (.dll) to link.")
            }
        }
        return items
    }

    static func componentID(fileName: String, kind: WCPComponent.Kind) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let cleaned = String(stem.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        return (trimmed.isEmpty ? "component" : trimmed) + "-" + kind.rawValue
    }

    static func environment(from profile: [String: Any]) -> [String: String] {
        let raw = (profile["environment"] as? [String: Any]) ?? (profile["env"] as? [String: Any]) ?? [:]
        var result: [String: String] = [:]
        for (key, value) in raw {
            guard isValidEnvironmentName(key) else { continue }
            if let text = value as? String {
                result[key] = text
            } else if let number = value as? NSNumber {
                result[key] = number.stringValue
            }
        }
        return result
    }

    static func isValidEnvironmentName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.unicodeScalars.count <= 255 else { return false }
        let start = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_")
        let rest = start.union(CharacterSet(charactersIn: "0123456789"))
        return start.contains(first) && name.unicodeScalars.dropFirst().allSatisfy { rest.contains($0) }
    }

    static func install(_ package: URL, into root: URL) throws -> WCPComponent {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let staging = root.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let tar = staging.appendingPathComponent("package.tar")
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let status = tar.withUnsafeFileSystemRepresentation { tarPath in
            package.withUnsafeFileSystemRepresentation { packagePath in
                wcp_zstd_decompress_path(packagePath, tarPath, maxExpandedBytes, nil,
                                         &errorBuffer, errorBuffer.count)
            }
        }
        guard status == 0 else {
            let text = String(cString: errorBuffer)
            throw WCPError.message("The .wcp could not be decompressed: \(text.isEmpty ? "not a zstd file" : text)")
        }

        let archive = try WCPTarArchive.open(tar)
        defer { archive.close() }

        let payload = staging.appendingPathComponent("payload", isDirectory: true)
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)

        var profileBytes: Data?
        var files: [String] = []
        var total: UInt64 = 0

        try archive.forEachFile { entry in
            if entry.path == "profile.json" {
                guard entry.size <= UInt64(maxProfileBytes) else {
                    throw WCPError.message("The package's profile.json is too large.")
                }
                profileBytes = try archive.read(entry, limit: maxProfileBytes)
                return
            }
            guard entry.size <= maxEntryBytes else {
                throw WCPError.message("\(entry.path) is larger than Madeira imports from a .wcp.")
            }
            total += entry.size
            guard total <= maxExpandedBytes else {
                throw WCPError.message("The package expands past Madeira's size limit for a component.")
            }
            guard files.count < maxFileCount else {
                throw WCPError.message("The package has more files than Madeira imports from a .wcp.")
            }
            let destination = payload.appendingPathComponent(entry.path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try archive.copy(entry, to: destination)
            files.append(entry.path)
        }

        guard let profileBytes,
              let profile = try JSONSerialization.jsonObject(with: profileBytes) as? [String: Any] else {
            throw WCPError.message("The .wcp has no profile.json.")
        }
        let type = (profile["type"] as? String) ?? ""
        guard let kind = kind(type: type, files: files) else {
            throw WCPError.message("The .wcp type “\(type)” is not a FEX or Wine component.")
        }
        let layout = try layout(kind: kind, files: files)

        var notes: [String] = []
        if kind == .fex {
            let linux = files.filter { $0.hasSuffix(".so") }
            if !linux.isEmpty {
                notes.append("\(linux.count) Linux-host librar\(linux.count == 1 ? "y was" : "ies were") left out; Madeira runs the PE modules.")
            }
            if type.lowercased() != "fexcore" {
                notes.append("Built for \(type.isEmpty ? "another host" : type). Madeira needs its own iOS build of FEX, so this module may not start a game.")
            }
        }
        if !(profile["files"] as? [Any] ?? []).isEmpty {
            notes.append("The package's target paths were resolved onto Madeira's DLL folders.")
        }

        let id = componentID(fileName: package.lastPathComponent, kind: kind)
        let destination = root.appendingPathComponent(id, isDirectory: true)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: payload, to: destination)
        try profileBytes.write(to: destination.appendingPathComponent("profile.json"))

        let versionName = (profile["versionName"] as? String) ?? (package.deletingPathExtension().lastPathComponent)
        let versionCode = (profile["versionCode"] as? NSNumber)?.intValue
        let detail = (profile["description"] as? String) ?? ""

        return WCPComponent(
            id: id,
            name: versionName,
            kind: kind,
            type: type,
            versionName: versionName,
            versionCode: versionCode,
            detail: detail,
            enabled: true,
            installedAt: Date().timeIntervalSince1970,
            sourceFile: package.lastPathComponent,
            fileCount: files.count,
            layout: layout,
            environment: environment(from: profile),
            notes: notes
        )
    }
}

// MARK: - Model

@MainActor
final class WCPComponentsModel: ObservableObject {
    static let shared = WCPComponentsModel()

    struct State: Codable {
        var version = 1
        var components: [WCPComponent] = []
    }

    @Published private(set) var components: [WCPComponent] = []
    @Published private(set) var busy = false
    @Published var error: String?
    @Published var status: String?

    /// Documents/Components. WineProcessBridge.m reads state.json here.
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Components", isDirectory: true)
    }

    static var stateFile: URL { root.appendingPathComponent("state.json") }

    static var contentType: UTType {
        UTType(filenameExtension: "wcp") ?? .data
    }

    private init() { reload() }

    func reload() {
        guard let data = try? Data(contentsOf: Self.stateFile),
              let state = try? JSONDecoder().decode(State.self, from: data) else {
            components = []
            return
        }
        components = state.components.sorted { $0.installedAt > $1.installedAt }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
            let state = State(components: components)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: Self.stateFile, options: .atomic)
        } catch {
            self.error = "Could not save the component list: \(error.localizedDescription)"
        }
    }

    func report(_ error: Error) {
        self.error = error.localizedDescription
    }

    func install(from source: URL) {
        guard !busy else { return }
        error = nil
        status = nil
        busy = true

        let accessed = source.startAccessingSecurityScopedResource()
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("wcp-" + UUID().uuidString + "-" + source.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
        } catch {
            if accessed { source.stopAccessingSecurityScopedResource() }
            busy = false
            report(WCPError.message("Could not read the .wcp: \(error.localizedDescription)"))
            return
        }
        if accessed { source.stopAccessingSecurityScopedResource() }

        let root = Self.root
        let fileName = source.lastPathComponent
        Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                var component = try WCPInstaller.install(temporary, into: root)
                component.sourceFile = fileName
                let finished = component
                await MainActor.run { WCPComponentsModel.shared.installed(finished) }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { WCPComponentsModel.shared.failed(message) }
            }
        }
    }

    private func installed(_ component: WCPComponent) {
        // A re-import keeps the previous enabled choice.
        if let old = components.first(where: { $0.id == component.id }) {
            var merged = component
            merged.enabled = old.enabled
            components.removeAll { $0.id == component.id }
            components.insert(merged, at: 0)
        } else {
            components.insert(component, at: 0)
        }
        save()
        busy = false
        error = nil
        status = "Imported \(component.versionLine). It applies the next time a game starts."
        LogStore.shared.log("[wcp] imported \(component.id) type=\(component.type) files=\(component.fileCount) links=\(component.layout.count)")
    }

    private func failed(_ message: String) {
        busy = false
        error = message
        LogStore.shared.log("[wcp] import failed: \(message)")
    }

    func setEnabled(_ component: WCPComponent, _ enabled: Bool) {
        guard let index = components.firstIndex(where: { $0.id == component.id }) else { return }
        components[index].enabled = enabled
        save()
        LogStore.shared.log("[wcp] \(component.id) \(enabled ? "enabled" : "disabled")")
    }

    func remove(_ component: WCPComponent) {
        components.removeAll { $0.id == component.id }
        try? FileManager.default.removeItem(at: Self.root.appendingPathComponent(component.id, isDirectory: true))
        save()
        status = "Removed \(component.versionLine)."
        LogStore.shared.log("[wcp] removed \(component.id)")
    }

    /// Whether a component's environment lines will be exported.
    var environmentCount: Int {
        components.filter(\.enabled).reduce(0) { $0 + $1.environment.count }
    }
}

// MARK: - Settings › Windows components

struct ComponentsSettingsSection: View {
    @ObservedObject private var model = WCPComponentsModel.shared
    @State private var importing = false
    @State private var removing: WCPComponent?

    var body: some View {
        Section {
            if model.components.isEmpty {
                LabeledContent("Imported components", value: "None")
            }
            ForEach(model.components) { component in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(component.versionLine).font(.body)
                        Spacer()
                        Text(component.kind.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    if !component.detail.isEmpty {
                        Text(component.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Text("\(component.layout.count) file\(component.layout.count == 1 ? "" : "s") linked"
                         + (component.environment.isEmpty ? "" : " · \(component.environment.count) environment variables"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Toggle("Enabled", isOn: Binding(
                        get: { component.enabled },
                        set: { model.setEnabled(component, $0) }))
                    if !component.notes.isEmpty {
                        ForEach(component.notes, id: \.self) { note in
                            Text(note).font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    Button("Remove", role: .destructive) { removing = component }
                        .font(.caption)
                }
                .padding(.vertical, 2)
            }
            Button {
                importing = true
            } label: {
                Label("Import .wcp", systemImage: "square.and.arrow.down")
            }
            .disabled(model.busy)
            if model.busy {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Importing…").font(.caption)
                }
            }
            if let status = model.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Windows components (.wcp)")
        } footer: {
            Text("Imports FEX and Wine packages in the DroidDeck and GameNative .wcp format. An enabled package replaces the matching runtime files at the start of the next Windows session; the app itself is not modified. FEX packages built for Android or Linux cannot run on iOS, so a FEX package must be rebuilt with Madeira's iOS host layer.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [WCPComponentsModel.contentType]) { result in
            switch result {
            case .success(let url): model.install(from: url)
            case .failure(let error): model.report(error)
            }
        }
        .confirmationDialog("Remove this component?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            if let removing {
                Button("Remove \(removing.versionLine)", role: .destructive) {
                    model.remove(removing)
                    self.removing = nil
                }
            }
        } message: {
            Text("Its files are deleted from Madeira. Games use the bundled runtime again at the next launch.")
        }
    }
}
