import AudioToolbox
import CoreAudio
import Foundation
import OSLog

private let savedDeviceUIDKey = "com.spatial.app.virtualRoutingSavedDeviceUID"

protocol VirtualAudioRoutingService: AnyObject {
    var isActive: Bool { get }
    var virtualDeviceAvailable: Bool { get }
    var virtualDeviceIssue: String? { get }
    func activate(preferredMonitorDeviceUID: String?, pinEngineOutput: (AudioDeviceID) -> Void) -> Bool
    func deactivate()
    func restoreOnLaunchIfNeeded()
}

final class SpatialVirtualAudioRoutingService: VirtualAudioRoutingService {
    private let logger = Logger(subsystem: "com.spatial.app", category: "VirtualAudioRouting")
    private let deviceService: AudioDeviceService
    private(set) var isActive = false

    var virtualDeviceAvailable: Bool {
        deviceService.spatialVirtualDeviceReadiness().isUsable
    }

    var virtualDeviceIssue: String? {
        deviceService.spatialVirtualDeviceReadiness().issue
    }

    init(deviceService: AudioDeviceService) {
        self.deviceService = deviceService
    }

    func activate(preferredMonitorDeviceUID: String?, pinEngineOutput: (AudioDeviceID) -> Void) -> Bool {
        let readiness = deviceService.spatialVirtualDeviceReadiness()

        guard let spatialSpeaker = readiness.device, readiness.issue == nil else {
            if let issue = readiness.issue {
                logger.warning("Spatial Speaker unavailable for routing: \(issue, privacy: .public)")
            } else {
                logger.warning("Spatial Speaker not installed — virtual routing unavailable")
            }
            return false
        }

        let current = deviceService.systemOutputDevice()
        let currentIsSpatial = current?.isSpatialVirtualDevice ?? false
        let preferredMonitor = resolveMonitorDevice(
            preferredMonitorDeviceUID: preferredMonitorDeviceUID,
            currentOutput: current
        )

        if let preferredMonitor {
            UserDefaults.standard.set(preferredMonitor.uid, forKey: savedDeviceUIDKey)
            pinEngineOutput(preferredMonitor.id)
            logger.info("Prepared monitor output device: \(preferredMonitor.name, privacy: .public) uid=\(preferredMonitor.uid, privacy: .public)")
        } else if !currentIsSpatial, let current {
            UserDefaults.standard.set(current.uid, forKey: savedDeviceUIDKey)
            pinEngineOutput(current.id)
            logger.info("Falling back to current output device for monitor path: \(current.name, privacy: .public)")
        }

        if currentIsSpatial {
            guard let preferredMonitor else {
                logger.error("System output is already Spatial Speaker, but no real monitor device is available for a routing reset")
                UserDefaults.standard.removeObject(forKey: savedDeviceUIDKey)
                return false
            }

            logger.warning("System output already points at Spatial Speaker before activation — forcing a routing reset via '\(preferredMonitor.name, privacy: .public)'")

            guard switchSystemOutput(to: preferredMonitor, failureMessage: "Could not switch system output away from Spatial Speaker during routing reset") else {
                UserDefaults.standard.removeObject(forKey: savedDeviceUIDKey)
                return false
            }
        }

        guard switchSystemOutput(to: spatialSpeaker, failureMessage: "Could not switch system output to Spatial Speaker") else {
            UserDefaults.standard.removeObject(forKey: savedDeviceUIDKey)
            return false
        }

        isActive = true
        logger.info("Virtual routing active. System output routed to Spatial Speaker while Spatial monitors on '\(preferredMonitor?.name ?? current?.name ?? "unknown", privacy: .public)'.")
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

    private func switchSystemOutput(to device: AudioOutputDevice, failureMessage: String) -> Bool {
        do {
            try deviceService.setSystemOutputDevice(device)
        } catch {
            logger.error("\(failureMessage, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }

        guard deviceService.waitForSystemOutputDevice(uid: device.uid) else {
            logger.error("System output did not remain on expected device after switch. expectedUID=\(device.uid, privacy: .public) device=\(device.name, privacy: .public)")
            return false
        }

        return true
    }

    private func resolveMonitorDevice(
        preferredMonitorDeviceUID: String?,
        currentOutput: AudioOutputDevice?
    ) -> AudioOutputDevice? {
        if let preferredMonitorDeviceUID,
           let preferred = deviceService.deviceWithUID(preferredMonitorDeviceUID),
           !preferred.isSpatialVirtualDevice {
            return preferred
        }

        if let currentOutput, !currentOutput.isSpatialVirtualDevice {
            return currentOutput
        }

        return deviceService.allOutputDevices().first { !$0.isSpatialVirtualDevice }
    }
}

final class StubVirtualAudioRoutingService: VirtualAudioRoutingService {
    private(set) var isActive = false
    let virtualDeviceAvailable = false
    let virtualDeviceIssue: String? = nil

    func activate(preferredMonitorDeviceUID: String?, pinEngineOutput: (AudioDeviceID) -> Void) -> Bool { false }
    func deactivate() {}
    func restoreOnLaunchIfNeeded() {}
}
