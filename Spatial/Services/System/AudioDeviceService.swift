import AudioToolbox
import CoreAudio
import Foundation
import OSLog

protocol SpatialDriverInstalling {
    func installDriver() async throws
}

struct AudioOutputDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    var isSpatialVirtualDevice: Bool {
        uid == AudioDeviceService.spatialVirtualDeviceUID
            || name == AudioDeviceService.spatialVirtualDeviceName
    }
}

struct HALDriverFactoryConflict: Equatable {
    let factoryUUID: String
    let bundleNames: [String]
}

struct SpatialVirtualDeviceReadiness: Equatable {
    let device: AudioOutputDevice?
    let issue: String?

    var isUsable: Bool {
        device != nil && issue == nil
    }
}

private struct HALDriverSignatureDiagnostics {
    let signature: String?
    let identifier: String?

    var isAdHoc: Bool {
        signature?.caseInsensitiveCompare("adhoc") == .orderedSame
    }
}

final class AudioDeviceService {
    static let spatialVirtualDeviceUID = "com.spatial.app.driver.speaker"
    static let spatialVirtualDeviceName = "Spatial Speaker"
    static let spatialDriverBundleName = "SpatialSpeaker.driver"
    static let legacyDriverBundleNames = [
        "VirtualDesktopSpeakers.driver",
        "VirtualDesktopMicrophone.driver"
    ]
    static let spatialDriverInstallDirectory = "/Library/Audio/Plug-Ins/HAL"

    private let logger = Logger(subsystem: "com.spatial.app", category: "AudioDeviceService")
    private let fileManager = FileManager.default
    private var cachedSpatialVirtualDeviceReadiness: SpatialVirtualDeviceReadiness?
    private var cachedSpatialVirtualDeviceReadinessDate: Date?
    private var lastEnumeratedDevicesSummary: String?
    private var lastEnumeratedDevicesLogDate: Date?
    private var lastReadinessFailureSignature: String?
    private var lastReadinessFailureLogDate: Date?
    private let repeatedEnumerationLogInterval: TimeInterval = 15
    private let repeatedReadinessFailureLogInterval: TimeInterval = 30

    func invalidateSpatialVirtualDeviceReadinessCache() {
        cachedSpatialVirtualDeviceReadiness = nil
        cachedSpatialVirtualDeviceReadinessDate = nil
    }

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

        let debugSummary = deviceIDs.map { deviceID -> String in
            let uid = stringProperty(kAudioDevicePropertyDeviceUID, on: deviceID) ?? "<nil>"
            let name = stringProperty(kAudioObjectPropertyName, on: deviceID) ?? "<nil>"
            let outputChannels = outputChannelCount(deviceID)
            return "id=\(deviceID) name=\(name) uid=\(uid) out=\(outputChannels)"
        }.joined(separator: "; ")
        logEnumeratedDevicesIfNeeded(debugSummary)

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

    func spatialVirtualDevice() -> AudioOutputDevice? {
        allOutputDevices().first { $0.isSpatialVirtualDevice }
    }

    func spatialVirtualDeviceReadiness() -> SpatialVirtualDeviceReadiness {
        if let cachedSpatialVirtualDeviceReadiness,
           let cachedSpatialVirtualDeviceReadinessDate,
           Date().timeIntervalSince(cachedSpatialVirtualDeviceReadinessDate) < 1 {
            return cachedSpatialVirtualDeviceReadiness
        }

        let readiness: SpatialVirtualDeviceReadiness

        guard let device = spatialVirtualDevice() else {
            let outputs = allOutputDevices().map { "\($0.name) [\($0.uid)]" }.joined(separator: ", ")
            let issue = missingSpatialVirtualDeviceIssue()
            logReadinessFailureIfNeeded(
                signature: "missing|\(isSpatialDriverInstalled)|\(outputs)|\(issue)",
                message: "Spatial Speaker readiness failed: device not found. installedDriver=\(self.isSpatialDriverInstalled) outputs=\(outputs) issue=\(issue)"
            )
            readiness = SpatialVirtualDeviceReadiness(device: nil, issue: issue)
            cachedSpatialVirtualDeviceReadiness = readiness
            cachedSpatialVirtualDeviceReadinessDate = Date()
            return readiness
        }

        guard let probeIssue = probeLoopbackReadiness(for: device.id) else {
            logger.info("Spatial Speaker readiness succeeded: id=\(device.id) uid=\(device.uid, privacy: .public) name=\(device.name, privacy: .public)")
            readiness = SpatialVirtualDeviceReadiness(device: device, issue: nil)
            cachedSpatialVirtualDeviceReadiness = readiness
            cachedSpatialVirtualDeviceReadinessDate = Date()
            return readiness
        }

        logReadinessFailureIfNeeded(
            signature: "probe|\(device.id)|\(device.uid)|\(probeIssue)",
            message: "Spatial Speaker readiness probe failed: id=\(device.id) uid=\(device.uid) name=\(device.name) issue=\(probeIssue)"
        )
        readiness = SpatialVirtualDeviceReadiness(device: device, issue: probeIssue)
        cachedSpatialVirtualDeviceReadiness = readiness
        cachedSpatialVirtualDeviceReadinessDate = Date()
        return readiness
    }

