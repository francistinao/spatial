#include <CoreAudio/AudioHardware.h>
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
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
    kSpatialSpeakerZeroTimestampPeriod = 16384
};

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
    UInt32 lastFrameCount;
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
    .lastFrameCount = 0
};

static const CFStringRef kSpatialSpeakerName = CFSTR("Spatial Speaker");
static const CFStringRef kSpatialSpeakerManufacturer = CFSTR("Spatial");
static const CFStringRef kSpatialSpeakerUID = CFSTR("com.spatial.app.driver.speaker");
static const CFStringRef kSpatialSpeakerModelUID = CFSTR("com.spatial.app.driver.speaker.model");
static const CFStringRef kSpatialSpeakerInputName = CFSTR("Spatial Speaker Input");
static const CFStringRef kSpatialSpeakerOutputName = CFSTR("Spatial Speaker Output");
static const CFStringRef kSpatialSpeakerBundleID = CFSTR("com.spatial.app.driver.speaker");
static os_log_t gSpatialSpeakerLog;

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

    os_log_error(
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

static UInt32 SpatialSpeaker_StreamConfigurationDataSize(void)
{
    return (UInt32)(offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer));
}

static Boolean SpatialSpeaker_IsStreamObject(AudioObjectID objectID)
{
    return objectID == kSpatialSpeakerInputStreamObjectID || objectID == kSpatialSpeakerOutputStreamObjectID;
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

static void SpatialSpeaker_CopyLatestInput(UInt32 frameCount, Float32 *outBuffer)
{
    UInt32 copyFrames = frameCount;
    if (copyFrames > kSpatialSpeakerRingBufferFrames) {
        copyFrames = kSpatialSpeakerRingBufferFrames;
    }

    pthread_mutex_lock(&gSpatialSpeakerState.mutex);
    UInt32 availableFrames = gSpatialSpeakerState.lastFrameCount;
    if (availableFrames == 0) {
        memset(outBuffer, 0, frameCount * kSpatialSpeakerChannelCount * sizeof(Float32));
        pthread_mutex_unlock(&gSpatialSpeakerState.mutex);
        return;
    }

    UInt32 framesToUse = availableFrames < copyFrames ? availableFrames : copyFrames;
    UInt32 bytesToCopy = framesToUse * kSpatialSpeakerChannelCount * sizeof(Float32);
    memcpy(outBuffer, gSpatialSpeakerState.ringBuffer, bytesToCopy);
    pthread_mutex_unlock(&gSpatialSpeakerState.mutex);

    if (framesToUse < frameCount) {
        memset(outBuffer + (framesToUse * kSpatialSpeakerChannelCount), 0, (frameCount - framesToUse) * kSpatialSpeakerChannelCount * sizeof(Float32));
    }
}

static void SpatialSpeaker_StoreOutput(UInt32 frameCount, const Float32 *buffer)
{
    UInt32 copyFrames = frameCount;
    if (copyFrames > kSpatialSpeakerRingBufferFrames) {
        buffer += (copyFrames - kSpatialSpeakerRingBufferFrames) * kSpatialSpeakerChannelCount;
        copyFrames = kSpatialSpeakerRingBufferFrames;
    }

    pthread_mutex_lock(&gSpatialSpeakerState.mutex);
    memcpy(gSpatialSpeakerState.ringBuffer, buffer, copyFrames * kSpatialSpeakerChannelCount * sizeof(Float32));
    gSpatialSpeakerState.lastFrameCount = copyFrames;
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
    os_log_info(gSpatialSpeakerLog, "SpatialSpeaker_Initialize host=%p", inHost);
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
    (void)inClientInfo;
    return inDeviceObjectID == kSpatialSpeakerDeviceObjectID ? kAudioHardwareNoError : kAudioHardwareBadDeviceError;
}

static OSStatus SpatialSpeaker_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo)
{
    (void)inDriver;
    (void)inClientInfo;
    return inDeviceObjectID == kSpatialSpeakerDeviceObjectID ? kAudioHardwareNoError : kAudioHardwareBadDeviceError;
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
                case kAudioObjectPropertyOwner:
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyName:
                case kAudioPlugInPropertyBundleID:
                case kAudioPlugInPropertyResourceBundle:
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects:
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
                case kAudioObjectPropertyOwner:
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
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
                    *outDataSize = 2 * sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyRelatedDevices:
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyStreams:
                    *outDataSize = (inAddress->mScope == kAudioObjectPropertyScopeGlobal) ? 2 * sizeof(AudioObjectID) : sizeof(AudioObjectID);
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
                    UInt32 count = 0;
                    if (SpatialSpeaker_QualifierHasClass(inQualifierDataSize, inQualifierData, kAudioStreamClassID)) {
                        owned[count++] = kSpatialSpeakerInputStreamObjectID;
                        owned[count++] = kSpatialSpeakerOutputStreamObjectID;
                    }
                    if (inDataSize < count * sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                    memcpy(outData, owned, count * sizeof(AudioObjectID));
                    *outDataSize = count * sizeof(AudioObjectID);
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
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertySafetyOffset:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    *((UInt32 *)outData) = 0;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyStreams:
                {
                    AudioObjectID streams[2];
                    UInt32 count = 0;
                    if (inAddress->mScope == kAudioObjectPropertyScopeGlobal || inAddress->mScope == kAudioObjectPropertyScopeInput) {
                        streams[count++] = kSpatialSpeakerInputStreamObjectID;
                    }
                    if (inAddress->mScope == kAudioObjectPropertyScopeGlobal || inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                        streams[count++] = kSpatialSpeakerOutputStreamObjectID;
                    }
                    if (inDataSize < count * sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                    memcpy(outData, streams, count * sizeof(AudioObjectID));
                    *outDataSize = count * sizeof(AudioObjectID);
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
                    if (inDataSize < SpatialSpeaker_StreamConfigurationDataSize()) return kAudioHardwareBadPropertySizeError;
                    AudioBufferList *bufferList = (AudioBufferList *)outData;
                    bufferList->mNumberBuffers = 1;
                    bufferList->mBuffers[0].mNumberChannels = kSpatialSpeakerChannelCount;
                    bufferList->mBuffers[0].mDataByteSize = kSpatialSpeakerBufferFrameSize * kSpatialSpeakerChannelCount * sizeof(Float32);
                    bufferList->mBuffers[0].mData = NULL;
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
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    *((UInt32 *)outData) = isInput ? 1U : 0U;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
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
    (void)inClientID;

    if (inDeviceObjectID != kSpatialSpeakerDeviceObjectID) {
        return kAudioHardwareBadDeviceError;
    }

    UInt32 previous = atomic_fetch_add(&gSpatialSpeakerState.ioStartCount, 1);
    if (previous == 0) {
        gSpatialSpeakerState.startHostTime = mach_absolute_time();
        gSpatialSpeakerState.startSampleTime = 0;
        atomic_fetch_add(&gSpatialSpeakerState.ioSeed, 1);
    }

    return kAudioHardwareNoError;
}

static OSStatus SpatialSpeaker_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver;
    (void)inClientID;

    if (inDeviceObjectID != kSpatialSpeakerDeviceObjectID) {
        return kAudioHardwareBadDeviceError;
    }

    UInt32 current = atomic_load(&gSpatialSpeakerState.ioStartCount);
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
    (void)inClientID;

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
        case kAudioServerPlugInIOOperationWriteMix:
            *outWillDo = true;
            return kAudioHardwareNoError;
        default:
            return kAudioHardwareNoError;
    }
}

static OSStatus SpatialSpeaker_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo)
{
    (void)inDriver;
    (void)inClientID;
    (void)inOperationID;
    (void)inIOBufferFrameSize;
    (void)inIOCycleInfo;
    return inDeviceObjectID == kSpatialSpeakerDeviceObjectID ? kAudioHardwareNoError : kAudioHardwareBadDeviceError;
}

static OSStatus SpatialSpeaker_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer)
{
    (void)inDriver;
    (void)inClientID;
    (void)inIOCycleInfo;
    (void)ioSecondaryBuffer;

    if (inDeviceObjectID != kSpatialSpeakerDeviceObjectID) {
        return kAudioHardwareBadDeviceError;
    }
    if (ioMainBuffer == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix && inStreamObjectID == kSpatialSpeakerOutputStreamObjectID) {
        SpatialSpeaker_StoreOutput(inIOBufferFrameSize, (const Float32 *)ioMainBuffer);
        return kAudioHardwareNoError;
    }

    if (inOperationID == kAudioServerPlugInIOOperationReadInput && inStreamObjectID == kSpatialSpeakerInputStreamObjectID) {
        SpatialSpeaker_CopyLatestInput(inIOBufferFrameSize, (Float32 *)ioMainBuffer);
        return kAudioHardwareNoError;
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
