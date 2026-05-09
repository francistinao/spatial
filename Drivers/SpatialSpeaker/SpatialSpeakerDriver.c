#include <CoreAudio/AudioHardware.h>
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#define kSpatialSpeakerFactoryUUID CFUUIDGetConstantUUIDWithBytes(NULL, 0xB7, 0x9D, 0x80, 0x1D, 0x85, 0xD5, 0x42, 0x59, 0x8A, 0x5E, 0x11, 0xA0, 0xB0, 0xB1, 0x7C, 0x8F)
#define kSpatialSpeakerLegacyPlugInTypeUUID CFUUIDGetConstantUUIDWithBytes(NULL, 0xF8, 0xBB, 0x1C, 0x28, 0xBA, 0xE8, 0x11, 0xD6, 0x9C, 0x31, 0x00, 0x03, 0x93, 0x15, 0xCD, 0x46)

enum
{
    kSpatialSpeakerDeviceObjectID = 2,
    kSpatialSpeakerInputStreamObjectID = 3,
    kSpatialSpeakerOutputStreamObjectID = 4
};

enum
{
    kSpatialSpeakerChannelCount = 2,
    kSpatialSpeakerNominalSampleRate = 48000,
    kSpatialSpeakerBufferFrameSize = 512,
    kSpatialSpeakerRingBufferFrames = 8192,
    kSpatialSpeakerZeroTimestampPeriod = 16384,
    kSpatialSpeakerTrackedClientCapacity = 32,
    kSpatialSpeakerTrackedBundleIDLength = 128
};

static const char *kSpatialSpeakerDiagnosticsBuildTag = "diag-2026-05-09-r10-peekread";

typedef struct SpatialSpeakerTrackedClient
{
    UInt32 clientID;
    pid_t processID;
    UInt32 ioStartCount;
    UInt32 readInputCount;
    UInt32 hasWrittenAudio;
    UInt32 hasLoggedWriterAbsence;
    UInt32 isInputOnly;
    UInt32 hasLoggedReadInputZeroMismatch;
    UInt32 hasLoggedMissingStartIO;
    UInt32 hasLoggedMissingReadInputAfterStartIO;
    char bundleID[kSpatialSpeakerTrackedBundleIDLength];
} SpatialSpeakerTrackedClient;

typedef struct SpatialSpeakerDriver
{
    AudioServerPlugInDriverInterface *mInterface;
    UInt32 mRefCount;
} SpatialSpeakerDriver;

typedef struct SpatialSpeakerState
{
    AudioServerPlugInHostRef host;
    atomic_uint ioStartCount;
    atomic_uint_fast64_t ioSeed;
    UInt64 startHostTime;
    Float64 startSampleTime;
    pthread_mutex_t mutex;
    Float32 ringBuffer[kSpatialSpeakerRingBufferFrames * kSpatialSpeakerChannelCount];
    /* Ring buffer: WriteMix pushes interleaved stereo frames; ReadInput peeks the
     * newest samples without consuming (see SpatialSpeaker_CopyLatestInput). Peeking
     * avoids partitioning one writer's frames across multiple HAL capture clients,
     * which used to sound like severe distortion. readIndex/stored advance only on
     * overflow drops in StoreOutput. lastFrameCount mirrors ringStoredFrames for logs. */
    UInt32 lastFrameCount;
    UInt32 ringWriteIndex; /* next write position, in frames */
    UInt32 ringReadIndex;  /* oldest retained frame index when stored > 0 */
    UInt32 ringStoredFrames; /* frames currently in the ring */
    UInt64 ringWriteCount; /* total writes since boot, for diagnostics */
    UInt64 ringReadCount;  /* total ReadInput peeks since boot, for diagnostics */
    SpatialSpeakerTrackedClient trackedClients[kSpatialSpeakerTrackedClientCapacity];
    UInt32 lastWriterClientID;
    pid_t lastWriterProcessID;
    Float32 lastNonZeroPeak;
    UInt32 lastWriteFrameCount;
    UInt64 writeMixSequence;
    UInt32 spatialReadInputCallCount;
    UInt32 hasLoggedMissingSpatialReadAfterWrite;
    char lastWriterBundleID[kSpatialSpeakerTrackedBundleIDLength];
} SpatialSpeakerState;

static HRESULT SpatialSpeaker_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG SpatialSpeaker_AddRef(void *inDriver);
static ULONG SpatialSpeaker_Release(void *inDriver);
static OSStatus SpatialSpeaker_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus SpatialSpeaker_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID);
static OSStatus SpatialSpeaker_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus SpatialSpeaker_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus SpatialSpeaker_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus SpatialSpeaker_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static OSStatus SpatialSpeaker_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static Boolean SpatialSpeaker_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress);
static OSStatus SpatialSpeaker_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable);
static OSStatus SpatialSpeaker_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize);
static OSStatus SpatialSpeaker_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData);
static OSStatus SpatialSpeaker_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData);
static OSStatus SpatialSpeaker_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus SpatialSpeaker_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus SpatialSpeaker_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus SpatialSpeaker_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace);
static OSStatus SpatialSpeaker_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static OSStatus SpatialSpeaker_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer);
static OSStatus SpatialSpeaker_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static UInt32 SpatialSpeaker_StreamObjectCountForScope(AudioObjectPropertyScope scope);

static AudioServerPlugInDriverInterface gSpatialSpeakerInterface =
{
    NULL,
    SpatialSpeaker_QueryInterface,
    SpatialSpeaker_AddRef,
    SpatialSpeaker_Release,
    SpatialSpeaker_Initialize,
    SpatialSpeaker_CreateDevice,
    SpatialSpeaker_DestroyDevice,
    SpatialSpeaker_AddDeviceClient,
    SpatialSpeaker_RemoveDeviceClient,
    SpatialSpeaker_PerformDeviceConfigurationChange,
    SpatialSpeaker_AbortDeviceConfigurationChange,
    SpatialSpeaker_HasProperty,
    SpatialSpeaker_IsPropertySettable,
    SpatialSpeaker_GetPropertyDataSize,
    SpatialSpeaker_GetPropertyData,
    SpatialSpeaker_SetPropertyData,
    SpatialSpeaker_StartIO,
    SpatialSpeaker_StopIO,
    SpatialSpeaker_GetZeroTimeStamp,
    SpatialSpeaker_WillDoIOOperation,
    SpatialSpeaker_BeginIOOperation,
    SpatialSpeaker_DoIOOperation,
    SpatialSpeaker_EndIOOperation
};

static SpatialSpeakerDriver gSpatialSpeakerDriver = {
    &gSpatialSpeakerInterface,
    1
};

static SpatialSpeakerState gSpatialSpeakerState = {
    .host = NULL,
    .ioStartCount = ATOMIC_VAR_INIT(0),
    .ioSeed = ATOMIC_VAR_INIT(1),
    .startHostTime = 0,
    .startSampleTime = 0,
    .mutex = PTHREAD_MUTEX_INITIALIZER,
    .ringBuffer = {0},
    .lastFrameCount = 0,
    .ringWriteIndex = 0,
    .ringReadIndex = 0,
    .ringStoredFrames = 0,
    .ringWriteCount = 0,
    .ringReadCount = 0,
    .trackedClients = {{0}},
    .lastWriterClientID = 0,
    .lastWriterProcessID = 0,
    .lastNonZeroPeak = 0,
    .lastWriteFrameCount = 0,
    .writeMixSequence = 0,
    .spatialReadInputCallCount = 0,
    .hasLoggedMissingSpatialReadAfterWrite = 0,
    .lastWriterBundleID = {0}
};

static const CFStringRef kSpatialSpeakerName = CFSTR("Spatial Speaker");
static const CFStringRef kSpatialSpeakerManufacturer = CFSTR("Spatial");
static const CFStringRef kSpatialSpeakerUID = CFSTR("com.spatial.app.driver.speaker");
static const CFStringRef kSpatialSpeakerModelUID = CFSTR("com.spatial.app.driver.speaker.model");
static const CFStringRef kSpatialSpeakerInputName = CFSTR("Spatial Speaker Input");
static const CFStringRef kSpatialSpeakerOutputName = CFSTR("Spatial Speaker Output");
static const CFStringRef kSpatialSpeakerBundleID = CFSTR("com.spatial.app.driver.speaker");
static os_log_t gSpatialSpeakerLog;

static const char *SpatialSpeaker_IOOperationName(UInt32 operationID)
{
    switch (operationID) {
        case kAudioServerPlugInIOOperationReadInput:
            return "ReadInput";
        case kAudioServerPlugInIOOperationWriteMix:
            return "WriteMix";
        default:
            return "UnknownIOOperation";
    }
}

static const char *SpatialSpeaker_ScopeName(AudioObjectPropertyScope scope)
{
    switch (scope) {
        case kAudioObjectPropertyScopeGlobal:
            return "global";
        case kAudioObjectPropertyScopeInput:
            return "input";
        case kAudioObjectPropertyScopeOutput:
            return "output";
        default:
            return "unknown";
    }
}

static const char *SpatialSpeaker_ObjectName(AudioObjectID objectID)
{
    switch (objectID) {
        case kAudioObjectPlugInObject:
            return "plugin";
        case kSpatialSpeakerDeviceObjectID:
            return "device";
        case kSpatialSpeakerInputStreamObjectID:
            return "inputStream";
        case kSpatialSpeakerOutputStreamObjectID:
            return "outputStream";
        default:
            return "unknown";
    }
}

