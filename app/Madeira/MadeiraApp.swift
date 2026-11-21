import Foundation
import SwiftUI

@main
struct MadeiraApp: App {
    init() {
        // A component may ship the Wine unix half as a dylib; when it does, this loads it
        // and hands its dispatch table to the PE ntdll. Must run before Wine starts, and it
        // is a no-op (one log line) when no component provides one.
        UnixHalf.install()
        // A package pushed into Documents/Import is installed on the next launch, so a
        // component release takes no UI interaction at all.
        Task { @MainActor in WCPComponentsModel.shared.installInboxAtLaunch() }
        // Opt-in iPhone pointer experiments (PhonePointer.m): before any scene exists.
        madeira_phone_pointer_setup()
        // madeira-bcd: the Metal Performance HUD's performance insights (the
        // notes that stack up left of its panel: shader compiles, similar render
        // passes, blit encoders) cover the game. Off unless madeira.cfg says
        // env.MTL_HUD_INSIGHTS_ENABLED = 1, which is exported later and wins.
        setenv("MTL_HUD_INSIGHTS_ENABLED", "0", 0)
        // Host pads as Windows.Gaming.Input gamepads (upstream's opt-in provider, willfaust/wine #40):
        // on by default here; madeira.cfg env.MADEIRA_WGI_HOST_PADS = 0 is exported later and wins.
        setenv("MADEIRA_WGI_HOST_PADS", "1", 0)
        // ml1172: read the screen on the main thread; library entries, whose
        // default Resolution comes from it, are also made on other threads.
        _ = ResolutionChoices.screen
        // A sign-in an installer left goes into the Keychain before anything else runs
        // (SigningRefresh.swift), only while the refresh is switched on.
        if SigningRefresh.enabled { SigningAccountStore.takeIn() }
        // Use one profile before Wine or Steam Cloud reads the prefix.
        ProfileUnification.run()
        // Games and downloads keep going when Madeira leaves the screen (BackgroundRun.swift).
        BackgroundRun.shared.start()
        // Read the cached library before the first grid page is built.
        if LibraryGridArm.enabled, SteamOwnedLibrary.enabled { SteamOwnedLibrary.shared.start() }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .background(InteractionFrameRateInstaller())   // touch frame-rate request (New library grid)
                .modifier(ClaimGamepadEvents())
                .onAppear {
                    ExternalDrives.shared.mountAll()
                    GamepadInput.shared.start()
                    HardwareInput.shared.start()
                    JITNetworkShortcut.shared.restoreLeftover()   // also starts its network path monitor
                    WineGeckoModel.shared.installAutomatically()  // on Wi-Fi, so Wine never asks (WineGecko.swift)
                    AchievementWatcher.shared.start()             // unlock banners from Steam's stats files (SteamAchievements.swift)
                    ClaudeHelp.install()                          // the fixes guide beside madeira-log.txt (ClaudeHelp.swift)
                }
                // madeira://jit-network/... (the Madeira JIT shortcut returning, JITNetwork.swift),
                // else a .wcp component package, else a shared game setup (a .madeirasetup file or
                // madeira://setup?d=..., GameSetupShare.swift), else madeira://play?exe=...
                // (Home Screen shortcuts, SavesAndShortcuts.swift).
                .onOpenURL { url in
                    if url.isFileURL && url.pathExtension.lowercased() == "wcp" {
                        Task { @MainActor in WCPComponentsModel.shared.install(from: url) }
                        return
                    }
                    // madeira://wcp?url=https://… downloads and installs a package, and
                    // madeira://wcp scans Madeira's Import folder. Both exist so a
                    // component can be installed without the Files sheet, which
                    // iOS 26/27 sometimes stops delivering taps to.
                    if url.scheme?.lowercased() == "madeira", url.host?.lowercased() == "wcp" {
                        let link = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                            .queryItems?.first { $0.name.lowercased() == "url" }?.value
                        Task { @MainActor in
                            if let link, !link.isEmpty {
                                WCPComponentsModel.shared.install(remote: link)
                            } else {
                                WCPComponentsModel.shared.importWaitingPackages()
                            }
                        }
                        return
                    }
                    if JITNetworkShortcut.shared.handle(url) || GameSetupInbox.shared.handle(url) { return }
                    ShortcutRouter.shared.handle(url)
                }
        }
    }
}
