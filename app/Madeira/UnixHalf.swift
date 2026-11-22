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
/// What makes a swap coherent is that the half is reached through a function-pointer table
/// the PE ntdll owns (`__wine_unixlib_handle`), and that table is installed by the half's own
/// `load_ntdll_functions` while `__wine_main` bootstraps. Two consequences, both measured:
///
///   * Installing a table earlier — from app `init()`, before Wine starts — cannot work.
///     `load_ntdll_functions` runs later and overwrites it. So this does not try to; it
///     prefers the loaded half's `__wine_main`, and that half installs its own table at the
///     normal point. One half runs, one table exists.
///   * Mixing halves would be incoherent, because the half holds its own state (server
///     pointers, registry handles, the WoW64 main-image flag). That is why `ios_main_image_i386`
///     is written through this type as well: writing the archive's copy while the dylib runs
///     would set a variable the running half never reads.
///
/// Signing is not optional and not an entitlement question. Measured on device (build 14):
///
///   | signing                | dlopen result              |
///   | unsigned               | "missing code signature"   |
///   | ad-hoc (`ldid -S`)     | "code signature invalid"   |
///   | Apple Development      | loads                      |
///
/// LiveContainer re-signs the guest bundle with this project's own team (4CDWTGR84Z), so a
/// library signed with the same development identity passes validation. Ad-hoc has no team.
/// The entitlements plist never reaches the device — the installed guest binary is
/// `flags=0x0(none)`, so `disable-library-validation` is not part of the answer.
///
/// When no component is installed, the linked archive runs and every function below forwards
/// to it, so a fresh install with no packages behaves exactly like stock.
enum UnixHalf {
    /// Name of the library a component provides. Kept in sync with `build/ntdll-unix/build-dylib.sh`.
    static let libraryName = "libntdll_unix.dylib"

    /// Entry points the dylib exports. They are accessors rather than Wine's own symbols
    /// because the half is compiled with `-fvisibility=hidden`; `unixhalf_entry.c` is the
    /// single default-visible object and forwards to the hidden ones.
    private static let mainSymbol = "madeira_unix_half_main"
    private static let logSetFileSymbol = "madeira_unix_half_log_set_file"
    private static let mainI386Symbol = "madeira_unix_half_main_i386_addr"
    /// Optional: a component built before this existed has no child-table reader, and the
    /// caller then falls back to the linked archive's copy as before.
    private static let liveGameChildrenSymbol = "madeira_unix_half_live_game_children"

    /// Signature of the loaded half's `__wine_main`, as the app calls it.
    private typealias MainFn = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Void
    private typealias LogSetFileFn = @convention(c) (UnsafePointer<CChar>?) -> Void
    private typealias MainI386AddrFn = @convention(c) () -> UnsafeMutablePointer<Int32>?
    private typealias LiveGameChildrenFn = @convention(c) (UnsafeMutablePointer<CChar>?, Int32, Double) -> Int32