static const char *SpatialSpeaker_SelectorName(AudioObjectPropertySelector selector)
{
    switch (selector) {
        case kAudioObjectPropertyBaseClass: return "kAudioObjectPropertyBaseClass";
        case kAudioObjectPropertyClass: return "kAudioObjectPropertyClass";
        case kAudioObjectPropertyOwner: return "kAudioObjectPropertyOwner";
        case kAudioObjectPropertyName: return "kAudioObjectPropertyName";
        case kAudioObjectPropertyManufacturer: return "kAudioObjectPropertyManufacturer";
        case kAudioObjectPropertyOwnedObjects: return "kAudioObjectPropertyOwnedObjects";
        case kAudioObjectPropertyControlList: return "kAudioObjectPropertyControlList";
        case kAudioObjectPropertyModelName: return "kAudioObjectPropertyModelName";
        case kAudioPlugInPropertyBundleID: return "kAudioPlugInPropertyBundleID";
        case kAudioPlugInPropertyDeviceList: return "kAudioPlugInPropertyDeviceList";
        case kAudioPlugInPropertyTranslateUIDToDevice: return "kAudioPlugInPropertyTranslateUIDToDevice";
        case kAudioPlugInPropertyResourceBundle: return "kAudioPlugInPropertyResourceBundle";
        case kAudioDevicePropertyConfigurationApplication: return "kAudioDevicePropertyConfigurationApplication";
        case kAudioDevicePropertyDeviceUID: return "kAudioDevicePropertyDeviceUID";
        case kAudioDevicePropertyModelUID: return "kAudioDevicePropertyModelUID";
        case kAudioDevicePropertyTransportType: return "kAudioDevicePropertyTransportType";
        case kAudioDevicePropertyRelatedDevices: return "kAudioDevicePropertyRelatedDevices";
        case kAudioDevicePropertyClockDomain: return "kAudioDevicePropertyClockDomain";
        case kAudioDevicePropertyDeviceIsAlive: return "kAudioDevicePropertyDeviceIsAlive";
        case kAudioDevicePropertyDeviceIsRunning: return "kAudioDevicePropertyDeviceIsRunning";
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: return "kAudioDevicePropertyDeviceCanBeDefaultDevice";
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: return "kAudioDevicePropertyDeviceCanBeDefaultSystemDevice";
        case kAudioDevicePropertyIsHidden: return "kAudioDevicePropertyIsHidden";
        case kAudioDevicePropertyLatency: return "kAudioDevicePropertyLatency/kAudioStreamPropertyLatency";
        case kAudioDevicePropertyStreams: return "kAudioDevicePropertyStreams";
        case kAudioDevicePropertySafetyOffset: return "kAudioDevicePropertySafetyOffset";
        case kAudioDevicePropertyNominalSampleRate: return "kAudioDevicePropertyNominalSampleRate";
        case kAudioDevicePropertyAvailableNominalSampleRates: return "kAudioDevicePropertyAvailableNominalSampleRates";
        case kAudioDevicePropertyPreferredChannelsForStereo: return "kAudioDevicePropertyPreferredChannelsForStereo";
        case kAudioDevicePropertyZeroTimeStampPeriod: return "kAudioDevicePropertyZeroTimeStampPeriod";
        case kAudioDevicePropertyClockIsStable: return "kAudioDevicePropertyClockIsStable";
        case kAudioDevicePropertyClockAlgorithm: return "kAudioDevicePropertyClockAlgorithm";
        case kAudioDevicePropertyBufferFrameSize: return "kAudioDevicePropertyBufferFrameSize";
        case kAudioDevicePropertyBufferFrameSizeRange: return "kAudioDevicePropertyBufferFrameSizeRange";
        case kAudioDevicePropertyStreamConfiguration: return "kAudioDevicePropertyStreamConfiguration";
        case kAudioStreamPropertyIsActive: return "kAudioStreamPropertyIsActive";
        case kAudioStreamPropertyDirection: return "kAudioStreamPropertyDirection";
        case kAudioStreamPropertyTerminalType: return "kAudioStreamPropertyTerminalType";
        case kAudioStreamPropertyStartingChannel: return "kAudioStreamPropertyStartingChannel";
        case kAudioStreamPropertyVirtualFormat: return "kAudioStreamPropertyVirtualFormat";
        case kAudioStreamPropertyAvailableVirtualFormats: return "kAudioStreamPropertyAvailableVirtualFormats";
        case kAudioStreamPropertyPhysicalFormat: return "kAudioStreamPropertyPhysicalFormat";
        case kAudioStreamPropertyAvailablePhysicalFormats: return "kAudioStreamPropertyAvailablePhysicalFormats";
        default: return "unknownSelector";
    }
}

static void SpatialSpeaker_LogUnsupportedProperty(const char *stage, AudioObjectID objectID, const AudioObjectPropertyAddress *inAddress)
{
    if (gSpatialSpeakerLog == NULL || inAddress == NULL) {
        return;
    }

    // Use debug level so log stream --level error stays uncluttered.
    os_log_debug(
        gSpatialSpeakerLog,
        "%{public}s unsupported property object=%{public}s(%u) selector=%{public}s(%u) scope=%u element=%u",
        stage,
        SpatialSpeaker_ObjectName(objectID),
        objectID,
        SpatialSpeaker_SelectorName(inAddress->mSelector),
        inAddress->mSelector,
        inAddress->mScope,
        inAddress->mElement
    );
}

static AudioStreamBasicDescription SpatialSpeaker_StreamFormat(void)
{
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    format.mSampleRate = kSpatialSpeakerNominalSampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = sizeof(Float32) * kSpatialSpeakerChannelCount;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = sizeof(Float32) * kSpatialSpeakerChannelCount;
    format.mChannelsPerFrame = kSpatialSpeakerChannelCount;
    format.mBitsPerChannel = sizeof(Float32) * 8;
    return format;
}

static AudioStreamRangedDescription SpatialSpeaker_RangedFormat(void)
{
    AudioStreamRangedDescription ranged;
    memset(&ranged, 0, sizeof(ranged));
    ranged.mFormat = SpatialSpeaker_StreamFormat();
    ranged.mSampleRateRange.mMinimum = kSpatialSpeakerNominalSampleRate;
    ranged.mSampleRateRange.mMaximum = kSpatialSpeakerNominalSampleRate;
    return ranged;
}

static Boolean SpatialSpeaker_InputTopologyIsValid(UInt32 *outInputStreamCount, UInt32 *outOutputStreamCount, UInt32 *outInputChannelCount, UInt32 *outOutputChannelCount)
{
    UInt32 inputStreamCount = SpatialSpeaker_StreamObjectCountForScope(kAudioObjectPropertyScopeInput);
    UInt32 outputStreamCount = SpatialSpeaker_StreamObjectCountForScope(kAudioObjectPropertyScopeOutput);
    UInt32 inputChannelCount = kSpatialSpeakerChannelCount;
    UInt32 outputChannelCount = kSpatialSpeakerChannelCount;
    AudioStreamBasicDescription format = SpatialSpeaker_StreamFormat();

    Boolean valid = inputStreamCount == 1U
        && outputStreamCount == 1U
        && inputChannelCount > 0U
        && outputChannelCount > 0U
        && format.mChannelsPerFrame == kSpatialSpeakerChannelCount
        && format.mBytesPerFrame == sizeof(Float32) * kSpatialSpeakerChannelCount;

    if (outInputStreamCount != NULL) *outInputStreamCount = inputStreamCount;
    if (outOutputStreamCount != NULL) *outOutputStreamCount = outputStreamCount;
    if (outInputChannelCount != NULL) *outInputChannelCount = inputChannelCount;
    if (outOutputChannelCount != NULL) *outOutputChannelCount = outputChannelCount;
    return valid;
}

static void SpatialSpeaker_LogTopologySummary(const char *stage)
{
    UInt32 inputStreamCount = 0;
    UInt32 outputStreamCount = 0;
    UInt32 inputChannelCount = 0;
    UInt32 outputChannelCount = 0;
    Boolean valid = SpatialSpeaker_InputTopologyIsValid(&inputStreamCount, &outputStreamCount, &inputChannelCount, &outputChannelCount);
    AudioStreamBasicDescription format = SpatialSpeaker_StreamFormat();

    os_log_error(
        gSpatialSpeakerLog,
        "DIAG Topology[%{public}s][%{public}s] inputStreamObject=%u outputStreamObject=%u inputStreams=%u outputStreams=%u inputChannels=%u outputChannels=%u sampleRate=%.0f bytesPerFrame=%u channelsPerFrame=%u interleaved=%{public}s valid=%{public}s",
        kSpatialSpeakerDiagnosticsBuildTag,
        stage,
        kSpatialSpeakerInputStreamObjectID,
        kSpatialSpeakerOutputStreamObjectID,
        inputStreamCount,
        outputStreamCount,
        inputChannelCount,
        outputChannelCount,
        format.mSampleRate,
        format.mBytesPerFrame,
        format.mChannelsPerFrame,
        (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0 ? "false" : "true",
        valid ? "true" : "false"
    );
}

static UInt32 SpatialSpeaker_StreamConfigurationDataSize(void)
{
    return (UInt32)(offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer));
}

static void SpatialSpeaker_CopyBundleID(CFStringRef bundleID, char *destination, size_t destinationSize)
{
    if (destination == NULL || destinationSize == 0) {
        return;
    }

    destination[0] = '\0';
    if (bundleID == NULL) {
        return;
    }

    if (!CFStringGetCString(bundleID, destination, destinationSize, kCFStringEncodingUTF8)) {
        snprintf(destination, destinationSize, "<unprintable>");
    }
}

static Boolean SpatialSpeaker_BundleHasPrefix(const char *bundleID, const char *prefix)
{
    if (bundleID == NULL || prefix == NULL) {
        return false;
    }

    size_t prefixLength = strlen(prefix);
    return strncmp(bundleID, prefix, prefixLength) == 0;
}

static Boolean SpatialSpeaker_ShouldTreatClientAsInputOnly(const char *bundleID)
{
    return SpatialSpeaker_BundleHasPrefix(bundleID, "com.spatial.app");
}

static const char *SpatialSpeaker_StreamName(AudioObjectID streamObjectID)
{
    switch (streamObjectID) {
        case kSpatialSpeakerInputStreamObjectID:
            return "input";
        case kSpatialSpeakerOutputStreamObjectID:
            return "output";
        default:
            return "unknown";
    }
}

static Boolean SpatialSpeaker_IsStreamObject(AudioObjectID objectID)
{
    return objectID == kSpatialSpeakerInputStreamObjectID || objectID == kSpatialSpeakerOutputStreamObjectID;
}

static Boolean SpatialSpeaker_QualifierHasClass(UInt32 inQualifierDataSize, const void *inQualifierData, AudioClassID classID);

static UInt32 SpatialSpeaker_DeviceOwnedObjectCount(UInt32 inQualifierDataSize, const void *inQualifierData)
{
    return SpatialSpeaker_QualifierHasClass(inQualifierDataSize, inQualifierData, kAudioStreamClassID) ? 2U : 0U;
}

