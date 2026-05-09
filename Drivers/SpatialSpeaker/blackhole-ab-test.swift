#!/usr/bin/env swift
// Stand-alone A/B test for the loopback HAL input unit setup used by
// `LiveAudioCaptureService.startLoopbackCaptureWithHALInputUnit`. Intended for
// the Spatial Speaker debug session described in
// debug-virtual-input-readinput-missing.plan.md (step 6).
//
// Usage:
//   swift Drivers/SpatialSpeaker/blackhole-ab-test.swift <deviceUIDOrName> [seconds]
//
// Examples:
//   swift Drivers/SpatialSpeaker/blackhole-ab-test.swift "BlackHole 2ch" 5
//   swift Drivers/SpatialSpeaker/blackhole-ab-test.swift com.spatial.app.driver.speaker 5
//
// What it does:
//   1. Resolves the AudioDeviceID for the supplied UID or device name.
//   2. Builds an AUHAL input unit using the exact same property-set sequence as the
//      Spatial app, with per-call status logging.
//   3. Starts capture for `seconds` seconds (default 5) and prints peak per buffer.
//   4. Reports min/max/non-zero buffer counts.
//
// Output per buffer: "tick n=<i> frames=<f> peak=<x>"
// Exit code 0 on success, 1 on AU/Core Audio failure.

import AudioToolbox
import CoreAudio
import Darwin

// MARK: - Args

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("Usage: \(arguments[0]) <deviceUIDOrName> [seconds]\n".utf8))
    exit(2)
}

let deviceQuery = arguments[1]
let captureSeconds: Double = arguments.count >= 3 ? (Double(arguments[2]) ?? 5) : 5

// MARK: - Helpers

func osStatusString(_ status: OSStatus) -> String {
    var bytes = [UInt8](repeating: 0, count: 4)
    var be = status.bigEndian
    memcpy(&bytes, &be, 4)
    let isAscii = bytes.allSatisfy { (0x20...0x7E).contains($0) }
    let fourcc = isAscii ? " (\(String(bytes: bytes, encoding: .ascii) ?? ""))" : ""
    return "\(status)\(fourcc)"
}

func allDeviceIDs() -> [AudioDeviceID] {
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
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids) == noErr else {
        return []
    }
    return ids
}

func deviceString(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var cf: CFString? = nil
    var dataSize = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &cf) == noErr else { return nil }
    return cf as String?
}

func channelCount(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
        return 0
    }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, raw) == noErr else { return 0 }
    let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    let pointer = UnsafeMutableAudioBufferListPointer(list)
    return pointer.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func resolveDevice(_ query: String) -> AudioDeviceID? {
    for id in allDeviceIDs() {
        let uid = deviceString(id, selector: kAudioDevicePropertyDeviceUID) ?? ""
        let name = deviceString(id, selector: kAudioObjectPropertyName) ?? ""
        if uid == query || name == query { return id }
        if name.localizedCaseInsensitiveContains(query) { return id }
    }
    return nil
}

func setAU(_ unit: AudioUnit, _ prop: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement, _ data: UnsafeMutableRawPointer, _ size: UInt32, label: String) -> OSStatus {
    let status = AudioUnitSetProperty(unit, prop, scope, element, data, size)
    let scopeName: String
    switch scope {
    case kAudioUnitScope_Global: scopeName = "global"
    case kAudioUnitScope_Input: scopeName = "input"
    case kAudioUnitScope_Output: scopeName = "output"
    default: scopeName = "scope=\(scope)"
    }
    print("AU set \(label) scope=\(scopeName) element=\(element) size=\(size) status=\(osStatusString(status))")
    return status
}

// MARK: - Resolve device

guard let deviceID = resolveDevice(deviceQuery) else {
    FileHandle.standardError.write(Data("Could not find a device matching '\(deviceQuery)'\n".utf8))
    exit(1)
}

let resolvedUID = deviceString(deviceID, selector: kAudioDevicePropertyDeviceUID) ?? "<nil>"
let resolvedName = deviceString(deviceID, selector: kAudioObjectPropertyName) ?? "<nil>"
let inputChannels = channelCount(deviceID, scope: kAudioObjectPropertyScopeInput)
let outputChannels = channelCount(deviceID, scope: kAudioObjectPropertyScopeOutput)
print("Resolved device id=\(deviceID) name='\(resolvedName)' uid='\(resolvedUID)' in=\(inputChannels) out=\(outputChannels)")

// MARK: - Read input physical format

func inputStreamFormat(_ deviceID: AudioDeviceID) -> AudioStreamBasicDescription? {
    var streamsAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, nil, &dataSize) == noErr, dataSize > 0 else { return nil }
    let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
    var streamIDs = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(deviceID, &streamsAddress, 0, nil, &dataSize, &streamIDs) == noErr,
          let firstStream = streamIDs.first else { return nil }
    var formatAddress = AudioObjectPropertyAddress(
        mSelector: kAudioStreamPropertyPhysicalFormat,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    var asbd = AudioStreamBasicDescription()
    var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioObjectGetPropertyData(firstStream, &formatAddress, 0, nil, &asbdSize, &asbd) == noErr else { return nil }
    print("Input stream physical format: streamID=\(firstStream) sampleRate=\(asbd.mSampleRate) channels=\(asbd.mChannelsPerFrame) bytesPerFrame=\(asbd.mBytesPerFrame) flags=\(asbd.mFormatFlags)")
    return asbd
}

guard var inputFormat = inputStreamFormat(deviceID) else {
    FileHandle.standardError.write(Data("Could not read input stream format for device id=\(deviceID)\n".utf8))
    exit(1)
}

