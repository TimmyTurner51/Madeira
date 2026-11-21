import Foundation

/// The Wine unix half, loaded from a `.wcp` component instead of being linked in.
///
/// FEX (`libarm64ecfex.dll`) and the Wine PE half (`ntdll.dll`, `kernel32.dll`, ...) are
/// PE images and already arrive as components, so a change to either is a package install.
/// The unix half is Mach-O — `libntdll_unix`, `libwineserver`, `libwin32u_unix` — and in the
/// stock layout it is a static archive in the IPA, which is why every change to it has cost
/// an app rebuild. It is also the half FH6 work keeps touching (`virtual_ios.c`,
/// `signal_arm64_ios.c`, `request_ios.c`).
///
/// What makes this deliverable at all is that the half is reached through **data**: the PE
/// ntdll owns `__wine_unixlib_handle`, a global holding a pointer to the unix dispatch
/// table, and it reads that pointer at runtime. A different table is a different unix half.
/// So a component can ship the half as a dylib; this type loads it, and hands its table to
/// the PE side through that global.
///
/// Two things are established here and one is still being measured:
///
///   * where a component's library lives (`Documents/Components/<id>/files/`), and
///   * whether dyld will map it at all under LiveContainer, whose re-sign at install gives
///     the app an identifier and team the Mac cannot reproduce. A replacement of the app's
///     own dylib is rejected outright; loading a new library is a different dyld path and
///     the answer is printed, not assumed.
///
/// Until a component ships a real half, the linked archive stays the fallback and this is a
/// no-op beyond one log line. `UnixHalf.install()` must run before Wine starts.
enum UnixHalf {
    /// Name of the library a component provides. Kept in sync with the build product in
    /// `build/ntdll-unix/build.sh`.
    static let libraryName = "libntdll_unix.dylib"

    /// Entry point a component's library may export to install its own dispatch table.
    /// The stock archive installs through `load_builtin_unixlib` instead; a dylib cannot,
    /// so it is handed the PE ntdll's handle global and writes the table itself.
    static let installSymbol = "madeira_unix_half_install"

    /// Symbol the PE ntdll resolves the table through.
    static let handleSymbol = "__wine_unixlib_handle"

    private static var handle: UnsafeMutableRawPointer?

    /// Whether a component's half is in use. When false, the linked archive is.
    static private(set) var componentLoaded = false

    /// Directory holding the enabled native component's files, if one provides this library.
    ///
    /// This reads `state.json`, the same list `WineProcessBridge` applies at session start, so
    /// "enabled" and the component kind mean the same thing here as everywhere else. Scanning
    /// for the file directly would load a component the user had switched off, or one of two
    /// copies left behind by an earlier install.
    static func componentDirectory() -> URL? {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let components = docs.appendingPathComponent("Components", isDirectory: true)
        guard let data = try? Data(contentsOf: components.appendingPathComponent("state.json")),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = state["components"] as? [[String: Any]] else { return nil }

        // Newest enabled native component wins, so a replacement release takes effect
        // without the previous one having to be removed by hand.
        let native = entries
            .filter { ($0["kind"] as? String) == Kind.native }
            .filter { ($0["enabled"] as? Bool) == true }
            .sorted { ($0["installedAt"] as? Double ?? 0) > ($1["installedAt"] as? Double ?? 0) }

        for entry in native {
            guard let id = entry["id"] as? String, !id.isEmpty,
                  !id.contains("/"), !id.contains("..") else { continue }
            let directory = components.appendingPathComponent(id, isDirectory: true)
            let candidate = directory.appendingPathComponent("files").appendingPathComponent(libraryName)
            if fm.fileExists(atPath: candidate.path) { return directory }
        }
        return nil
    }

    /// The component kind this loader serves, matching `WCPComponent.Kind.native`.
    private enum Kind { static let native = "native" }

    /// Load a component's unix half, if one is installed. Returns a one-line verdict for the
    /// log; safe to call when no component provides it.
    @discardableResult
    static func install() -> String {
        guard let directory = componentDirectory() else {
            return report("[unix-half] no component provides \(libraryName); using the linked archive")
        }
        let path = directory.appendingPathComponent("files")
            .appendingPathComponent(libraryName).path
        // RTLD_LOCAL: nothing else resolves against it until the table is handed over.
        guard let loaded = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            let reason = dlerror().map { String(cString: $0) } ?? "dlerror returned nothing"
            return report("[unix-half] dyld REFUSED \(path): \(reason)")
        }
        handle = loaded

        // The PE ntdll's handle global, if this library happens to be the half itself.
        // Resolving it here reports whether the component really is a unix half rather
        // than some other dylib that merely has the expected name.
        let ownHandle = dlsym(loaded, handleSymbol)
        let installer = dlsym(loaded, installSymbol)

        if let installer {
            // Signature: void install(void *pe_ntdll_handle_global). The dylib writes its
            // dispatch table through the address the PE side owns, which is what makes the
            // swap possible without relinking the app.
            typealias Install = @convention(c) (UnsafeMutableRawPointer?) -> Void
            let installFn = unsafeBitCast(installer, to: Install.self)
            installFn(UnixHalf.peHandleGlobal())
            componentLoaded = true
            return report("[unix-half] component half INSTALLED from \(path)")
        }

        return report("[unix-half] loaded \(path) but it exports no \(installSymbol)"
                      + " (handle-symbol=\(ownHandle != nil ? "present" : "absent")); using the linked archive")
    }

    /// One line to both channels: the app log, which is what a session is read from, and
    /// stderr, which catches the case where the log is not writable yet at launch.
    @discardableResult
    private static func report(_ verdict: String) -> String {
        LogStore.shared.log(verdict)
        fputs("\(verdict)\n", stderr)
        return verdict
    }

    /// Address of the PE ntdll's `__wine_unixlib_handle`, which the linked archive also
    /// writes. Nil when this build has no such global, which would be a build defect.
    private static func peHandleGlobal() -> UnsafeMutableRawPointer? {
        // RTLD_DEFAULT walks the loaded images, so this finds the PE ntdll's global without
        // this type needing its own copy of the symbol.
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), handleSymbol)
    }
}