static UInt32 SpatialSpeaker_PlugInOwnedObjectCount(UInt32 inQualifierDataSize, const void *inQualifierData)
{
    return SpatialSpeaker_QualifierHasClass(inQualifierDataSize, inQualifierData, kAudioDeviceClassID) ? 1U : 0U;
}

static UInt32 SpatialSpeaker_StreamObjectCountForScope(AudioObjectPropertyScope scope)
{
    switch (scope) {
        case kAudioObjectPropertyScopeGlobal:
            return 2U;
        case kAudioObjectPropertyScopeInput:
        case kAudioObjectPropertyScopeOutput:
            return 1U;
        default:
            return 0U;
    }
}

static UInt32 SpatialSpeaker_CopyPlugInOwnedObjects(UInt32 inQualifierDataSize, const void *inQualifierData, AudioObjectID *outData)
{
    UInt32 count = SpatialSpeaker_PlugInOwnedObjectCount(inQualifierDataSize, inQualifierData);
    if (count == 1U && outData != NULL) {
        outData[0] = kSpatialSpeakerDeviceObjectID;
    }
    return count;
}

static UInt32 SpatialSpeaker_CopyDeviceOwnedObjects(UInt32 inQualifierDataSize, const void *inQualifierData, AudioObjectID *outData)
{
    UInt32 count = SpatialSpeaker_DeviceOwnedObjectCount(inQualifierDataSize, inQualifierData);
    if (count == 2U && outData != NULL) {
        outData[0] = kSpatialSpeakerInputStreamObjectID;
        outData[1] = kSpatialSpeakerOutputStreamObjectID;
    }
    return count;
}

static UInt32 SpatialSpeaker_CopyDeviceStreams(AudioObjectPropertyScope scope, AudioObjectID *outData)
{
    UInt32 count = 0;

    if (scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeInput) {
        if (outData != NULL) {
            outData[count] = kSpatialSpeakerInputStreamObjectID;
        }
        ++count;
    }

    if (scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeOutput) {
        if (outData != NULL) {
            outData[count] = kSpatialSpeakerOutputStreamObjectID;
        }
        ++count;
    }

    return count;
}

static UInt64 SpatialSpeaker_HostTicksFromSeconds(Float64 seconds)
{
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    long double nanos = (long double)seconds * 1000000000.0L;
    return (UInt64)((nanos * (long double)timebase.denom) / (long double)timebase.numer);
}

static Float64 SpatialSpeaker_SecondsFromHostTicks(UInt64 hostTicks)
{
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    long double nanos = ((long double)hostTicks * (long double)timebase.numer) / (long double)timebase.denom;
    return (Float64)(nanos / 1000000000.0L);
}

static SpatialSpeakerTrackedClient *SpatialSpeaker_FindTrackedClient(UInt32 clientID)
{
    for (UInt32 i = 0; i < kSpatialSpeakerTrackedClientCapacity; ++i) {
        if (gSpatialSpeakerState.trackedClients[i].clientID == clientID) {
            return &gSpatialSpeakerState.trackedClients[i];
        }
    }
    return NULL;
}

static SpatialSpeakerTrackedClient *SpatialSpeaker_EnsureTrackedClient(const AudioServerPlugInClientInfo *inClientInfo)
{
    if (inClientInfo == NULL) {
        return NULL;
    }

    SpatialSpeakerTrackedClient *existing = SpatialSpeaker_FindTrackedClient(inClientInfo->mClientID);
    if (existing != NULL) {
        existing->processID = inClientInfo->mProcessID;
        SpatialSpeaker_CopyBundleID(inClientInfo->mBundleID, existing->bundleID, sizeof(existing->bundleID));
        return existing;
    }

    for (UInt32 i = 0; i < kSpatialSpeakerTrackedClientCapacity; ++i) {
        if (gSpatialSpeakerState.trackedClients[i].clientID == 0) {
            SpatialSpeakerTrackedClient *slot = &gSpatialSpeakerState.trackedClients[i];
            memset(slot, 0, sizeof(*slot));
            slot->clientID = inClientInfo->mClientID;
            slot->processID = inClientInfo->mProcessID;
            SpatialSpeaker_CopyBundleID(inClientInfo->mBundleID, slot->bundleID, sizeof(slot->bundleID));
            return slot;
        }
    }

    // All slots occupied — this client will NOT have isInputOnly set. Log so we know.
    char bundleID[kSpatialSpeakerTrackedBundleIDLength];
    SpatialSpeaker_CopyBundleID(inClientInfo->mBundleID, bundleID, sizeof(bundleID));
    os_log_error(gSpatialSpeakerLog, "EnsureTrackedClient OVERFLOW: all %u slots occupied, clientID=%u bundleID=%{public}s will not be tracked (WriteMix NOT suppressed)", kSpatialSpeakerTrackedClientCapacity, inClientInfo->mClientID, bundleID);
    return NULL;
}

static Boolean SpatialSpeaker_IsInputOnlyClient(UInt32 clientID)
{
    Boolean isInputOnly = false;
    pthread_mutex_lock(&gSpatialSpeakerState.mutex);
    SpatialSpeakerTrackedClient *client = SpatialSpeaker_FindTrackedClient(clientID);
    isInputOnly = client != NULL && client->isInputOnly != 0;
    pthread_mutex_unlock(&gSpatialSpeakerState.mutex);
    return isInputOnly;
}

static Boolean SpatialSpeaker_HasActiveExternalWriter(void)
{
    Boolean found = false;
    pthread_mutex_lock(&gSpatialSpeakerState.mutex);
    for (UInt32 i = 0; i < kSpatialSpeakerTrackedClientCapacity; ++i) {
        SpatialSpeakerTrackedClient *client = &gSpatialSpeakerState.trackedClients[i];
        if (client->clientID != 0 && client->isInputOnly == 0 && client->ioStartCount > 0) {
            found = true;
            break;
        }
    }
    pthread_mutex_unlock(&gSpatialSpeakerState.mutex);
    return found;
}

/* Copy the newest loopback frames without consuming. Core Audio may call ReadInput
 * once per capture client per cycle; a consumer ring would split one writer's
 * frames across those readers and sound badly distorted. Peeking the tail keeps
 * every tap aligned on the same recent mix. Empty ring → silence. */
static void SpatialSpeaker_CopyLatestInput(UInt32 frameCount, Float32 *outBuffer)
{
    if (frameCount == 0) return;

    pthread_mutex_lock(&gSpatialSpeakerState.mutex);

    UInt32 stored = gSpatialSpeakerState.ringStoredFrames;
    UInt32 readIdx = gSpatialSpeakerState.ringReadIndex;
    const UInt32 cap = kSpatialSpeakerRingBufferFrames;
    UInt32 framesToCopy = stored < frameCount ? stored : frameCount;

    if (framesToCopy > 0) {
        /* Invariant when stored > 0: (readIdx + stored) % cap == ringWriteIndex. */
        UInt32 startFrame = (readIdx + stored - framesToCopy + cap) % cap;

        UInt32 firstChunk = framesToCopy;
        if (startFrame + firstChunk > cap) {
            firstChunk = cap - startFrame;
        }
        UInt32 secondChunk = framesToCopy - firstChunk;

        memcpy(
            outBuffer,
            &gSpatialSpeakerState.ringBuffer[startFrame * kSpatialSpeakerChannelCount],
            firstChunk * kSpatialSpeakerChannelCount * sizeof(Float32)
        );
        if (secondChunk > 0) {
            memcpy(
                outBuffer + firstChunk * kSpatialSpeakerChannelCount,
                &gSpatialSpeakerState.ringBuffer[0],
                secondChunk * kSpatialSpeakerChannelCount * sizeof(Float32)
            );
        }

        gSpatialSpeakerState.ringReadCount += 1;
    }

    pthread_mutex_unlock(&gSpatialSpeakerState.mutex);

    if (framesToCopy < frameCount) {
        memset(
            outBuffer + framesToCopy * kSpatialSpeakerChannelCount,
            0,
            (frameCount - framesToCopy) * kSpatialSpeakerChannelCount * sizeof(Float32)
        );
    }
}

static void SpatialSpeaker_StoreOutput(UInt32 frameCount, const Float32 *buffer)
{
    if (frameCount == 0) return;

    UInt32 incoming = frameCount;
    /* If the producer ever delivers more than capacity in one call, drop the
     * oldest portion of the burst so the most-recent audio survives. */
    if (incoming > kSpatialSpeakerRingBufferFrames) {
        buffer += (incoming - kSpatialSpeakerRingBufferFrames) * kSpatialSpeakerChannelCount;
        incoming = kSpatialSpeakerRingBufferFrames;
    }

    pthread_mutex_lock(&gSpatialSpeakerState.mutex);

    /* If incoming would exceed remaining capacity, advance readIndex first
     * (drop the oldest unread frames) and account for the loss. */
    UInt32 stored = gSpatialSpeakerState.ringStoredFrames;
    if (stored + incoming > kSpatialSpeakerRingBufferFrames) {
        UInt32 overflow = (stored + incoming) - kSpatialSpeakerRingBufferFrames;
        gSpatialSpeakerState.ringReadIndex = (gSpatialSpeakerState.ringReadIndex + overflow) % kSpatialSpeakerRingBufferFrames;
        stored -= overflow;
    }

    UInt32 writeIdx = gSpatialSpeakerState.ringWriteIndex;
    UInt32 firstChunk = incoming;
    if (writeIdx + firstChunk > kSpatialSpeakerRingBufferFrames) {
        firstChunk = kSpatialSpeakerRingBufferFrames - writeIdx;
    }
    UInt32 secondChunk = incoming - firstChunk;

    memcpy(
        &gSpatialSpeakerState.ringBuffer[writeIdx * kSpatialSpeakerChannelCount],
        buffer,
        firstChunk * kSpatialSpeakerChannelCount * sizeof(Float32)
    );
    if (secondChunk > 0) {
        memcpy(
            &gSpatialSpeakerState.ringBuffer[0],
            buffer + firstChunk * kSpatialSpeakerChannelCount,
            secondChunk * kSpatialSpeakerChannelCount * sizeof(Float32)
        );
    }

    gSpatialSpeakerState.ringWriteIndex = (writeIdx + incoming) % kSpatialSpeakerRingBufferFrames;
    gSpatialSpeakerState.ringStoredFrames = stored + incoming;
    gSpatialSpeakerState.lastFrameCount = gSpatialSpeakerState.ringStoredFrames;
    gSpatialSpeakerState.ringWriteCount += 1;

    pthread_mutex_unlock(&gSpatialSpeakerState.mutex);
}

