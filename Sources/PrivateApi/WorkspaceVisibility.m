#import "include/private.h"
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

static int (*nativeConnection)(void);
static CFArrayRef (*copyNativeDisplays)(int);
static CFArrayRef (*copyNativeSpaces)(int, int, CFArrayRef);
static uint64_t (*activeNativeSpace)(int);
static Class createSpaceClass, moveWindowsClass, destroySpaceClass;

@protocol AeroNativeSpaceCreation <NSObject>
- (instancetype)initWithOptions:(uint32_t)options values:(NSDictionary *)values;
- (id)performWithWMBridgeDelegate;
@end
@protocol AeroNativeSpaceMutation <NSObject>
- (instancetype)initWithWindows:(NSArray *)windows spaceID:(uint64_t)spaceID;
- (instancetype)initWithSpaceID:(uint64_t)spaceID;
- (void)performWithWMBridgeDelegate;
@end
@protocol AeroNativeSpaceResult <NSObject>
- (uint64_t)spaceID;
@end

// Check the ABI before calling an Objective-C entry point absent from the SDK.
static bool hasMethod(Class cls, NSString *name, unsigned arguments, char resultType) {
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(name));
    if (!method || method_getNumberOfArguments(method) != arguments) return false;
    char type[16] = {0};
    method_getReturnType(method, type, sizeof(type));
    return type[0] == resultType;
}

bool AeroSpaceNativeVisibilityAvailable(void) {
    static dispatch_once_t once;
    static bool available;
    dispatch_once(&once, ^{
        void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
        if (!sky) return;
        nativeConnection = dlsym(sky, "SLSMainConnectionID");
        copyNativeDisplays = dlsym(sky, "SLSCopyManagedDisplaySpaces");
        copyNativeSpaces = dlsym(sky, "SLSCopySpacesForWindows");
        activeNativeSpace = dlsym(sky, "SLSGetActiveSpace");
        createSpaceClass = NSClassFromString(@"SLSBridgedSpaceCreateOperation");
        moveWindowsClass = NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
        destroySpaceClass = NSClassFromString(@"SLSBridgedSpaceDestroyOperation");
        available = nativeConnection && copyNativeDisplays && copyNativeSpaces && activeNativeSpace &&
            hasMethod(createSpaceClass, @"initWithOptions:values:", 4, '@') &&
            hasMethod(createSpaceClass, @"performWithWMBridgeDelegate", 2, '@') &&
            hasMethod(moveWindowsClass, @"initWithWindows:spaceID:", 4, '@') &&
            hasMethod(moveWindowsClass, @"performWithWMBridgeDelegate", 2, 'v') &&
            hasMethod(destroySpaceClass, @"initWithSpaceID:", 3, '@') &&
            hasMethod(destroySpaceClass, @"performWithWMBridgeDelegate", 2, 'v');
    });
    return available;
}

CFArrayRef AeroSpaceCopyNativeDisplays(void) {
    return AeroSpaceNativeVisibilityAvailable() ? copyNativeDisplays(nativeConnection()) : NULL;
}

CFArrayRef AeroSpaceCopyNativeWindowSpaces(CGWindowID windowId) {
    if (!windowId || !AeroSpaceNativeVisibilityAvailable()) return NULL;
    return copyNativeSpaces(nativeConnection(), 7, (__bridge CFArrayRef)@[@(windowId)]);
}

uint64_t AeroSpaceActiveNativeSpace(void) {
    return AeroSpaceNativeVisibilityAvailable() ? activeNativeSpace(nativeConnection()) : 0;
}

uint64_t AeroSpaceCreateParkingSpace(CFStringRef uniqueName) {
    if (!uniqueName || !CFStringGetLength(uniqueName) || !AeroSpaceNativeVisibilityAvailable()) return 0;
    @autoreleasepool {
        @try {
            NSDictionary *values = @{@"type": @0, @"name": (__bridge NSString *)uniqueName};
            id<AeroNativeSpaceCreation> operation = [(id<AeroNativeSpaceCreation>)[createSpaceClass alloc] initWithOptions:0 values:values];
            if (!operation) return 0;
            id<AeroNativeSpaceResult> result = [operation performWithWMBridgeDelegate];
            uint64_t spaceId = 0;
            if (hasMethod([result class], @"spaceID", 2, 'Q')) {
                spaceId = [result spaceID];
            }
            return spaceId;
        } @catch (NSException *exception) {
            return 0;
        }
    }
}

bool AeroSpaceMoveWindowsToNativeSpace(const CGWindowID *windowIds, size_t count, uint64_t spaceId) {
    if (!spaceId || (!windowIds && count) || !AeroSpaceNativeVisibilityAvailable()) return false;
    if (count == 0) return true;
    @autoreleasepool {
        @try {
            NSMutableArray *windows = [NSMutableArray arrayWithCapacity:count];
            for (size_t i = 0; i < count; ++i) {
                if (!windowIds[i]) return false;
                [windows addObject:@(windowIds[i])];
            }
            id<AeroNativeSpaceMutation> operation = [(id<AeroNativeSpaceMutation>)[moveWindowsClass alloc] initWithWindows:windows spaceID:spaceId];
            if (!operation) return false;
            [operation performWithWMBridgeDelegate];
            return true;
        } @catch (NSException *exception) {
            return false;
        }
    }
}