    var isSpatialDriverInstalled: Bool {
        installedSpatialDriverURL != nil
    }

    var installedSpatialDriverURL: URL? {
        let installDirectory = URL(fileURLWithPath: Self.spatialDriverInstallDirectory, isDirectory: true)
        let preferredURL = installDirectory.appendingPathComponent(Self.spatialDriverBundleName, isDirectory: true)

        if fileManager.fileExists(atPath: preferredURL.path) {
            return preferredURL
        }

        let directChildren = (try? fileManager.contentsOfDirectory(
            at: installDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return directChildren.first { child in
            child.pathExtension == "driver"
                && child.lastPathComponent.localizedCaseInsensitiveContains("Spatial")
        }
    }

    func deviceWithUID(_ uid: String) -> AudioOutputDevice? {
        allOutputDevices().first { $0.uid == uid }
    }

    func halDriverFactoryConflicts() -> [HALDriverFactoryConflict] {
        let installDirectory = URL(fileURLWithPath: Self.spatialDriverInstallDirectory, isDirectory: true)
        let driverBundles = (try? fileManager.contentsOfDirectory(
            at: installDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var bundlesByFactoryUUID: [String: Set<String>] = [:]

        for driverURL in driverBundles where driverURL.pathExtension == "driver" {
            guard let info = halDriverInfo(for: driverURL) else { continue }

            for factoryUUID in info.factoryUUIDs {
                bundlesByFactoryUUID[factoryUUID, default: []].insert(info.bundleName)
            }
        }

        return bundlesByFactoryUUID.compactMap { factoryUUID, bundleNames in
            guard bundleNames.count > 1 else { return nil }
            return HALDriverFactoryConflict(
                factoryUUID: factoryUUID,
                bundleNames: bundleNames.sorted()
            )
        }
        .sorted { $0.factoryUUID < $1.factoryUUID }
    }

    func halDriverConflictMessage() -> String? {
        let conflicts = halDriverFactoryConflicts()
        guard !conflicts.isEmpty else { return nil }

        let details = conflicts.map { conflict in
            let bundles = conflict.bundleNames.joined(separator: ", ")
            return "\(bundles) share factory UUID \(conflict.factoryUUID)"
        }.joined(separator: "; ")

        return "Conflicting HAL drivers were found in \(Self.spatialDriverInstallDirectory): \(details). Remove the duplicate driver, then restart Core Audio or reboot."
    }

    func missingSpatialVirtualDeviceIssue() -> String {
        if let conflict = halDriverConflictMessage() {
            return conflict
        }

        guard let installedDriverURL = installedSpatialDriverURL else {
            return "Install Spatial Speaker to let Spatial route and capture system audio."
        }

        if let diagnostics = signatureDiagnostics(for: installedDriverURL), diagnostics.isAdHoc {
            return "Spatial Speaker is installed, but the HAL bundle is still ad-hoc signed. macOS may refuse to publish ad-hoc audio drivers. Rebuild and reinstall it with a real Apple Development signing identity."
        }

        return "Spatial Speaker is installed, but macOS has not published a usable Core Audio device for it yet. Restart Core Audio or reboot. If it still does not appear, run Drivers/SpatialSpeaker/diagnose.sh and verify the driver signature and coreaudiod logs."
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
        outputChannelCount(deviceID) > 0
    }

    private func outputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return 0
        }

        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBuffer.deallocate() }

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawBuffer)
        guard status == noErr else {
            logger.error("Failed to read stream configuration for device id=\(deviceID): OSStatus=\(status)")
            return 0
        }

        let bufferList = rawBuffer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let audioBufferListPointer = UnsafeMutableAudioBufferListPointer(bufferList)
        return audioBufferListPointer.reduce(0) { partialResult, buffer in
            partialResult + Int(buffer.mNumberChannels)
        }
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

    private func logEnumeratedDevicesIfNeeded(_ summary: String) {
        let now = Date()
        let isRepeatedSummary = summary == lastEnumeratedDevicesSummary
        let loggedRecently = lastEnumeratedDevicesLogDate.map {
            now.timeIntervalSince($0) < repeatedEnumerationLogInterval
        } ?? false

        guard !isRepeatedSummary || !loggedRecently else { return }

        logger.info("Enumerated Core Audio devices: \(summary, privacy: .public)")
        lastEnumeratedDevicesSummary = summary
        lastEnumeratedDevicesLogDate = now
    }

    private func logReadinessFailureIfNeeded(signature: String, message: @autoclosure () -> String) {
        let now = Date()
        let isRepeatedFailure = signature == lastReadinessFailureSignature
        let loggedRecently = lastReadinessFailureLogDate.map {
            now.timeIntervalSince($0) < repeatedReadinessFailureLogInterval
        } ?? false

        guard !isRepeatedFailure || !loggedRecently else { return }

        let logMessage = message()
        logger.error("\(logMessage, privacy: .public)")
        lastReadinessFailureSignature = signature
        lastReadinessFailureLogDate = now
    }

    private func probeLoopbackReadiness(for deviceID: AudioDeviceID) -> String? {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &description) else {
            return "Core Audio HAL output unit is unavailable."
        }

        var audioUnit: AudioUnit?
        let newStatus = AudioComponentInstanceNew(component, &audioUnit)
        guard newStatus == noErr, let audioUnit else {
            return "Core Audio could not create a HAL output unit for Spatial Speaker (OSStatus \(newStatus))."
        }

        defer {
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
        }

        var enableInput: UInt32 = 1
        let enableInputStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enableInput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard enableInputStatus == noErr else {
            return "Spatial Speaker exists, but Core Audio could not enable loopback capture on it yet (OSStatus \(enableInputStatus))."
        }

        var disableOutput: UInt32 = 0
        let disableOutputStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &disableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard disableOutputStatus == noErr else {
            return "Spatial Speaker exists, but Core Audio could not prepare the capture unit yet (OSStatus \(disableOutputStatus))."
        }

        var mutableDeviceID = deviceID
        let bindStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard bindStatus == noErr else {
            let conflictSuffix = halDriverConflictMessage().map { " \($0)" } ?? ""
            return "Spatial Speaker is listed, but Core Audio could not bind a capture unit to it yet (OSStatus \(bindStatus)). Restart Core Audio or reboot, then try again.\(conflictSuffix)"
        }

        let initializeStatus = AudioUnitInitialize(audioUnit)
        guard initializeStatus == noErr else {
            let conflictSuffix = halDriverConflictMessage().map { " \($0)" } ?? ""
            return "Spatial Speaker is listed, but Core Audio could not initialize it for capture yet (OSStatus \(initializeStatus)). Restart Core Audio or reboot, then try again.\(conflictSuffix)"
        }

        return nil
    }