static CFTypeRef SpatialSpeaker_CopyPropertyString(CFStringRef value)
{
    return CFRetain(value);
}

static Boolean SpatialSpeaker_QualifierHasClass(UInt32 inQualifierDataSize, const void *inQualifierData, AudioClassID classID)
{
    if (inQualifierDataSize == 0 || inQualifierData == NULL) {
        return true;
    }

    UInt32 classCount = inQualifierDataSize / sizeof(AudioClassID);
    const AudioClassID *classes = (const AudioClassID *)inQualifierData;
    for (UInt32 index = 0; index < classCount; ++index) {
        if (classes[index] == classID || classes[index] == kAudioObjectClassID) {
            return true;
        }
    }

    return false;
}

static HRESULT SpatialSpeaker_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface)
{
    if (outInterface == NULL) {
        return E_POINTER;
    }

    CFUUIDRef requestedUUID = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requestedUUID == NULL) {
        *outInterface = NULL;
        return E_NOINTERFACE;
    }

    Boolean supported = CFEqual(requestedUUID, IUnknownUUID) || CFEqual(requestedUUID, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(requestedUUID);

    if (!supported) {
        *outInterface = NULL;
        return E_NOINTERFACE;
    }

    SpatialSpeaker_AddRef(inDriver);
    *outInterface = inDriver;
    return S_OK;
}

static ULONG SpatialSpeaker_AddRef(void *inDriver)
{
    SpatialSpeakerDriver *driver = (SpatialSpeakerDriver *)inDriver;
    return ++driver->mRefCount;
}

static ULONG SpatialSpeaker_Release(void *inDriver)
{
    SpatialSpeakerDriver *driver = (SpatialSpeakerDriver *)inDriver;
    if (driver->mRefCount > 1) {
        --driver->mRefCount;
    }
    return driver->mRefCount;
}

static OSStatus SpatialSpeaker_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    (void)inDriver;
    gSpatialSpeakerLog = os_log_create("com.spatial.app.driver.speaker", "AudioServerPlugIn");
    gSpatialSpeakerState.host = inHost;
    gSpatialSpeakerState.startHostTime = mach_absolute_time();
    gSpatialSpeakerState.startSampleTime = 0;
    os_log_error(gSpatialSpeakerLog, "DIAG SpatialSpeaker_Initialize build=%{public}s host=%p", kSpatialSpeakerDiagnosticsBuildTag, inHost);
    SpatialSpeaker_LogTopologySummary("initialize");
    return kAudioHardwareNoError;
}

static OSStatus SpatialSpeaker_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID)
{
    (void)inDriver;
    (void)inDescription;
    (void)inClientInfo;
    (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus SpatialSpeaker_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus SpatialSpeaker_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo)
{
    (void)inDriver;
    if (inDeviceObjectID != kSpatialSpeakerDeviceObjectID) return kAudioHardwareBadDeviceError;
    if (inClientInfo) {
        char bundleID[kSpatialSpeakerTrackedBundleIDLength];
        SpatialSpeaker_CopyBundleID(inClientInfo->mBundleID, bundleID, sizeof(bundleID));
        Boolean isInputOnly = SpatialSpeaker_ShouldTreatClientAsInputOnly(bundleID);

        pthread_mutex_lock(&gSpatialSpeakerState.mutex);
        SpatialSpeakerTrackedClient *client = SpatialSpeaker_EnsureTrackedClient(inClientInfo);
        if (client != NULL) {
            client->isInputOnly = isInputOnly ? 1U : 0U;
            client->hasLoggedReadInputZeroMismatch = 0;
            client->readInputCount = 0;
            client->hasLoggedMissingStartIO = 0;
            client->hasLoggedMissingReadInputAfterStartIO = 0;
        }
        pthread_mutex_unlock(&gSpatialSpeakerState.mutex);

        os_log_error(gSpatialSpeakerLog, "AddDeviceClient[%{public}s] clientID=%u pid=%d bundleID=%{public}s role=%{public}s",
            kSpatialSpeakerDiagnosticsBuildTag, inClientInfo->mClientID, inClientInfo->mProcessID, bundleID, isInputOnly ? "capture-only" : "writer-candidate");
        if (isInputOnly) {
            os_log_error(gSpatialSpeakerLog, "AddDeviceClient[%{public}s]: marked clientID=%u as input-only (WriteMix suppressed)", kSpatialSpeakerDiagnosticsBuildTag, inClientInfo->mClientID);
            SpatialSpeaker_LogTopologySummary("add-capture-client");
        }
    }
    return kAudioHardwareNoError;
}

static OSStatus SpatialSpeaker_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo)
{
    (void)inDriver;
    if (inDeviceObjectID != kSpatialSpeakerDeviceObjectID) return kAudioHardwareBadDeviceError;
    if (inClientInfo) {
        pthread_mutex_lock(&gSpatialSpeakerState.mutex);
        for (UInt32 i = 0; i < kSpatialSpeakerTrackedClientCapacity; i++) {
            if (gSpatialSpeakerState.trackedClients[i].clientID == inClientInfo->mClientID) {
                memset(&gSpatialSpeakerState.trackedClients[i], 0, sizeof(gSpatialSpeakerState.trackedClients[i]));
                break;
            }
        }
        pthread_mutex_unlock(&gSpatialSpeakerState.mutex);

        os_log_error(gSpatialSpeakerLog, "RemoveDeviceClient clientID=%u pid=%d",
            inClientInfo->mClientID, inClientInfo->mProcessID);
    }
    return kAudioHardwareNoError;
}

static OSStatus SpatialSpeaker_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo)
{
    (void)inDriver;
    (void)inChangeAction;
    (void)inChangeInfo;
    return inDeviceObjectID == kSpatialSpeakerDeviceObjectID ? kAudioHardwareNoError : kAudioHardwareBadDeviceError;
}

static OSStatus SpatialSpeaker_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo)
{
    (void)inDriver;
    (void)inChangeAction;
    (void)inChangeInfo;
    return inDeviceObjectID == kSpatialSpeakerDeviceObjectID ? kAudioHardwareNoError : kAudioHardwareBadDeviceError;
}

static Boolean SpatialSpeaker_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress)
{
    (void)inDriver;
    (void)inClientProcessID;

    switch (inObjectID) {
        case kAudioObjectPlugInObject:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyBundleID:
                case kAudioPlugInPropertyDeviceList:
                case kAudioPlugInPropertyTranslateUIDToDevice:
                case kAudioPlugInPropertyResourceBundle:
                    return true;
                default:
                    return false;
            }

        case kSpatialSpeakerDeviceObjectID:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyModelName:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioDevicePropertyConfigurationApplication:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyRelatedDevices:
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyIsHidden:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertyStreams:
                case kAudioObjectPropertyControlList:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyNominalSampleRate:
                case kAudioDevicePropertyAvailableNominalSampleRates:
                case kAudioDevicePropertyPreferredChannelsForStereo:
                case kAudioDevicePropertyZeroTimeStampPeriod:
                case kAudioDevicePropertyClockIsStable:
                case kAudioDevicePropertyClockAlgorithm:
                case kAudioDevicePropertyBufferFrameSize:
                case kAudioDevicePropertyBufferFrameSizeRange:
                case kAudioDevicePropertyStreamConfiguration:
                    return true;
                default:
                    return false;
            }

        case kSpatialSpeakerInputStreamObjectID:
        case kSpatialSpeakerOutputStreamObjectID:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyName:
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyPhysicalFormat:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    return true;
                default:
                    return false;
            }

        default:
            SpatialSpeaker_LogUnsupportedProperty("HasProperty", inObjectID, inAddress);
            return false;
    }
}

static OSStatus SpatialSpeaker_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable)
{
    (void)inDriver;
    (void)inClientProcessID;

    if (outIsSettable == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    *outIsSettable = false;

    if (inObjectID == kSpatialSpeakerDeviceObjectID) {
        switch (inAddress->mSelector) {
            case kAudioDevicePropertyBufferFrameSize:
            case kAudioDevicePropertyNominalSampleRate:
                *outIsSettable = false;
                return kAudioHardwareNoError;
            default:
                break;
        }
    }

    if (SpatialSpeaker_IsStreamObject(inObjectID)) {
        switch (inAddress->mSelector) {
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                *outIsSettable = false;
                return kAudioHardwareNoError;
            default:
                break;
        }
    }

    return SpatialSpeaker_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress) ? kAudioHardwareNoError : kAudioHardwareUnknownPropertyError;
}

static OSStatus SpatialSpeaker_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize)
{
    (void)inDriver;
    (void)inClientProcessID;
    (void)inQualifierDataSize;
    (void)inQualifierData;

    if (outDataSize == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    switch (inObjectID) {
        case kAudioObjectPlugInObject:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwner:
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyName:
                case kAudioPlugInPropertyBundleID:
                case kAudioPlugInPropertyResourceBundle:
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects:
                    *outDataSize = SpatialSpeaker_PlugInOwnedObjectCount(inQualifierDataSize, inQualifierData) * sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioPlugInPropertyDeviceList:
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioPlugInPropertyTranslateUIDToDevice:
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                default:
                    return kAudioHardwareUnknownPropertyError;
            }

        case kSpatialSpeakerDeviceObjectID:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwner:
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyIsHidden:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyZeroTimeStampPeriod:
                case kAudioDevicePropertyClockAlgorithm:
                case kAudioDevicePropertyClockIsStable:
                case kAudioDevicePropertyBufferFrameSize:
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyModelName:
                case kAudioObjectPropertyManufacturer:
                case kAudioDevicePropertyConfigurationApplication:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects:
                    *outDataSize = SpatialSpeaker_DeviceOwnedObjectCount(inQualifierDataSize, inQualifierData) * sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyRelatedDevices:
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyStreams:
                    *outDataSize = SpatialSpeaker_StreamObjectCountForScope(inAddress->mScope) * sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyControlList:
                    *outDataSize = 0;
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyNominalSampleRate:
                    *outDataSize = sizeof(Float64);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyAvailableNominalSampleRates:
                    *outDataSize = sizeof(AudioValueRange);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyPreferredChannelsForStereo:
                    *outDataSize = 2 * sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyBufferFrameSizeRange:
                    *outDataSize = sizeof(AudioValueRange);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyStreamConfiguration:
                    *outDataSize = SpatialSpeaker_StreamConfigurationDataSize();
                    return kAudioHardwareNoError;
                default:
                    return kAudioHardwareUnknownPropertyError;
            }

        case kSpatialSpeakerInputStreamObjectID:
        case kSpatialSpeakerOutputStreamObjectID:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwner:
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyName:
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                    *outDataSize = sizeof(AudioStreamBasicDescription);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    *outDataSize = sizeof(AudioStreamRangedDescription);
                    return kAudioHardwareNoError;
                default:
                    return kAudioHardwareUnknownPropertyError;
            }

        default:
            SpatialSpeaker_LogUnsupportedProperty("GetPropertyDataSize", inObjectID, inAddress);
            return kAudioHardwareBadObjectError;
    }
}

