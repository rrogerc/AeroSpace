#import "private.h"
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <limits.h>
#import <os/signpost.h>

// The legacy Process Manager ABI is two 32-bit words on both supported architectures.
typedef struct {
    uint32_t high;
    uint32_t low;
} AeroProcessSerialNumber;

typedef int32_t (*GetProcessForPIDFn)(pid_t, AeroProcessSerialNumber *);
typedef CGError (*SetFrontProcessFn)(const AeroProcessSerialNumber *, CGWindowID, uint32_t);
typedef CGError (*PostEventFn)(const AeroProcessSerialNumber *, const uint8_t *);

static GetProcessForPIDFn getProcessForPID;
static SetFrontProcessFn setFrontProcess;
static PostEventFn postEvent;
static os_log_t focusTiming;

bool AeroSpacePrivateFocusAvailable(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        focusTiming = os_log_create("bobko.aerospace", OS_LOG_CATEGORY_POINTS_OF_INTEREST);
        // Keep the framework loaded for the lifetime of these function pointers.
        void *skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
        if (!skyLight) return;
        getProcessForPID = (GetProcessForPIDFn)dlsym(RTLD_DEFAULT, "GetProcessForPID");
        setFrontProcess = (SetFrontProcessFn)dlsym(skyLight, "_SLPSSetFrontProcessWithOptions");
        postEvent = (PostEventFn)dlsym(skyLight, "SLPSPostEventRecordTo");
    });
    return getProcessForPID && setFrontProcess && postEvent;
}

CGError AeroSpaceMakeKeyWindow(pid_t pid, CGWindowID windowId) {
    if (pid <= 0 || windowId == kCGNullWindowID) return kCGErrorIllegalArgument;
    if (!AeroSpacePrivateFocusAvailable()) return kCGErrorNotImplemented;
    AeroProcessSerialNumber psn = {0, 0};
    os_signpost_id_t timing = os_signpost_id_generate(focusTiming);
    os_signpost_interval_begin(focusTiming, timing, "resolveFocusProcess", "pid: %{public}d", pid);
    int32_t processResult = getProcessForPID(pid, &psn);
    os_signpost_interval_end(focusTiming, timing, "resolveFocusProcess");
    if (processResult != 0) return kCGErrorFailure;

    // Same window-specific activation sequence as Rift's make_key_window.
    // These records identify the desired key window rather than the app's previous one.
    uint8_t event[0x100] = {0};
    event[0x04] = 0xf8;
    event[0x08] = 0x01;
    event[0x3a] = 0x10;
    for (int i = 0; i < 4; ++i) event[0x3c + i] = (uint8_t)(windowId >> (8 * i));
    for (int i = 0x20; i < 0x30; ++i) event[i] = 0xff;

    os_signpost_interval_begin(focusTiming, timing, "activateFocusProcess", "pid: %{public}d window: %{public}u", pid, windowId);
    CGError result = setFrontProcess(&psn, windowId, 0x200); // kCPSUserGenerated
    os_signpost_interval_end(focusTiming, timing, "activateFocusProcess");
    if (result != kCGErrorSuccess) return result;
    os_signpost_interval_begin(focusTiming, timing, "postWindowFocusEvents", "pid: %{public}d window: %{public}u", pid, windowId);
    result = postEvent(&psn, event);
    if (result == kCGErrorSuccess) {
        event[0x08] = 0x02;
        result = postEvent(&psn, event);
    }
    os_signpost_interval_end(focusTiming, timing, "postWindowFocusEvents");
    return result;
}

typedef int32_t (*WindowConnectionFn)(void);
typedef CFTypeRef (*WindowQueryFn)(int32_t, CFArrayRef, int32_t);
typedef CFTypeRef (*WindowCopyFn)(CFTypeRef);
typedef int32_t (*WindowIntFn)(CFTypeRef);
typedef uint32_t (*WindowIdFn)(CFTypeRef);
typedef bool (*WindowAdvanceFn)(CFTypeRef);
typedef CGRect (*WindowBoundsFn)(CFTypeRef);

static WindowConnectionFn windowConnection;
static WindowQueryFn windowQuery;
static WindowCopyFn windowCopy;
static WindowIntFn windowCount, windowPid, windowLevel;
static WindowIdFn windowId;
static WindowAdvanceFn windowAdvance;
static WindowBoundsFn windowBounds;

static bool privateWindowQueryAvailable(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
        if (!skyLight) return;
        windowConnection = (WindowConnectionFn)dlsym(skyLight, "SLSMainConnectionID");
        windowQuery = (WindowQueryFn)dlsym(skyLight, "SLSWindowQueryWindows");
        windowCopy = (WindowCopyFn)dlsym(skyLight, "SLSWindowQueryResultCopyWindows");
        windowCount = (WindowIntFn)dlsym(skyLight, "SLSWindowIteratorGetCount");
        windowPid = (WindowIntFn)dlsym(skyLight, "SLSWindowIteratorGetPID");
        windowLevel = (WindowIntFn)dlsym(skyLight, "SLSWindowIteratorGetLevel");
        windowId = (WindowIdFn)dlsym(skyLight, "SLSWindowIteratorGetWindowID");
        windowAdvance = (WindowAdvanceFn)dlsym(skyLight, "SLSWindowIteratorAdvance");
        windowBounds = (WindowBoundsFn)dlsym(skyLight, "SLSWindowIteratorGetBounds");
    });
    return windowConnection && windowQuery && windowCopy && windowCount && windowPid &&
           windowLevel && windowId && windowAdvance && windowBounds;
}

CGError AeroSpaceCopyWindowInfo(const CGWindowID *ids, size_t count,
                               AeroSpaceWindowInfo *output, size_t capacity,
                               size_t *outputCount) {
    if (!outputCount) return kCGErrorIllegalArgument;
    *outputCount = 0;
    if (count == 0) return kCGErrorSuccess;
    if (!ids || !output || capacity < count || count > INT_MAX) return kCGErrorIllegalArgument;
    if (!privateWindowQueryAvailable()) return kCGErrorNotImplemented;
    CFMutableArrayRef numbers = CFArrayCreateMutable(NULL, (CFIndex)count, &kCFTypeArrayCallBacks);
    if (!numbers) return kCGErrorFailure;
    for (size_t i = 0; i < count; i++) {
        int64_t value = ids[i];
        CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt64Type, &value);
        if (!number) { CFRelease(numbers); return kCGErrorFailure; }
        CFArrayAppendValue(numbers, number);
        CFRelease(number);
    }
    CFTypeRef result = windowQuery(windowConnection(), numbers, 0);
    CFRelease(numbers);
    if (!result) return kCGErrorFailure;
    CFTypeRef iterator = windowCopy(result);
    CFRelease(result);
    if (!iterator) return kCGErrorFailure;
    // Like Rift, settle the query before the first Advance. Some reply shapes
    // otherwise initially appear empty. The output count is bounded independently.
    if (windowCount(iterator) < 0) { CFRelease(iterator); return kCGErrorFailure; }
    size_t written = 0;
    while (windowAdvance(iterator)) {
        if (written == capacity) { CFRelease(iterator); return kCGErrorRangeCheck; }
        output[written++] = (AeroSpaceWindowInfo){windowId(iterator), windowPid(iterator),
                                               windowLevel(iterator), windowBounds(iterator)};
    }
    CFRelease(iterator);
    *outputCount = written;
    return kCGErrorSuccess;
}
