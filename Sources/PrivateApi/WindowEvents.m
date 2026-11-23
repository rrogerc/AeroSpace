#import "include/private.h"
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>

static int (*eventConnection)(void);
static CGError (*registerNotifyProc)(void *, uint32_t, void *);
static CGError (*requestNotifications)(int, const uint32_t *, int);
static CFTypeRef (*queryWindows)(int, CFArrayRef, int);
static CFTypeRef (*copyQueriedWindows)(CFTypeRef);
static int (*queriedCount)(CFTypeRef);
static bool (*nextQueried)(CFTypeRef);
static int (*queriedPid)(CFTypeRef);
static int (*queriedLevel)(CFTypeRef);
static uint32_t (*queriedParent)(CFTypeRef);
static CGRect (*queriedBounds)(CFTypeRef);
static CGError (*isOrderedIn)(int, uint32_t, uint8_t *);
static AeroSpaceWindowEventHandler eventHandler;

// WindowServer sends the level of every new window to a connection that asked for the notifications of at least one
// window. Any ID will do, also one that no window has
static const uint32_t placeholderWindow = 4000000000;

bool AeroSpaceWindowEventsAvailable(void) {
    static dispatch_once_t once;
    static bool available;
    dispatch_once(&once, ^{
        void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
        if (!sky) return;
        eventConnection = dlsym(sky, "SLSMainConnectionID");
        registerNotifyProc = dlsym(sky, "SLSRegisterNotifyProc");
        requestNotifications = dlsym(sky, "SLSRequestNotificationsForWindows");
        queryWindows = dlsym(sky, "SLSWindowQueryWindows");
        copyQueriedWindows = dlsym(sky, "SLSWindowQueryResultCopyWindows");
        queriedCount = dlsym(sky, "SLSWindowIteratorGetCount");
        nextQueried = dlsym(sky, "SLSWindowIteratorAdvance");
        queriedPid = dlsym(sky, "SLSWindowIteratorGetPID");
        queriedLevel = dlsym(sky, "SLSWindowIteratorGetLevel");
        queriedParent = dlsym(sky, "SLSWindowIteratorGetParentID");
        queriedBounds = dlsym(sky, "SLSWindowIteratorGetBounds");
        isOrderedIn = dlsym(sky, "SLSWindowIsOrderedIn");
        available = eventConnection && registerNotifyProc && requestNotifications && queryWindows && copyQueriedWindows &&
            queriedCount && nextQueried && queriedPid && queriedLevel && queriedParent && queriedBounds && isOrderedIn;
    });
    return available;
}

// Every event of AeroSpaceWindowEvent carries the ID of its window in its first four bytes
static void windowEvent(uint32_t event, void *data, size_t length, void *context) {
    if (!eventHandler || !data || length < sizeof(uint32_t)) return;
    uint32_t windowId;
    memcpy(&windowId, data, sizeof(windowId));
    if (windowId) eventHandler(event, windowId);
}

bool AeroSpaceObserveWindowEvents(AeroSpaceWindowEventHandler handler) {
    if (!handler || !AeroSpaceWindowEventsAvailable()) return false;
    static dispatch_once_t once;
    static bool registered;
    dispatch_once(&once, ^{
        eventHandler = handler;
        const uint32_t events[] = {
            AeroSpaceWindowEventClosed, AeroSpaceWindowEventMoved, AeroSpaceWindowEventResized,
            AeroSpaceWindowEventLevelChanged, AeroSpaceWindowEventOrderedIn,
        };
        registered = true;
        for (size_t i = 0; i < sizeof(events) / sizeof(events[0]); ++i) {
            if (registerNotifyProc((void *)windowEvent, events[i], NULL) != kCGErrorSuccess) registered = false;
        }
        if (registered) AeroSpaceWatchWindows(NULL, 0);
    });
    return registered;
}

void AeroSpaceWatchWindows(const CGWindowID *windowIds, size_t count) {
    if ((!windowIds && count) || !AeroSpaceWindowEventsAvailable()) return;
    if (count > 255) count = 255;
    uint32_t list[256];
    for (size_t i = 0; i < count; ++i) list[i] = windowIds[i];
    list[count] = placeholderWindow;
    requestNotifications(eventConnection(), list, (int)count + 1);
}

bool AeroSpaceCopyNewWindowInfo(CGWindowID windowId, AeroSpaceNewWindowInfo *info) {
    if (!windowId || !info || !AeroSpaceWindowEventsAvailable()) return false;
    @autoreleasepool {
        int connection = eventConnection();
        CFTypeRef query = queryWindows(connection, (__bridge CFArrayRef)@[@(windowId)], 1);
        if (!query) return false;
        CFTypeRef windows = copyQueriedWindows(query);
        CFRelease(query);
        if (!windows) return false;
        // Like AeroSpaceCopyWindowInfo, settle the query before the first advance
        bool found = queriedCount(windows) > 0 && nextQueried(windows);
        if (found) {
            uint8_t ordered = 0;
            isOrderedIn(connection, windowId, &ordered);
            *info = (AeroSpaceNewWindowInfo){
                .pid = queriedPid(windows), .level = queriedLevel(windows), .parent = queriedParent(windows),
                .orderedIn = ordered != 0, .bounds = queriedBounds(windows),
            };
        }
        CFRelease(windows);
        return found;
    }
}