// MARK: - Build AU

var description = AudioComponentDescription(
    componentType: kAudioUnitType_Output,
    componentSubType: kAudioUnitSubType_HALOutput,
    componentManufacturer: kAudioUnitManufacturer_Apple,
    componentFlags: 0,
    componentFlagsMask: 0
)
guard let component = AudioComponentFindNext(nil, &description) else {
    FileHandle.standardError.write(Data("HAL output unit unavailable\n".utf8))
    exit(1)
}
var auOpt: AudioUnit?
let newStatus = AudioComponentInstanceNew(component, &auOpt)
print("AudioComponentInstanceNew status=\(osStatusString(newStatus))")
guard newStatus == noErr, let au = auOpt else { exit(1) }

defer {
    AudioOutputUnitStop(au)
    AudioUnitUninitialize(au)
    AudioComponentInstanceDispose(au)
}

var enableInput: UInt32 = 1
guard setAU(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableInput, 4, label: "EnableIO/Input/elem1") == noErr else { exit(1) }

var disableOutput: UInt32 = 0
guard setAU(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disableOutput, 4, label: "EnableIO/Output/elem0") == noErr else { exit(1) }

var mutableDeviceID = deviceID
guard setAU(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &mutableDeviceID, UInt32(MemoryLayout<AudioDeviceID>.size), label: "CurrentDevice/Global/elem0") == noErr else { exit(1) }

// Read AUHAL's input element to verify the device-side hardware format we will work with.
var probeFormat = AudioStreamBasicDescription()
var probeSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
let probeStatus = AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &probeFormat, &probeSize)
print("AU get StreamFormat/Input/elem1 status=\(osStatusString(probeStatus)) sampleRate=\(probeFormat.mSampleRate) channels=\(probeFormat.mChannelsPerFrame) flags=\(probeFormat.mFormatFlags)")

// Set the AUHAL output side (post-conversion) to match.
var asbd = inputFormat
guard setAU(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), label: "StreamFormat/Output/elem1") == noErr else { exit(1) }

// MARK: - Callback

final class State {
    var bufferCount = 0
    var nonZeroCount = 0
    var maxPeak: Float = 0
    var lastPrintedTick = 0
    var audioUnit: AudioUnit
    var channels: Int
    var bytesPerFrame: Int

    init(audioUnit: AudioUnit, channels: Int, bytesPerFrame: Int) {
        self.audioUnit = audioUnit
        self.channels = channels
        self.bytesPerFrame = bytesPerFrame
    }
}

let state = State(
    audioUnit: au,
    channels: max(Int(probeFormat.mChannelsPerFrame), 1),
    bytesPerFrame: max(Int(probeFormat.mBytesPerFrame), 4 * max(Int(probeFormat.mChannelsPerFrame), 1))
)

let inputCallback: AURenderCallback = { (refcon, ioActionFlags, timeStamp, busNumber, frameCount, _) -> OSStatus in
    let state = Unmanaged<State>.fromOpaque(refcon).takeUnretainedValue()
    let totalBytes = Int(frameCount) * state.bytesPerFrame
    let bufferRaw = UnsafeMutableRawPointer.allocate(byteCount: totalBytes, alignment: MemoryLayout<Float>.alignment)
    defer { bufferRaw.deallocate() }
    var bufferList = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(mNumberChannels: UInt32(state.channels), mDataByteSize: UInt32(totalBytes), mData: bufferRaw)
    )

    let render = AudioUnitRender(state.audioUnit, ioActionFlags, timeStamp, busNumber, frameCount, &bufferList)
    if render != noErr {
        FileHandle.standardError.write(Data("AudioUnitRender status=\(render)\n".utf8))
        return render
    }

    let samples = bufferRaw.assumingMemoryBound(to: Float.self)
    var peak: Float = 0
    let totalFrames = Int(frameCount) * state.channels
    for i in 0..<totalFrames {
        let v = abs(samples[i])
        if v > peak { peak = v }
    }
    state.bufferCount += 1
    if peak > 0 { state.nonZeroCount += 1 }
    if peak > state.maxPeak { state.maxPeak = peak }
    if state.bufferCount - state.lastPrintedTick >= 10 || state.bufferCount <= 6 {
        state.lastPrintedTick = state.bufferCount
        print(String(format: "tick n=%d frames=%d peak=%.6f", state.bufferCount, Int(frameCount), peak))
    }
    return noErr
}

var callback = AURenderCallbackStruct(
    inputProc: inputCallback,
    inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(state).toOpaque())
)
guard setAU(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size), label: "SetInputCallback/Global/elem0") == noErr else { exit(1) }

let initStatus = AudioUnitInitialize(au)
print("AudioUnitInitialize status=\(osStatusString(initStatus))")
guard initStatus == noErr else { exit(1) }

let startStatus = AudioOutputUnitStart(au)
print("AudioOutputUnitStart status=\(osStatusString(startStatus))")
guard startStatus == noErr else { exit(1) }

print("Capturing for \(captureSeconds)s...")
RunLoop.current.run(until: Date(timeIntervalSinceNow: captureSeconds))

print("Summary: bufferCount=\(state.bufferCount) nonZeroCount=\(state.nonZeroCount) maxPeak=\(state.maxPeak)")
if state.bufferCount == 0 {
    FileHandle.standardError.write(Data("No callbacks received.\n".utf8))
    exit(1)
}
if state.nonZeroCount == 0 {
    FileHandle.standardError.write(Data("All buffers were silent (peak=0). Either the source isn't playing into '\(resolvedName)' or the device's input scope is broken.\n".utf8))
    exit(1)
}
exit(0)
