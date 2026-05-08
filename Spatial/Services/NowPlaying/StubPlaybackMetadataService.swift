import AppKit
import Foundation
import OSLog

final class StubPlaybackMetadataService: PlaybackMetadataService {
    private let logger = Logger(subsystem: "com.spatial.app", category: "NowPlaying")
    private let fallback = MockData.previewNowPlaying
    private let fileManager = FileManager.default
    private var lastLoggedSystemAudioSignature: String?
    private var lastLoggedBrowserTabSignature: String?

    func currentNowPlaying(for selectedSource: AudioSourceOption?) -> NowPlayingInfo {
        guard let selectedSource else {
            return fallback
        }

        switch selectedSource {
        case .spotify:
            return spotifyInfo()
        case .appleMusic:
            return musicInfo()
        case .systemAudio:
            return systemAudioInfo()
        case .externalInput:
            return waitingInfo(for: selectedSource, subtitle: "External Input")
        }
    }

    private func spotifyInfo() -> NowPlayingInfo {
        let appName = "Spotify"
        guard isRunning(bundleIdentifier: "com.spotify.client") else {
            logger.debug("Spotify not running")
            return waitingInfo(for: .spotify, subtitle: appName)
        }

        let title = appleScriptValue("""
        tell application "\(appName)"
            if player state is playing then
                return name of current track
            end if
        end tell
        """)

        let artist = appleScriptValue("""
        tell application "\(appName)"
            if player state is playing then
                return artist of current track
            end if
        end tell
        """)

        let artworkURL = appleScriptValue("""
        tell application "\(appName)"
            if player state is playing then
                return artwork url of current track
            end if
        end tell
        """).flatMap(URL.init(string:))

        if let title, !title.isEmpty {
            logger.info("Spotify now playing detected: \(title, privacy: .public)")
            return NowPlayingInfo(
                trackName: title,
                artistName: artist ?? appName,
                sourceName: appName,
                isPlaying: true,
                source: .spotify,
                artworkURL: artworkURL,
                artworkSystemName: "music.note.list"
            )
        }

        return waitingInfo(for: .spotify, subtitle: appName)
    }

    private func musicInfo() -> NowPlayingInfo {
        let appName = "Music"
        guard isRunning(bundleIdentifier: "com.apple.Music") else {
            logger.debug("Apple Music not running")
            return waitingInfo(for: .appleMusic, subtitle: "Apple Music")
        }

        let title = appleScriptValue("""
        tell application "\(appName)"
            if player state is playing then
                return name of current track
            end if
        end tell
        """)

        let artist = appleScriptValue("""
        tell application "\(appName)"
            if player state is playing then
                return artist of current track
            end if
        end tell
        """)

        let databaseID = appleScriptValue("""
        tell application "\(appName)"
            if player state is playing then
                return (database ID of current track) as text
            end if
        end tell
        """)

        if let title, !title.isEmpty {
            let artworkURL = databaseID.flatMap(cachedMusicArtworkURL(for:))
            logger.info("Apple Music now playing detected: \(title, privacy: .public)")
            return NowPlayingInfo(
                trackName: title,
                artistName: artist ?? "Apple Music",
                sourceName: "Apple Music",
                isPlaying: true,
                source: .appleMusic,
                artworkURL: artworkURL,
                artworkSystemName: "music.note"
            )
        }

        return waitingInfo(for: .appleMusic, subtitle: "Apple Music")
    }

    private func systemAudioInfo() -> NowPlayingInfo {
        if let browserInfo = browserSystemAudioInfo() {
            logSystemAudioMappingIfNeeded(for: browserInfo)
            return browserInfo
        }

        let fallbackApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "System Audio"
        logSystemAudioFallbackIfNeeded(appName: fallbackApp)
        return NowPlayingInfo(
            trackName: "System Output Ready",
            artistName: fallbackApp,
            sourceName: "System Audio",
            isPlaying: true,
            source: .systemAudio,
            artworkURL: nil,
            artworkSystemName: "desktopcomputer"
        )
    }

    private func browserSystemAudioInfo() -> NowPlayingInfo? {
        let browsers: [(name: String, bundleIdentifier: String)] = [
            ("Brave Browser", "com.brave.Browser"),
            ("Google Chrome", "com.google.Chrome"),
            ("Safari", "com.apple.Safari"),
            ("Arc", "company.thebrowser.Browser")
        ]

        for browser in browsers where isRunning(bundleIdentifier: browser.bundleIdentifier) {
            if let title = browserTabTitle(appName: browser.name), !title.isEmpty {
                guard isLikelyMediaTabTitle(title) else { continue }
                logBrowserTabDetectionIfNeeded(browserName: browser.name, title: title)
                return NowPlayingInfo(
                    trackName: normalizedTrackTitle(from: title),
                    artistName: browser.name,
                    sourceName: "System Audio",
                    isPlaying: true,
                    source: .systemAudio,
                    artworkURL: nil,
                    artworkSystemName: "globe"
                )
            }
        }

        return nil
    }