    private func halDriverInfo(for driverURL: URL) -> (bundleName: String, factoryUUIDs: [String])? {
        let infoURL = driverURL.appendingPathComponent("Contents/Info.plist")
        guard
            let data = try? Data(contentsOf: infoURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let dictionary = plist as? [String: Any]
        else {
            return nil
        }

        let factoryUUIDs = (dictionary["CFPlugInFactories"] as? [String: Any])?
            .keys
            .map { $0.lowercased() } ?? []

        return (bundleName: driverURL.lastPathComponent, factoryUUIDs: factoryUUIDs)
    }

    private func signatureDiagnostics(for driverURL: URL) -> HALDriverSignatureDiagnostics? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", "--verbose=4", driverURL.path]

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            logger.error("Failed to inspect driver signature for '\(driverURL.path, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            return nil
        }

        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return nil
        }

        let signature = output
            .split(separator: "\n")
            .first { $0.hasPrefix("Signature=") }
            .map { String($0.dropFirst("Signature=".count)) }

        let identifier = output
            .split(separator: "\n")
            .first { $0.hasPrefix("Identifier=") }
            .map { String($0.dropFirst("Identifier=".count)) }

        return HALDriverSignatureDiagnostics(signature: signature, identifier: identifier)
    }
}

final class BundledSpatialDriverInstaller: SpatialDriverInstalling {
    private let logger = Logger(subsystem: "com.spatial.app", category: "SpatialDriverInstaller")
    private let fileManager = FileManager.default