static OSStatus SpatialSpeaker_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData)
{
    (void)inDriver;
    (void)inClientProcessID;

    if (outData == NULL || outDataSize == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    switch (inObjectID) {
        case kAudioObjectPlugInObject:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                    *((AudioClassID *)outData) = kAudioObjectClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyClass:
                    if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                    *((AudioClassID *)outData) = kAudioPlugInClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwner:
                    if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                    *((AudioObjectID *)outData) = kAudioObjectUnknown;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyManufacturer:
                    if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                    *((CFStringRef *)outData) = SpatialSpeaker_CopyPropertyString(kSpatialSpeakerManufacturer);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyName:
                    if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                    *((CFStringRef *)outData) = SpatialSpeaker_CopyPropertyString(kSpatialSpeakerName);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects:
                {
                    UInt32 count = SpatialSpeaker_CopyPlugInOwnedObjects(inQualifierDataSize, inQualifierData, (AudioObjectID *)outData);
                    UInt32 dataSize = count * sizeof(AudioObjectID);
                    if (inDataSize < dataSize) return kAudioHardwareBadPropertySizeError;
                    *outDataSize = dataSize;
                    return kAudioHardwareNoError;
                }
                case kAudioPlugInPropertyDeviceList:
                    if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                    *((AudioObjectID *)outData) = kSpatialSpeakerDeviceObjectID;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioPlugInPropertyBundleID:
                    if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                    *((CFStringRef *)outData) = SpatialSpeaker_CopyPropertyString(kSpatialSpeakerBundleID);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioPlugInPropertyResourceBundle:
                    if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                    *((CFStringRef *)outData) = SpatialSpeaker_CopyPropertyString(CFSTR(""));
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioPlugInPropertyTranslateUIDToDevice:
                {
                    if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                    AudioObjectID translatedID = kAudioObjectUnknown;
                    if (inQualifierDataSize == sizeof(CFStringRef) && inQualifierData != NULL) {
                        CFStringRef requestedUID = *((CFStringRef const *)inQualifierData);
                        if (requestedUID != NULL && CFEqual(requestedUID, kSpatialSpeakerUID)) {
                            translatedID = kSpatialSpeakerDeviceObjectID;
                        }
                    }
                    *((AudioObjectID *)outData) = translatedID;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                }
                default:
                    SpatialSpeaker_LogUnsupportedProperty("GetPropertyData", inObjectID, inAddress);
                    return kAudioHardwareUnknownPropertyError;
            }

        case kSpatialSpeakerDeviceObjectID:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                    *((AudioClassID *)outData) = kAudioObjectClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyClass:
                    if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                    *((AudioClassID *)outData) = kAudioDeviceClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwner:
                    if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                    *((AudioObjectID *)outData) = kAudioObjectPlugInObject;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyName:
                    if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                    *((CFStringRef *)outData) = SpatialSpeaker_CopyPropertyString(kSpatialSpeakerName);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyModelName:
                    if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                    *((CFStringRef *)outData) = SpatialSpeaker_CopyPropertyString(CFSTR("Spatial Speaker Loopback"));
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyManufacturer:
                    if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                    *((CFStringRef *)outData) = SpatialSpeaker_CopyPropertyString(kSpatialSpeakerManufacturer);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects:
                {
                    AudioObjectID owned[2];
                    UInt32 count = SpatialSpeaker_CopyDeviceOwnedObjects(inQualifierDataSize, inQualifierData, owned);
                    UInt32 dataSize = count * sizeof(AudioObjectID);
                    if (inDataSize < dataSize) return kAudioHardwareBadPropertySizeError;
                    if (dataSize > 0) {
                        memcpy(outData, owned, dataSize);
                    }
                    *outDataSize = dataSize;
                    return kAudioHardwareNoError;
                }
                case kAudioDevicePropertyConfigurationApplication:
                    if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                    *((CFStringRef *)outData) = SpatialSpeaker_CopyPropertyString(CFSTR("com.apple.audio.AudioMIDISetup"));
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyDeviceUID:
                    if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                    *((CFStringRef *)outData) = SpatialSpeaker_CopyPropertyString(kSpatialSpeakerUID);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyModelUID:
                    if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                    *((CFStringRef *)outData) = SpatialSpeaker_CopyPropertyString(kSpatialSpeakerModelUID);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyTransportType:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    *((UInt32 *)outData) = kAudioDeviceTransportTypeVirtual;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyRelatedDevices:
                    if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                    *((AudioObjectID *)outData) = kSpatialSpeakerDeviceObjectID;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyClockDomain:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    *((UInt32 *)outData) = 1;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyDeviceIsAlive:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    *((UInt32 *)outData) = 1;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyDeviceIsRunning:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    *((UInt32 *)outData) = atomic_load(&gSpatialSpeakerState.ioStartCount) > 0 ? 1U : 0U;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    *((UInt32 *)outData) = (inAddress->mScope == kAudioObjectPropertyScopeInput && inAddress->mSelector == kAudioDevicePropertyDeviceCanBeDefaultSystemDevice) ? 0U : 1U;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyIsHidden:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    *((UInt32 *)outData) = 0U;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertySafetyOffset:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    *((UInt32 *)outData) = 0;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyStreams:
                {
                    static _Atomic(uint32_t) streamsLogCount = 0;
                    uint32_t n = atomic_fetch_add_explicit(&streamsLogCount, 1, memory_order_relaxed);
                    AudioObjectID streams[2];
                    UInt32 count = SpatialSpeaker_CopyDeviceStreams(inAddress->mScope, streams);
                    UInt32 dataSize = count * sizeof(AudioObjectID);
                    if (inDataSize < dataSize) return kAudioHardwareBadPropertySizeError;
                    if (dataSize > 0) {
                        memcpy(outData, streams, dataSize);
                    }
                    if (n < 8) {
                        os_log_error(gSpatialSpeakerLog, "GetPropertyData streams scope=%u count=%u first=%u second=%u", inAddress->mScope, count, count > 0 ? streams[0] : 0, count > 1 ? streams[1] : 0);
                    }
                    *outDataSize = dataSize;
                    return kAudioHardwareNoError;
                }
                case kAudioObjectPropertyControlList:
                    *outDataSize = 0;
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyNominalSampleRate:
                    if (inDataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
                    *((Float64 *)outData) = (Float64)kSpatialSpeakerNominalSampleRate;
                    *outDataSize = sizeof(Float64);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyAvailableNominalSampleRates:
                {
                    if (inDataSize < sizeof(AudioValueRange)) return kAudioHardwareBadPropertySizeError;
                    AudioValueRange range = { (Float64)kSpatialSpeakerNominalSampleRate, (Float64)kSpatialSpeakerNominalSampleRate };
                    memcpy(outData, &range, sizeof(range));
                    *outDataSize = sizeof(range);
                    return kAudioHardwareNoError;
                }
                case kAudioDevicePropertyPreferredChannelsForStereo:
                {
                    UInt32 channels[2] = {1, 2};
                    if (inDataSize < sizeof(channels)) return kAudioHardwareBadPropertySizeError;
                    memcpy(outData, channels, sizeof(channels));
                    *outDataSize = sizeof(channels);
                    return kAudioHardwareNoError;
                }
                case kAudioDevicePropertyZeroTimeStampPeriod:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    *((UInt32 *)outData) = kSpatialSpeakerZeroTimestampPeriod;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyClockAlgorithm:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    *((UInt32 *)outData) = kAudioDeviceClockAlgorithmRaw;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyClockIsStable:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    *((UInt32 *)outData) = 1;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyBufferFrameSize:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    *((UInt32 *)outData) = kSpatialSpeakerBufferFrameSize;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyBufferFrameSizeRange:
                {
                    if (inDataSize < sizeof(AudioValueRange)) return kAudioHardwareBadPropertySizeError;
                    AudioValueRange range = { (Float64)kSpatialSpeakerBufferFrameSize, (Float64)kSpatialSpeakerBufferFrameSize };
                    memcpy(outData, &range, sizeof(range));
                    *outDataSize = sizeof(range);
                    return kAudioHardwareNoError;
                }
                case kAudioDevicePropertyStreamConfiguration:
                {
                    static _Atomic(uint32_t) streamConfigLogCount = 0;
                    uint32_t n = atomic_fetch_add_explicit(&streamConfigLogCount, 1, memory_order_relaxed);
                    if (inDataSize < SpatialSpeaker_StreamConfigurationDataSize()) return kAudioHardwareBadPropertySizeError;
                    AudioBufferList *bufferList = (AudioBufferList *)outData;
                    bufferList->mNumberBuffers = 1;
                    bufferList->mBuffers[0].mNumberChannels = kSpatialSpeakerChannelCount;
                    bufferList->mBuffers[0].mDataByteSize = kSpatialSpeakerBufferFrameSize * kSpatialSpeakerChannelCount * sizeof(Float32);
                    bufferList->mBuffers[0].mData = NULL;
                    if (n < 8) {
                        os_log_error(gSpatialSpeakerLog, "GetPropertyData streamConfig scope=%u buffers=%u channels=%u bytes=%u", inAddress->mScope, bufferList->mNumberBuffers, bufferList->mBuffers[0].mNumberChannels, bufferList->mBuffers[0].mDataByteSize);
                    }
                    *outDataSize = SpatialSpeaker_StreamConfigurationDataSize();
                    return kAudioHardwareNoError;
                }
                default:
                    SpatialSpeaker_LogUnsupportedProperty("GetPropertyData", inObjectID, inAddress);
                    return kAudioHardwareUnknownPropertyError;
            }

        case kSpatialSpeakerInputStreamObjectID:
        case kSpatialSpeakerOutputStreamObjectID:
        {
            Boolean isInput = inObjectID == kSpatialSpeakerInputStreamObjectID;
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                    *((AudioClassID *)outData) = kAudioObjectClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyClass:
                    if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                    *((AudioClassID *)outData) = kAudioStreamClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwner:
                    if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                    *((AudioObjectID *)outData) = kSpatialSpeakerDeviceObjectID;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyName:
                    if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                    *((CFStringRef *)outData) = SpatialSpeaker_CopyPropertyString(isInput ? kSpatialSpeakerInputName : kSpatialSpeakerOutputName);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyIsActive:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    *((UInt32 *)outData) = 1;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyDirection:
                {
                    static _Atomic(uint32_t) directionLogCount = 0;
                    uint32_t n = atomic_fetch_add_explicit(&directionLogCount, 1, memory_order_relaxed);
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    *((UInt32 *)outData) = isInput ? 1U : 0U;
                    if (n < 8) {
                        os_log_error(gSpatialSpeakerLog, "GetPropertyData streamDirection stream=%{public}s direction=%u", isInput ? "input" : "output", *((UInt32 *)outData));
                    }
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                }
                case kAudioStreamPropertyTerminalType:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    *((UInt32 *)outData) = isInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyStartingChannel:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    *((UInt32 *)outData) = 1;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyLatency:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    *((UInt32 *)outData) = 0;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                {
                    if (inDataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
                    AudioStreamBasicDescription format = SpatialSpeaker_StreamFormat();
                    memcpy(outData, &format, sizeof(format));
                    *outDataSize = sizeof(format);
                    return kAudioHardwareNoError;
                }
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                {
                    if (inDataSize < sizeof(AudioStreamRangedDescription)) return kAudioHardwareBadPropertySizeError;
                    AudioStreamRangedDescription ranged = SpatialSpeaker_RangedFormat();
                    memcpy(outData, &ranged, sizeof(ranged));
                    *outDataSize = sizeof(ranged);
                    return kAudioHardwareNoError;
                }
                default:
                    SpatialSpeaker_LogUnsupportedProperty("GetPropertyData", inObjectID, inAddress);
                    return kAudioHardwareUnknownPropertyError;
            }
        }

        default:
            SpatialSpeaker_LogUnsupportedProperty("GetPropertyData", inObjectID, inAddress);
            return kAudioHardwareBadObjectError;
    }
}