    private func isLikelyMediaTabTitle(_ title: String) -> Bool {
        let loweredTitle = title.lowercased()
        let mediaMarkers = [
            "youtube",
            "youtube music",
            "spotify",
            "soundcloud",
            "bandcamp",
            "netflix",
            "twitch",
            "vimeo",
            "deezer",
            "tidal",
            "pandora",
            "apple music",
            "prime video",
            "disney+",
            "hulu",
            "crunchyroll"
        ]

        return mediaMarkers.contains { loweredTitle.contains($0) }
    }

    private func browserTabTitle(appName: String) -> String? {
        appleScriptValue("""
        tell application "\(appName)"
            if (count of windows) is greater than 0 then
                return title of active tab of front window
            end if
        end tell
        """)
    }

    private func normalizedTrackTitle(from tabTitle: String) -> String {
        let separators = [" - YouTube", " - YouTube Music", " | Spotify", " - Brave"]

        for separator in separators where tabTitle.contains(separator) {
            return tabTitle.replacingOccurrences(of: separator, with: "")
        }

        return tabTitle
    }

    private func waitingInfo(for source: AudioSourceOption, subtitle: String) -> NowPlayingInfo {
        NowPlayingInfo(
            trackName: "Waiting for Signal",
            artistName: subtitle,
            sourceName: source.title.replacingOccurrences(of: "\n", with: " "),
            isPlaying: false,
            source: source,
            artworkURL: nil,
            artworkSystemName: source == .systemAudio ? "desktopcomputer" : source.symbolName
        )
    }

    private func isRunning(bundleIdentifier: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty == false
    }

    private func logBrowserTabDetectionIfNeeded(browserName: String, title: String) {
        let signature = "\(browserName)|\(title)"
        guard signature != lastLoggedBrowserTabSignature else { return }
        logger.debug("Detected browser tab title from \(browserName, privacy: .public): \(title, privacy: .public)")
        lastLoggedBrowserTabSignature = signature
    }

    private func logSystemAudioMappingIfNeeded(for nowPlaying: NowPlayingInfo) {
        let signature = "browser|\(nowPlaying.trackName)|\(nowPlaying.artistName)"
        guard signature != lastLoggedSystemAudioSignature else { return }
        logger.info("System audio mapped to browser metadata: \(nowPlaying.trackName, privacy: .public) by \(nowPlaying.artistName, privacy: .public)")
        lastLoggedSystemAudioSignature = signature
    }

    private func logSystemAudioFallbackIfNeeded(appName: String) {
        let signature = "fallback|\(appName)"
        guard signature != lastLoggedSystemAudioSignature else { return }
        logger.debug("System audio fallback metadata using frontmost app: \(appName, privacy: .public)")
        lastLoggedSystemAudioSignature = signature
    }

    private func appleScriptValue(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)

        if error != nil {
            return nil
        }

        return result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func appleScriptDescriptor(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)

        if error != nil {
            return nil
        }

        return result
    }

    private func cachedMusicArtworkURL(for databaseID: String) -> URL? {
        let cacheURL = artworkCacheDirectory.appendingPathComponent("music-\(sanitizedCacheKey(databaseID)).png")
        if fileManager.fileExists(atPath: cacheURL.path) {
            return cacheURL
        }

        guard let descriptor = appleScriptDescriptor("""
        tell application "Music"
            if player state is playing then
                set currentTrack to current track
                if (count of artworks of currentTrack) > 0 then
                    return data of artwork 1 of currentTrack
                end if
            end if
        end tell
        """) else {
            return nil
        }

        let artworkData = descriptor.data
        guard !artworkData.isEmpty,
              let image = NSImage(data: artworkData),
        let pngData = pngData(from: image) else {
            return nil
        }

        do {
            try fileManager.createDirectory(at: artworkCacheDirectory, withIntermediateDirectories: true, attributes: nil)
            try pngData.write(to: cacheURL, options: .atomic)
            return cacheURL
        } catch {
            logger.error("Failed to cache Apple Music artwork: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private var artworkCacheDirectory: URL {
        let baseURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return baseURL.appendingPathComponent("SpatialArtworkCache", isDirectory: true)
    }

    private func sanitizedCacheKey(_ key: String) -> String {
        key.replacingOccurrences(of: #"[^A-Za-z0-9_-]"#, with: "-", options: .regularExpression)
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }
}