    func installDriver() async throws {
        guard let bundledDriver = bundledDriverURL() else {
            throw NSError(domain: "Spatial.DriverInstaller", code: -3001, userInfo: [
                NSLocalizedDescriptionKey: "SpatialSpeaker.driver was not found in this app build yet."
            ])
        }

        let cleanupCommands = AudioDeviceService.legacyDriverBundleNames.map { bundleName in
            "/bin/rm -rf '\(shellEscapedPath("\(AudioDeviceService.spatialDriverInstallDirectory)/\(bundleName)"))'"
        }

        let installPath = "\(AudioDeviceService.spatialDriverInstallDirectory)/\(bundledDriver.lastPathComponent)"
        let installCommands = [
            "/bin/rm -rf '\(shellEscapedPath(installPath))'",
            "/usr/bin/ditto '\(shellEscapedPath(bundledDriver.path))' '\(shellEscapedPath(installPath))'",
            "/usr/sbin/chown -R root:wheel '\(shellEscapedPath(installPath))'",
            "/bin/chmod -R a+rX '\(shellEscapedPath(installPath))'"
        ]

        let script = ([
            "/bin/mkdir -p '\(shellEscapedPath(AudioDeviceService.spatialDriverInstallDirectory))'"
        ] + cleanupCommands + installCommands + [
            "/usr/bin/killall coreaudiod"
        ]).joined(separator: "; ")

        let output = try await runAppleScriptShellCommand(script)
        if !output.isEmpty {
            logger.info("Driver install output: \(output, privacy: .public)")
        }

        logger.info("Installed bundled driver payload: \(bundledDriver.lastPathComponent, privacy: .public)")
    }

    private func bundledDriverURL() -> URL? {
        let candidateRoots: [URL] = [
            Bundle.main.builtInPlugInsURL,
            Bundle.main.resourceURL,
            Bundle.main.bundleURL.deletingLastPathComponent(),
            URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent("build/Debug"),
            URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent("build/Release")
        ].compactMap { $0 }

        for root in candidateRoots where fileManager.fileExists(atPath: root.path) {
            let directChildren = (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            if let speakerDriver = directChildren.first(where: { child in
                child.pathExtension == "driver"
                    && child.lastPathComponent == AudioDeviceService.spatialDriverBundleName
            }) {
                return speakerDriver
            }
        }

        return nil
    }

    private func runAppleScriptShellCommand(_ command: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [
                "-e",
                "do shell script \"\(appleScriptEscaped(command))\" with administrator privileges"
            ]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            process.terminationHandler = { [logger] process in
                let stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if process.terminationStatus == 0 {
                    continuation.resume(returning: stdout)
                    return
                }

                let message = stderr.isEmpty ? stdout : stderr
                logger.error("Driver install failed. status=\(process.terminationStatus) message=\(message, privacy: .public)")
                continuation.resume(throwing: NSError(domain: "Spatial.DriverInstaller", code: Int(process.terminationStatus), userInfo: [
                    NSLocalizedDescriptionKey: message.isEmpty
                        ? "Spatial could not install the bundled driver."
                        : message
                ]))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func shellEscapedPath(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "'\\''")
    }

    private func appleScriptEscaped(_ command: String) -> String {
        command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