static OSStatus SpatialSpeaker_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData)
{
    (void)inDriver;
    (void)inClientProcessID;
    (void)inQualifierDataSize;
    (void)inQualifierData;

    if (inObjectID == kSpatialSpeakerDeviceObjectID && inAddress->mSelector == kAudioDevicePropertyBufferFrameSize) {
        if (inDataSize != sizeof(UInt32) || inData == NULL) {
            return kAudioHardwareBadPropertySizeError;
        }
        return *((const UInt32 *)inData) == kSpatialSpeakerBufferFrameSize ? kAudioHardwareNoError : kAudioHardwareUnsupportedOperationError;
    }

    if (inObjectID == kSpatialSpeakerDeviceObjectID && inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inDataSize != sizeof(Float64) || inData == NULL) {
            return kAudioHardwareBadPropertySizeError;
        }
        return *((const Float64 *)inData) == (Float64)kSpatialSpeakerNominalSampleRate ? kAudioHardwareNoError : kAudioDeviceUnsupportedFormatError;
    }

    if (SpatialSpeaker_IsStreamObject(inObjectID) &&
        (inAddress->mSelector == kAudioStreamPropertyVirtualFormat || inAddress->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (inDataSize != sizeof(AudioStreamBasicDescription) || inData == NULL) {
            return kAudioHardwareBadPropertySizeError;
        }
        AudioStreamBasicDescription expected = SpatialSpeaker_StreamFormat();
        return memcmp(inData, &expected, sizeof(expected)) == 0 ? kAudioHardwareNoError : kAudioDeviceUnsupportedFormatError;
    }

    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus SpatialSpeaker_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver;

    if (inDeviceObjectID != kSpatialSpeakerDeviceObjectID) {
        return kAudioHardwareBadDeviceError;
    }

    UInt32 previous = atomic_fetch_add(&gSpatialSpeakerState.ioStartCount, 1);
    char bundleID[kSpatialSpeakerTrackedBundleIDLength] = "<unknown>";
    UInt32 clientStartCount = 0;
    Boolean isInputOnly = false;
    pthread_mutex_lock(&gSpatialSpeakerState.mutex);
    SpatialSpeakerTrackedClient *client = SpatialSpeaker_FindTrackedClient(inClientID);
    if (client != NULL) {
        client->ioStartCount += 1;
        clientStartCount = client->ioStartCount;
        isInputOnly = client->isInputOnly != 0;
        strncpy(bundleID, client->bundleID, sizeof(bundleID) - 1);
        bundleID[sizeof(bundleID) - 1] = '\0';
    }
    pthread_mutex_unlock(&gSpatialSpeakerState.mutex);
    os_log_error(gSpatialSpeakerLog, "StartIO[%{public}s] clientID=%u bundleID=%{public}s inputOnly=%{public}s clientStartCount=%u ioStartCount=%u->%u", kSpatialSpeakerDiagnosticsBuildTag, inClientID, bundleID, isInputOnly ? "true" : "false", clientStartCount, previous, previous + 1);
    if (isInputOnly) {
        SpatialSpeaker_LogTopologySummary("startio-capture-client");
    }
    if (previous == 0) {
        gSpatialSpeakerState.startHostTime = mach_absolute_time();
        gSpatialSpeakerState.startSampleTime = 0;
        gSpatialSpeakerState.spatialReadInputCallCount = 0;
        gSpatialSpeakerState.hasLoggedMissingSpatialReadAfterWrite = 0;
        atomic_fetch_add(&gSpatialSpeakerState.ioSeed, 1);
    }

    return kAudioHardwareNoError;
}

static OSStatus SpatialSpeaker_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver;

    if (inDeviceObjectID != kSpatialSpeakerDeviceObjectID) {
        return kAudioHardwareBadDeviceError;
    }

    UInt32 current = atomic_load(&gSpatialSpeakerState.ioStartCount);
    char bundleID[kSpatialSpeakerTrackedBundleIDLength] = "<unknown>";
    UInt32 clientStartCount = 0;
    Boolean isInputOnly = false;
    pthread_mutex_lock(&gSpatialSpeakerState.mutex);
    SpatialSpeakerTrackedClient *client = SpatialSpeaker_FindTrackedClient(inClientID);
    if (client != NULL) {
        if (client->ioStartCount > 0) client->ioStartCount -= 1;
        clientStartCount = client->ioStartCount;
        isInputOnly = client->isInputOnly != 0;
        strncpy(bundleID, client->bundleID, sizeof(bundleID) - 1);
        bundleID[sizeof(bundleID) - 1] = '\0';
    }
    pthread_mutex_unlock(&gSpatialSpeakerState.mutex);
    os_log_error(gSpatialSpeakerLog, "StopIO clientID=%u bundleID=%{public}s inputOnly=%{public}s clientStartCount=%u ioStartCount=%u->%u", inClientID, bundleID, isInputOnly ? "true" : "false", clientStartCount, current, current > 0 ? current - 1 : 0);
    if (current > 0) {
        atomic_fetch_sub(&gSpatialSpeakerState.ioStartCount, 1);
    }

    return kAudioHardwareNoError;
}

static OSStatus SpatialSpeaker_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed)
{
    (void)inDriver;
    (void)inClientID;

    if (inDeviceObjectID != kSpatialSpeakerDeviceObjectID) {
        return kAudioHardwareBadDeviceError;
    }
    if (outSampleTime == NULL || outHostTime == NULL || outSeed == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    UInt64 now = mach_absolute_time();
    Float64 elapsedSeconds = SpatialSpeaker_SecondsFromHostTicks(now - gSpatialSpeakerState.startHostTime);
    Float64 elapsedFrames = elapsedSeconds * (Float64)kSpatialSpeakerNominalSampleRate;
    Float64 periodFrames = (Float64)kSpatialSpeakerZeroTimestampPeriod;
    Float64 zeroSampleTime = ((UInt64)(elapsedFrames / periodFrames)) * periodFrames;
    UInt64 zeroHostTime = gSpatialSpeakerState.startHostTime + SpatialSpeaker_HostTicksFromSeconds(zeroSampleTime / (Float64)kSpatialSpeakerNominalSampleRate);

    *outSampleTime = zeroSampleTime;
    *outHostTime = zeroHostTime;
    *outSeed = atomic_load(&gSpatialSpeakerState.ioSeed);
    return kAudioHardwareNoError;
}

static OSStatus SpatialSpeaker_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace)
{
    (void)inDriver;

    if (inDeviceObjectID != kSpatialSpeakerDeviceObjectID) {
        return kAudioHardwareBadDeviceError;
    }
    if (outWillDo == NULL || outWillDoInPlace == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    *outWillDo = false;
    *outWillDoInPlace = true;

    switch (inOperationID) {
        case kAudioServerPlugInIOOperationReadInput:
            *outWillDo = true;
            {
                static _Atomic(uint32_t) willDoCount = 0;
                uint32_t n = atomic_fetch_add_explicit(&willDoCount, 1, memory_order_relaxed);
                if (n < 24 || (n % 96) == 0) {
                    os_log_error(gSpatialSpeakerLog, "WillDoIOOperation[%{public}s] n=%u clientID=%u stream=%{public}s op=%{public}s willDo=true inputOnly=%{public}s", kSpatialSpeakerDiagnosticsBuildTag, n, inClientID, "input", SpatialSpeaker_IOOperationName(inOperationID), SpatialSpeaker_IsInputOnlyClient(inClientID) ? "true" : "false");
                }
            }
            return kAudioHardwareNoError;
        case kAudioServerPlugInIOOperationWriteMix:
            // Capture-only clients must still participate in input IO, but they should
            // not be scheduled for WriteMix. Treating them as pure input clients aligns
            // with the expected HAL contract for loopback readers.
            *outWillDo = SpatialSpeaker_IsInputOnlyClient(inClientID) ? false : true;
            {
                static _Atomic(uint32_t) willDoCount = 0;
                uint32_t n = atomic_fetch_add_explicit(&willDoCount, 1, memory_order_relaxed);
                if (n < 24) {
                    os_log_error(gSpatialSpeakerLog, "WillDoIOOperation[%{public}s] n=%u clientID=%u stream=%{public}s op=%{public}s willDo=%{public}s inputOnly=%{public}s", kSpatialSpeakerDiagnosticsBuildTag, n, inClientID, "output", SpatialSpeaker_IOOperationName(inOperationID), *outWillDo ? "true" : "false", SpatialSpeaker_IsInputOnlyClient(inClientID) ? "true" : "false");
                }
            }
            return kAudioHardwareNoError;
        default:
            return kAudioHardwareNoError;
    }
}

static OSStatus SpatialSpeaker_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo)
{
    (void)inDriver;
    (void)inIOCycleInfo;
    if (inDeviceObjectID == kSpatialSpeakerDeviceObjectID &&
        (inOperationID == kAudioServerPlugInIOOperationReadInput || inOperationID == kAudioServerPlugInIOOperationWriteMix)) {
        static _Atomic(uint32_t) beginIOCount = 0;
        uint32_t n = atomic_fetch_add_explicit(&beginIOCount, 1, memory_order_relaxed);
        if (n < 24) {
            os_log_error(
                gSpatialSpeakerLog,
                "DIAG BeginIO[%{public}s] n=%u clientID=%u op=%u(%{public}s) frames=%u inputOnly=%{public}s",
                kSpatialSpeakerDiagnosticsBuildTag,
                n,
                inClientID,
                inOperationID,
                SpatialSpeaker_IOOperationName(inOperationID),
                inIOBufferFrameSize,
                SpatialSpeaker_IsInputOnlyClient(inClientID) ? "true" : "false"
            );
        }
    }
    return inDeviceObjectID == kSpatialSpeakerDeviceObjectID ? kAudioHardwareNoError : kAudioHardwareBadDeviceError;
}