static bool spaceInteger(id value, int64_t *number) {
    return [value isKindOfClass:[NSNumber class]] &&
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        CFNumberGetValue((__bridge CFNumberRef)value, kCFNumberSInt64Type, number);
}

AeroSpaceParkingSpaceState AeroSpaceParkingSpaceStateInSnapshot(CFArrayRef raw,
                                                               uint64_t spaceId,
                                                               CFStringRef uniqueName) {
    if (!spaceId || spaceId > INT64_MAX || !uniqueName ||
        CFGetTypeID(uniqueName) != CFStringGetTypeID() || !CFStringGetLength(uniqueName) ||
        !raw || CFGetTypeID(raw) != CFArrayGetTypeID() || !CFArrayGetCount(raw)) {
        return AeroSpaceParkingSpaceStateUnknown;
    }
    @autoreleasepool {
        AeroSpaceParkingSpaceState result = AeroSpaceParkingSpaceStateAbsent;
        NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
        for (id display in (__bridge NSArray *)raw) {
            if (![display isKindOfClass:[NSDictionary class]] ||
                ![display[@"Display Identifier"] isKindOfClass:[NSString class]] ||
                ![display[@"Display Identifier"] length] ||
                ![display[@"Spaces"] isKindOfClass:[NSArray class]] ||
                ![display[@"Current Space"] isKindOfClass:[NSDictionary class]]) {
                return AeroSpaceParkingSpaceStateUnknown;
            }
            int64_t current;
            if (!spaceInteger(display[@"Current Space"][@"id64"], &current) || current <= 0) {
                return AeroSpaceParkingSpaceStateUnknown;
            }
            bool foundCurrent = false;
            for (id space in display[@"Spaces"]) {
                int64_t identifier, type;
                if (![space isKindOfClass:[NSDictionary class]] ||
                    !spaceInteger(space[@"id64"], &identifier) || identifier <= 0 ||
                    !spaceInteger(space[@"type"], &type) || type < 0 ||
                    [seen containsObject:@(identifier)]) {
                    return AeroSpaceParkingSpaceStateUnknown;
                }
                [seen addObject:@(identifier)];
                if (identifier == current) foundCurrent = true;
                if ((uint64_t)identifier == spaceId) {
                    // Creation, normal operation and recovery must agree on the
                    // same managed record. A separate SpaceCopyName query is not
                    // evidence that this record's unique name still matches.
                    id name = space[@"name"];
                    result = type == 0 && [name isKindOfClass:[NSString class]] &&
                        [name isEqualToString:(__bridge NSString *)uniqueName]
                        ? AeroSpaceParkingSpaceStateOwned : AeroSpaceParkingSpaceStateForeign;
                }
            }
            if (!foundCurrent) return AeroSpaceParkingSpaceStateUnknown;
        }
        return result;
    }
}

static AeroSpaceParkingSpaceState parkingSpaceState(uint64_t spaceId, CFStringRef uniqueName) {
    CFArrayRef raw = copyNativeDisplays(nativeConnection());
    AeroSpaceParkingSpaceState result = AeroSpaceParkingSpaceStateInSnapshot(raw, spaceId, uniqueName);
    if (raw) CFRelease(raw);
    return result;
}

bool AeroSpaceRecoverParkingSpace(uint64_t spaceId, CFStringRef uniqueName) {
    if (!spaceId || !uniqueName || !AeroSpaceNativeVisibilityAvailable()) return false;
    @autoreleasepool {
        AeroSpaceParkingSpaceState state = parkingSpaceState(spaceId, uniqueName);
        if (state == AeroSpaceParkingSpaceStateAbsent) return true;
        if (state != AeroSpaceParkingSpaceStateOwned) return false;
        @try {
            id<AeroNativeSpaceMutation> operation = [(id<AeroNativeSpaceMutation>)[destroySpaceClass alloc] initWithSpaceID:spaceId];
            if (!operation) return false;
            [operation performWithWMBridgeDelegate];
            double deadline = NSProcessInfo.processInfo.systemUptime + 2;
            do {
                state = parkingSpaceState(spaceId, uniqueName);
                if (state == AeroSpaceParkingSpaceStateAbsent) return true;
                if (state == AeroSpaceParkingSpaceStateForeign) return false;
                // Keep the asynchronous bridge alive while its operation is delivered.
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
            } while (NSProcessInfo.processInfo.systemUptime < deadline);
        } @catch (NSException *exception) {
            return false;
        }
        return false;
    }
}
