import AudioToolbox
import CoreAudio
import Foundation
import OSLog

private let savedDeviceUIDKey = "com.spatial.app.echoPreventionSavedDeviceUID"

protocol EchoPreventionService: AnyObject {
    var isActive: Bool { get }
    var blackHoleAvailable: Bool { get }
    func activate(pinEngineOutput: (AudioDeviceID) -> Void) -> Bool
    func deactivate()
    func restoreOnLaunchIfNeeded()
}

final class BlackHoleEchoPreventionService: EchoPreventionService {
    private let logger = Logger(subsystem: "com.spatial.app", category: "EchoPrevention")
    private let deviceService: AudioDeviceService
    private(set) var isActive = false

    var blackHoleAvailable: Bool {
        deviceService.blackHoleDevice() != nil
    }

    init(deviceService: AudioDeviceService) {
        self.deviceService = deviceService
    }

    func activate(pinEngineOutput: (AudioDeviceID) -> Void) -> Bool {
        guard let blackHole = deviceService.blackHoleDevice() else {
            logger.warning("BlackHole not installed — echo prevention unavailable")
            return false
        }

        let current = deviceService.systemOutputDevice()
        let currentIsBlackHole = current?.isBlackHole ?? false

        if !currentIsBlackHole, let current {
            UserDefaults.standard.set(current.uid, forKey: savedDeviceUIDKey)
            pinEngineOutput(current.id)
        }

        guard !currentIsBlackHole else {
            logger.info("System output is already BlackHole — skipping switch")
            isActive = true
            return true
        }

        do {
            try deviceService.setSystemOutputDevice(blackHole)
        } catch {
            logger.error("Could not switch system output to BlackHole: \(error.localizedDescription, privacy: .public)")
            UserDefaults.standard.removeObject(forKey: savedDeviceUIDKey)
            return false
        }

        isActive = true
        logger.info("Echo prevention active. Saved output '\(current?.name ?? "unknown", privacy: .public)' → BlackHole. Engine pinned to real hardware.")
        return true
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        restoreSystemOutput()
    }

    func restoreOnLaunchIfNeeded() {
        guard UserDefaults.standard.string(forKey: savedDeviceUIDKey) != nil else { return }
        logger.warning("Found unrestored saved device from prior run — restoring system output now")
        restoreSystemOutput()
    }

    private func restoreSystemOutput() {
        guard let uid = UserDefaults.standard.string(forKey: savedDeviceUIDKey) else { return }
        UserDefaults.standard.removeObject(forKey: savedDeviceUIDKey)

        guard let device = deviceService.deviceWithUID(uid) else {
            logger.warning("Saved output device uid='\(uid, privacy: .public)' not found — cannot restore")
            return
        }

        do {
            try deviceService.setSystemOutputDevice(device)
            logger.info("System output restored to: \(device.name, privacy: .public)")
        } catch {
            logger.error("Failed to restore system output: \(error.localizedDescription, privacy: .public)")
        }
    }
}

final class StubEchoPreventionService: EchoPreventionService {
    private(set) var isActive = false
    let blackHoleAvailable = false

    func activate(pinEngineOutput: (AudioDeviceID) -> Void) -> Bool { false }
    func deactivate() {}
    func restoreOnLaunchIfNeeded() {}
}
