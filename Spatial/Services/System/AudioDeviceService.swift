import CoreAudio
import Foundation
import OSLog

struct AudioOutputDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    var isBlackHole: Bool {
        name.localizedCaseInsensitiveContains("BlackHole")
    }
}

final class AudioDeviceService {
    private let logger = Logger(subsystem: "com.spatial.app", category: "AudioDeviceService")

    func allOutputDevices() -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return []
        }

        return deviceIDs.compactMap { outputDevice(for: $0) }
    }

    func systemOutputDevice() -> AudioOutputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID) == noErr,
              deviceID != kAudioDeviceUnknown else {
            return nil
        }

        return outputDevice(for: deviceID)
    }

    func blackHoleDevice() -> AudioOutputDevice? {
        allOutputDevices().first { $0.isBlackHole }
    }

    func deviceWithUID(_ uid: String) -> AudioOutputDevice? {
        allOutputDevices().first { $0.uid == uid }
    }

    func setSystemOutputDevice(_ device: AudioOutputDevice) throws {
        var deviceID = device.id
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice
        ]

        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                UInt32(MemoryLayout<AudioDeviceID>.size),
                &deviceID
            )
            if status != noErr {
                logger.error("Failed to set system output device '\(device.name, privacy: .public)' selector=\(selector): OSStatus=\(status)")
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                    NSLocalizedDescriptionKey: "Could not set system output device to \(device.name)"
                ])
            }
        }

        logger.info("System output device set to: \(device.name, privacy: .public) uid=\(device.uid, privacy: .public)")
    }

    private func outputDevice(for deviceID: AudioDeviceID) -> AudioOutputDevice? {
        guard hasOutputChannels(deviceID) else { return nil }

        let uid = stringProperty(kAudioDevicePropertyDeviceUID, on: deviceID) ?? ""
        let name = stringProperty(kAudioObjectPropertyName, on: deviceID) ?? "Unknown"

        return AudioOutputDevice(id: deviceID, uid: uid, name: name)
    }

    private func hasOutputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return false
        }

        let bufferCount = Int(dataSize) / MemoryLayout<AudioBufferList>.size
        return bufferCount > 0
    }

    private func stringProperty(_ selector: AudioObjectPropertySelector, on deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var cfString: CFString? = nil
        var dataSize = UInt32(MemoryLayout<CFString?>.size)

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &cfString)
        guard status == noErr, let result = cfString else { return nil }
        return result as String
    }
}