    private static var handle: UnsafeMutableRawPointer?
    private static var mainFn: MainFn?
    private static var logSetFileFn: LogSetFileFn?
    private static var mainI386AddrFn: MainI386AddrFn?
    private static var liveGameChildrenFn: LiveGameChildrenFn?

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
        // RTLD_LOCAL: nothing else resolves against it. Its own host symbols still bind,
        // because those come from the app by name and are already loaded.
        guard let loaded = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            let reason = dlerror().map { String(cString: $0) } ?? "dlerror returned nothing"
            return report("[unix-half] dyld REFUSED \(path): \(reason)")
        }

        guard let main = dlsym(loaded, mainSymbol),
              let logSetFile = dlsym(loaded, logSetFileSymbol),
              let mainI386Addr = dlsym(loaded, mainI386Symbol) else {
            // A library with the right name but the wrong surface is not a unix half. Refuse
            // it and keep the archive rather than starting Wine against a partial one.
            let missing = [
                dlsym(loaded, mainSymbol) == nil ? mainSymbol : nil,
                dlsym(loaded, logSetFileSymbol) == nil ? logSetFileSymbol : nil,
                dlsym(loaded, mainI386Symbol) == nil ? mainI386Symbol : nil,
            ].compactMap { $0 }
            dlclose(loaded)
            return report("[unix-half] \(path) is missing \(missing.joined(separator: ", ")); using the linked archive")
        }

        handle = loaded
        mainFn = unsafeBitCast(main, to: MainFn.self)
        logSetFileFn = unsafeBitCast(logSetFile, to: LogSetFileFn.self)
        mainI386AddrFn = unsafeBitCast(mainI386Addr, to: MainI386AddrFn.self)
        if let children = dlsym(loaded, liveGameChildrenSymbol) {
            liveGameChildrenFn = unsafeBitCast(children, to: LiveGameChildrenFn.self)
        }
        componentLoaded = true
        return report("[unix-half] component half INSTALLED from \(path)")
    }

    // MARK: - Dispatch used by the Objective-C bridge

    /// Start Wine from the loaded half. Returns false when nothing was loaded, so the caller
    /// can fall back to the linked symbol instead of calling through a null pointer.
    static func startWine(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Bool {
        guard let mainFn else { return false }
        mainFn(argc, argv)
        return true
    }

    /// Point the half's log at `path`. Returns false when the linked half should do it.
    static func setLogFile(_ path: UnsafePointer<CChar>) -> Bool {
        guard let logSetFileFn else { return false }
        logSetFileFn(path)
        return true
    }

    /// Publish the main image's machine to the half that will actually run.
    static func setMainImageI386(_ value: Int32) -> Bool {
        guard let mainI386AddrFn, let address = mainI386AddrFn() else { return false }
        address.pointee = value
        return true
    }

    /// Ask the running half which child pseudo-processes it started are still alive.
    ///
    /// The table is filled by `spawn_process`, which is unix side, so it exists in the
    /// loaded half's image. The linked archive's copy is a different array and is empty
    /// while a component runs — reading it made `MADEIRA_WAIT_CHILDREN` and the
    /// launcher-stub protection silently do nothing (a Dock session ended when
    /// `dockhost.exe` exited even though the game it had started was still loading).
    ///
    /// Returns `nil` when no component is loaded or it predates this accessor: the caller
    /// then uses the linked symbol, which is correct when the archive is what runs.
    static func liveGameChildren(_ buffer: UnsafeMutablePointer<CChar>?,
                                 _ length: Int32, _ maxAge: Double) -> Int32? {
        guard let liveGameChildrenFn else { return nil }
        return liveGameChildrenFn(buffer, length, maxAge)
    }

    /// One line to both channels: the app log, which is what a session is read from, and
    /// stderr, which catches the case where the log is not writable yet at launch.
    @discardableResult
    private static func report(_ verdict: String) -> String {
        LogStore.shared.log(verdict)
        fputs("\(verdict)\n", stderr)
        return verdict
    }
}

// MARK: - C entry points
//
// The bridge is Objective-C and starts Wine on a background thread at a point this Swift
// code does not control, so the hand-off is plain C functions rather than a Swift call into
// files that cannot import Swift.

/// Resolve a component's unix half. Call once, before any Wine code runs.
@_cdecl("madeira_unix_half_prepare")
public func madeiraUnixHalfPrepare() {
    UnixHalf.install()
}

/// Run the loaded half's `__wine_main`. Returns 0 when no component is loaded, and the
/// caller must then use the linked symbol.
@_cdecl("madeira_unix_half_start")
public func madeiraUnixHalfStart(_ argc: Int32,
                                 _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    UnixHalf.startWine(argc: argc, argv: argv) ? 1 : 0
}

/// Set the loaded half's log file. Returns 0 when no component is loaded.
@_cdecl("madeira_unix_half_set_log_file")
public func madeiraUnixHalfSetLogFile(_ path: UnsafePointer<CChar>?) -> Int32 {
    guard let path else { return 0 }
    return UnixHalf.setLogFile(path) ? 1 : 0
}

/// Write the main image's machine into the loaded half. Returns 0 when no component is loaded.
@_cdecl("madeira_unix_half_set_main_i386")
public func madeiraUnixHalfSetMainI386(_ value: Int32) -> Int32 {
    UnixHalf.setMainImageI386(value) ? 1 : 0
}

/// Count the child pseudo-processes the loaded half started that are still alive, and write
/// their names into `buffer`. Returns -1 when no component is loaded (the caller then reads
/// the linked archive's table), which is why 0 is a real answer here and not "unavailable".
@_cdecl("madeira_unix_half_live_game_children")
public func madeiraUnixHalfLiveGameChildren(_ buffer: UnsafeMutablePointer<CChar>?,
                                            _ length: Int32,
                                            _ maxAge: Double) -> Int32 {
    UnixHalf.liveGameChildren(buffer, length, maxAge) ?? -1
}