static OSStatus SpatialSpeaker_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer)
{
    (void)inDriver;
    (void)inIOCycleInfo;
    (void)ioSecondaryBuffer;

    if (inDeviceObjectID != kSpatialSpeakerDeviceObjectID) {
        return kAudioHardwareBadDeviceError;
    }
    if (ioMainBuffer == NULL) {
        os_log_error(
            gSpatialSpeakerLog,
            "DIAG DoIO rejected null main buffer clientID=%u op=%u streamObject=%u secondary=%p",
            inClientID,
            inOperationID,
            inStreamObjectID,
            ioSecondaryBuffer
        );
        return kAudioHardwareIllegalOperationError;
    }

    if (inOperationID == kAudioServerPlugInIOOperationReadInput || inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        static _Atomic(uint32_t) doIOEntryCount = 0;
        uint32_t n = atomic_fetch_add_explicit(&doIOEntryCount, 1, memory_order_relaxed);
        if (n < 32) {
            os_log_error(
                gSpatialSpeakerLog,
                "DIAG DoIO entry[%{public}s] n=%u clientID=%u op=%u(%{public}s) streamObject=%u stream=%{public}s frames=%u inputOnly=%{public}s main=%p secondary=%p",
                kSpatialSpeakerDiagnosticsBuildTag,
                n,
                inClientID,
                inOperationID,
                SpatialSpeaker_IOOperationName(inOperationID),
                inStreamObjectID,
                SpatialSpeaker_StreamName(inStreamObjectID),
                inIOBufferFrameSize,
                SpatialSpeaker_IsInputOnlyClient(inClientID) ? "true" : "false",
                ioMainBuffer,
                ioSecondaryBuffer
            );
        }
    }

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        // Some modern routes appear to invoke WriteMix with an unexpected stream
        // object even though this driver only exposes one writable output stream.
        // Treat WriteMix as a device-level operation so valid writer audio is not
        // discarded before the loopback reader can observe it.
        if (inStreamObjectID != kSpatialSpeakerOutputStreamObjectID) {
            static _Atomic(uint32_t) unexpectedWriteMixStreamCount = 0;
            uint32_t mismatchCount = atomic_fetch_add_explicit(&unexpectedWriteMixStreamCount, 1, memory_order_relaxed);
            if (mismatchCount < 16) {
                os_log_error(
                    gSpatialSpeakerLog,
                    "WriteMix stream mismatch n=%u clientID=%u inputOnly=%{public}s streamObject=%u stream=%{public}s -- accepting device-level mix anyway",
                    mismatchCount,
                    inClientID,
                    SpatialSpeaker_IsInputOnlyClient(inClientID) ? "true" : "false",
                    inStreamObjectID,
                    SpatialSpeaker_StreamName(inStreamObjectID)
                );
            }
        }

        if (SpatialSpeaker_IsInputOnlyClient(inClientID)) {
            static _Atomic(uint32_t) ignoredWriteMixCount = 0;
            uint32_t n = atomic_fetch_add_explicit(&ignoredWriteMixCount, 1, memory_order_relaxed);
            if (n < 16) {
                os_log_error(gSpatialSpeakerLog, "DoIOOperation ignored WriteMix n=%u clientID=%u stream=%{public}s frames=%u (input-only client)", n, inClientID, SpatialSpeaker_StreamName(inStreamObjectID), inIOBufferFrameSize);
            }
            return kAudioHardwareNoError;
        }

        static _Atomic(uint32_t) writeMixCount = 0;
        static _Atomic(uint32_t) silentStreak = 0;
        uint32_t n = atomic_fetch_add_explicit(&writeMixCount, 1, memory_order_relaxed);
        Float32 peak = 0;
        const Float32 *samples = (const Float32 *)ioMainBuffer;
        for (UInt32 i = 0; i < inIOBufferFrameSize * kSpatialSpeakerChannelCount; i++) {
            Float32 v = samples[i] < 0 ? -samples[i] : samples[i];
            if (v > peak) peak = v;
        }
        Boolean hasAudio = peak > 1e-6f;

        // Log first 16 cycles, then every ~1s, and on every transition zero↔nonzero.
        static _Atomic(uint32_t) lastLoggedNonZero = 0;
        uint32_t prevNonZero = atomic_load_explicit(&lastLoggedNonZero, memory_order_relaxed);
        char bundleID[kSpatialSpeakerTrackedBundleIDLength] = "<unknown>";
        Boolean hasExternalWriter = false;
        Boolean hasSpatialCaptureClient = false;
        UInt32 spatialReadInputCallCount = 0;
        UInt64 writeMixSequence = 0;
        pthread_mutex_lock(&gSpatialSpeakerState.mutex);
        SpatialSpeakerTrackedClient *client = SpatialSpeaker_FindTrackedClient(inClientID);
        if (client != NULL) {
            client->hasWrittenAudio = hasAudio ? 1U : client->hasWrittenAudio;
            strncpy(bundleID, client->bundleID, sizeof(bundleID) - 1);
            bundleID[sizeof(bundleID) - 1] = '\0';
        }
        if (hasAudio) {
            gSpatialSpeakerState.lastWriterClientID = inClientID;
            gSpatialSpeakerState.lastWriterProcessID = client != NULL ? client->processID : 0;
            gSpatialSpeakerState.lastNonZeroPeak = peak;
            gSpatialSpeakerState.lastWriteFrameCount = inIOBufferFrameSize;
            gSpatialSpeakerState.writeMixSequence += 1;
            strncpy(gSpatialSpeakerState.lastWriterBundleID, bundleID, sizeof(gSpatialSpeakerState.lastWriterBundleID) - 1);
            gSpatialSpeakerState.lastWriterBundleID[sizeof(gSpatialSpeakerState.lastWriterBundleID) - 1] = '\0';
        }
        for (UInt32 i = 0; i < kSpatialSpeakerTrackedClientCapacity; ++i) {
            SpatialSpeakerTrackedClient *tracked = &gSpatialSpeakerState.trackedClients[i];
            if (tracked->clientID != 0 && tracked->isInputOnly != 0) {
                hasSpatialCaptureClient = true;
            }
            if (tracked->clientID != 0 && tracked->isInputOnly == 0 && tracked->ioStartCount > 0) {
                hasExternalWriter = true;
            }
        }
        spatialReadInputCallCount = gSpatialSpeakerState.spatialReadInputCallCount;
        writeMixSequence = gSpatialSpeakerState.writeMixSequence;
        if (!hasExternalWriter && client != NULL && client->hasLoggedWriterAbsence == 0) {
            client->hasLoggedWriterAbsence = 1;
            os_log_error(gSpatialSpeakerLog, "WriteMix writer absence: no external writer active while clientID=%u bundleID=%{public}s wrote peak=%.6f", inClientID, bundleID, peak);
        }
        if (hasAudio
            && hasSpatialCaptureClient
            && spatialReadInputCallCount == 0
            && writeMixSequence >= 1
            && gSpatialSpeakerState.hasLoggedMissingSpatialReadAfterWrite == 0) {
            gSpatialSpeakerState.hasLoggedMissingSpatialReadAfterWrite = 1;
            os_log_error(
                gSpatialSpeakerLog,
                "WriteMix observed nonzero audio but no Spatial capture client has called ReadInput yet. writerClientID=%u bundleID=%{public}s writeMixSeq=%llu peak=%.6f",
                inClientID,
                bundleID,
                writeMixSequence,
                peak
            );
        }
        for (UInt32 i = 0; i < kSpatialSpeakerTrackedClientCapacity; ++i) {
            SpatialSpeakerTrackedClient *tracked = &gSpatialSpeakerState.trackedClients[i];
            if (tracked->clientID != 0
                && tracked->isInputOnly != 0
                && tracked->ioStartCount == 0
                && hasAudio
                && tracked->hasLoggedMissingStartIO == 0
                && writeMixSequence >= 1) {
                tracked->hasLoggedMissingStartIO = 1;
                os_log_error(
                    gSpatialSpeakerLog,
                    "Spatial input client was added but never started IO. captureClientID=%u bundleID=%{public}s writerClientID=%u writerBundleID=%{public}s writeMixSeq=%llu peak=%.6f",
                    tracked->clientID,
                    tracked->bundleID,
                    inClientID,
                    bundleID,
                    writeMixSequence,
                    peak
                );
            }
            if (tracked->clientID != 0
                && tracked->isInputOnly != 0
                && tracked->ioStartCount > 0
                && tracked->readInputCount == 0
                && hasAudio
                && tracked->hasLoggedMissingReadInputAfterStartIO == 0
                && writeMixSequence >= 1) {
                tracked->hasLoggedMissingReadInputAfterStartIO = 1;
                os_log_error(
                    gSpatialSpeakerLog,
                    "Spatial input client started IO but HAL never requested ReadInput. captureClientID=%u bundleID=%{public}s writerClientID=%u writerBundleID=%{public}s writeMixSeq=%llu peak=%.6f",
                    tracked->clientID,
                    tracked->bundleID,
                    inClientID,
                    bundleID,
                    writeMixSequence,
                    peak
                );
            }
        }
        pthread_mutex_unlock(&gSpatialSpeakerState.mutex);

        if (n < 32 || (n % 96) == 0 || (hasAudio && !prevNonZero) || (!hasAudio && prevNonZero)) {
            os_log_error(gSpatialSpeakerLog, "WriteMix n=%u clientID=%u bundleID=%{public}s stream=%{public}s frames=%u peak=%.6f", n, inClientID, bundleID, SpatialSpeaker_StreamName(inStreamObjectID), inIOBufferFrameSize, peak);
        }
        atomic_store_explicit(&lastLoggedNonZero, hasAudio ? 1u : 0u, memory_order_relaxed);

        // Only update the ring buffer when there is real audio. This prevents any
        // client that provides silent outOutputData (including our capture proc, which
        // ignores outOutputData) from overwriting a good Spotify frame with zeros.
        // After kSilentStreakLimit consecutive silent cycles the ring buffer IS cleared
        // so that a genuinely silent/paused source eventually silences ReadInput too.
        if (hasAudio) {
            atomic_store_explicit(&silentStreak, 0u, memory_order_relaxed);
            SpatialSpeaker_StoreOutput(inIOBufferFrameSize, samples);
        } else {
            uint32_t streak = atomic_fetch_add_explicit(&silentStreak, 1u, memory_order_relaxed) + 1u;
            if (streak >= 480u) {  // ~5 s at 512 frames/48 kHz per WriteMix client
                atomic_store_explicit(&silentStreak, 0u, memory_order_relaxed);
                SpatialSpeaker_StoreOutput(inIOBufferFrameSize, samples);
            }
        }
        return kAudioHardwareNoError;
    }

    if (inOperationID == kAudioServerPlugInIOOperationReadInput) {
        // Use a global rolling counter — never capped — so logs appear every ~170 ms
        // regardless of how many prior coreaudiod sessions have run.
        static _Atomic(uint32_t) readInputCount = 0;
        uint32_t n = atomic_fetch_add_explicit(&readInputCount, 1, memory_order_relaxed);
        Boolean isInputOnly = SpatialSpeaker_IsInputOnlyClient(inClientID);

        // Some aggregate-device routes appear to invoke ReadInput with an unexpected
        // stream object even though the device only exposes one loopback source. Treat
        // ReadInput as a device-level fetch and always copy the latest ring-buffered
        // mix instead of silently returning zeros on a stream-object mismatch.
        if (inStreamObjectID != kSpatialSpeakerInputStreamObjectID) {
            static _Atomic(uint32_t) unexpectedReadInputStreamCount = 0;
            uint32_t mismatchCount = atomic_fetch_add_explicit(&unexpectedReadInputStreamCount, 1, memory_order_relaxed);
            if (mismatchCount < 16) {
                os_log_error(
                    gSpatialSpeakerLog,
                    "ReadInput stream mismatch n=%u clientID=%u inputOnly=%{public}s streamObject=%u stream=%{public}s -- copying latest loopback anyway",
                    mismatchCount,
                    inClientID,
                    isInputOnly ? "true" : "false",
                    inStreamObjectID,
                    SpatialSpeaker_StreamName(inStreamObjectID)
                );
            }
        }
        SpatialSpeaker_CopyLatestInput(inIOBufferFrameSize, (Float32 *)ioMainBuffer);

        // Log the first few calls verbosely, then every 16 calls (~170 ms at 512 frames/48 kHz),
        // on first non-zero, and always on mismatch.
        static _Atomic(uint32_t) lastReadNonZero = 0;
        UInt32 clientReadInputCount = 0;
        UInt32 lastWriterClientID = 0;
        Float32 lastNonZeroPeak = 0;
        UInt64 writeMixSequence = 0;
        UInt32 ringFrameCount = 0;
        char lastWriterBundleID[kSpatialSpeakerTrackedBundleIDLength] = "<none>";
        char bundleID[kSpatialSpeakerTrackedBundleIDLength] = "<unknown>";
        Boolean shouldLogZeroMismatch = false;
        pthread_mutex_lock(&gSpatialSpeakerState.mutex);
        SpatialSpeakerTrackedClient *client = SpatialSpeaker_FindTrackedClient(inClientID);
        if (client != NULL) {
            client->readInputCount += 1;
            clientReadInputCount = client->readInputCount;
            strncpy(bundleID, client->bundleID, sizeof(bundleID) - 1);
            bundleID[sizeof(bundleID) - 1] = '\0';
            if (client->isInputOnly != 0) {
                gSpatialSpeakerState.spatialReadInputCallCount += 1;
            }
        }
        lastWriterClientID = gSpatialSpeakerState.lastWriterClientID;
        lastNonZeroPeak = gSpatialSpeakerState.lastNonZeroPeak;
        writeMixSequence = gSpatialSpeakerState.writeMixSequence;
        ringFrameCount = gSpatialSpeakerState.lastFrameCount;
        strncpy(lastWriterBundleID, gSpatialSpeakerState.lastWriterBundleID, sizeof(lastWriterBundleID) - 1);
        lastWriterBundleID[sizeof(lastWriterBundleID) - 1] = '\0';
        pthread_mutex_unlock(&gSpatialSpeakerState.mutex);

        if (clientReadInputCount <= 16 || (n % 16) == 0) {
            Float32 peak = 0;
            const Float32 *s = (const Float32 *)ioMainBuffer;
            for (UInt32 i = 0; i < inIOBufferFrameSize * kSpatialSpeakerChannelCount; i++) {
                Float32 v = s[i] < 0 ? -s[i] : s[i];
                if (v > peak) peak = v;
            }
            uint32_t prevNonZero = atomic_load_explicit(&lastReadNonZero, memory_order_relaxed);
            if (clientReadInputCount <= 16 || (n % 16) == 0 || (peak > 1e-6f && !prevNonZero)) {
                Float32 sample0 = inIOBufferFrameSize > 0 ? s[0] : 0;
                Float32 sample1 = inIOBufferFrameSize > 0 ? s[1] : 0;
                os_log_error(gSpatialSpeakerLog, "DIAG ReadInput n=%u clientID=%u bundleID=%{public}s clientReadCount=%u inputOnly=%{public}s stream=%{public}s frames=%u peak=%.6f sample0=%.6f sample1=%.6f ringFrames=%u lastWriterClientID=%u lastWriterBundleID=%{public}s lastWriterPeak=%.6f writeMixSeq=%llu", n, inClientID, bundleID, clientReadInputCount, isInputOnly ? "true" : "false", SpatialSpeaker_StreamName(inStreamObjectID), inIOBufferFrameSize, peak, sample0, sample1, ringFrameCount, lastWriterClientID, lastWriterBundleID, lastNonZeroPeak, writeMixSequence);
            }
            atomic_store_explicit(&lastReadNonZero, peak > 1e-6f ? 1u : 0u, memory_order_relaxed);
            if (ringFrameCount > 0 && peak <= 1e-6f && lastNonZeroPeak > 1e-6f) {
                pthread_mutex_lock(&gSpatialSpeakerState.mutex);
                SpatialSpeakerTrackedClient *client = SpatialSpeaker_FindTrackedClient(inClientID);
                if (client != NULL && client->isInputOnly != 0 && client->hasLoggedReadInputZeroMismatch == 0) {
                    client->hasLoggedReadInputZeroMismatch = 1;
                    shouldLogZeroMismatch = true;
                }
                pthread_mutex_unlock(&gSpatialSpeakerState.mutex);
            }
            if (shouldLogZeroMismatch) {
                os_log_error(gSpatialSpeakerLog, "ReadInput mismatch: clientID=%u bundleID=%{public}s inputOnly=%{public}s ringFrames=%u lastWriterPeak=%.6f but read peak=0", inClientID, bundleID, isInputOnly ? "true" : "false", ringFrameCount, lastNonZeroPeak);
            }
        }
        return kAudioHardwareNoError;
    }

    static _Atomic(uint32_t) unknownOpCount = 0;
    uint32_t n = atomic_fetch_add_explicit(&unknownOpCount, 1, memory_order_relaxed);
    if (n < 8) {
        os_log_error(gSpatialSpeakerLog, "UnknownOp n=%u op=%u stream=%u frames=%u", n, inOperationID, inStreamObjectID, inIOBufferFrameSize);
    }
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus SpatialSpeaker_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo)
{
    (void)inDriver;
    (void)inClientID;
    (void)inOperationID;
    (void)inIOBufferFrameSize;
    (void)inIOCycleInfo;
    return inDeviceObjectID == kSpatialSpeakerDeviceObjectID ? kAudioHardwareNoError : kAudioHardwareBadDeviceError;
}

void *SpatialSpeaker_Create(CFAllocatorRef allocator, CFUUIDRef typeID)
{
    (void)allocator;

    // Some macOS builds request the factory through the SDK-defined AudioServerPlugIn
    // type UUID, while others appear to probe the legacy/runtime UUID or the explicit
    // factory UUID directly. All paths intentionally resolve to the same singleton driver.
    if (typeID == NULL ||
        (!CFEqual(typeID, kAudioServerPlugInTypeUUID) &&
         !CFEqual(typeID, kSpatialSpeakerLegacyPlugInTypeUUID) &&
         !CFEqual(typeID, kSpatialSpeakerFactoryUUID))) {
        return NULL;
    }

    return &gSpatialSpeakerDriver;
}
