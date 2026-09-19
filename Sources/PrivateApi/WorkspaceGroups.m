#import "include/private.h"
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <os/signpost.h>

static int (*groupConnection)(void);
static uint64_t (*createGroup)(int, uint32_t, CFDictionaryRef);
static void (*destroyGroup)(int, uint64_t);
static CFDictionaryRef (*copyGroupValues)(int, uint64_t);
static CFArrayRef (*copyGroups)(int, uint32_t);
static CFArrayRef (*copyGroupMembership)(int, uint32_t, CFArrayRef);
static CFTypeRef (*createGroupTransaction)(int);
static void (*showGroup)(CFTypeRef, uint64_t);
static void (*hideGroup)(CFTypeRef, uint64_t);
static void (*commitGroupTransaction)(CFTypeRef, bool);
static Class assignGroupClass;
static os_log_t workspaceGroupTiming;

@protocol AeroWorkspaceGroupAssignment <NSObject>
- (instancetype)initWithSpaceID:(uint64_t)spaceID windows:(NSArray *)windows options:(uint32_t)options;
- (void)performWithWMBridgeDelegate;
@end

static bool groupMethod(Class cls, NSString *name, unsigned arguments, char resultType) {
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(name));
    if (!method || method_getNumberOfArguments(method) != arguments) return false;
    char type[16] = {0};
    method_getReturnType(method, type, sizeof(type));
    return type[0] == resultType;
}

bool AeroSpaceWorkspaceGroupsAvailable(void) {
    static dispatch_once_t once;
    static bool available;
    dispatch_once(&once, ^{
        workspaceGroupTiming = os_log_create("bobko.aerospace", OS_LOG_CATEGORY_POINTS_OF_INTEREST);
        if (!AeroSpaceNativeVisibilityAvailable()) return;
        void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
        if (!sky) return;
        groupConnection = dlsym(sky, "SLSMainConnectionID");
        createGroup = dlsym(sky, "SLSSpaceCreate");
        destroyGroup = dlsym(sky, "SLSSpaceDestroy");
        copyGroupValues = dlsym(sky, "SLSSpaceCopyValues");
        copyGroups = dlsym(sky, "SLSCopySpaces");
        copyGroupMembership = dlsym(sky, "SLSCopySpacesForWindows");
        createGroupTransaction = dlsym(sky, "SLSTransactionCreate");
        showGroup = dlsym(sky, "SLSTransactionShowSpace");
        hideGroup = dlsym(sky, "SLSTransactionHideSpace");
        commitGroupTransaction = dlsym(sky, "SLSTransactionCommit");
        assignGroupClass = NSClassFromString(@"SLSBridgedSpaceAddWindowsAndRemoveFromSpacesOperation");
        available = groupConnection && createGroup && destroyGroup && copyGroupValues && copyGroups &&
            copyGroupMembership && createGroupTransaction && showGroup && hideGroup && commitGroupTransaction &&
            groupMethod(assignGroupClass, @"initWithSpaceID:windows:options:", 5, '@') &&
            groupMethod(assignGroupClass, @"performWithWMBridgeDelegate", 2, 'v');
    });
    return available;
}

static bool groupNumber(id value, uint64_t *result) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return false;
    int64_t integer;
    if (!CFNumberGetValue((__bridge CFNumberRef)value, kCFNumberSInt64Type, &integer) || integer <= 0) return false;
    *result = (uint64_t)integer;
    return true;
}

static AeroSpaceParkingSpaceState groupState(uint64_t identifier, NSString *name) {
    if (!identifier || ![name isKindOfClass:NSString.class] || !name.length) return AeroSpaceParkingSpaceStateUnknown;
    NSArray *all = CFBridgingRelease(copyGroups(groupConnection(), 15));
    if (![all isKindOfClass:NSArray.class]) return AeroSpaceParkingSpaceStateUnknown;
    if (![all containsObject:@(identifier)]) return AeroSpaceParkingSpaceStateAbsent;
    NSDictionary *values = CFBridgingRelease(copyGroupValues(groupConnection(), identifier));
    uint64_t actualId, type;
    if (![values isKindOfClass:NSDictionary.class] || !groupNumber(values[@"id64"], &actualId) ||
        !groupNumber(values[@"type"], &type)) return AeroSpaceParkingSpaceStateUnknown;
    return actualId == identifier && type == 3 && [values[@"name"] isEqual:name]
        ? AeroSpaceParkingSpaceStateOwned : AeroSpaceParkingSpaceStateForeign;
}

static bool validGroups(NSDictionary *groups, bool allowAbsent) {
    if (![groups isKindOfClass:NSDictionary.class]) return false;
    for (id key in groups) {
        uint64_t identifier;
        if (!groupNumber(key, &identifier)) return false;
        AeroSpaceParkingSpaceState state = groupState(identifier, groups[key]);
        if (state != AeroSpaceParkingSpaceStateOwned && !(allowAbsent && state == AeroSpaceParkingSpaceStateAbsent)) return false;
    }
    return true;
}

uint64_t AeroSpaceCreateWorkspaceGroup(CFStringRef uniqueName) {
    if (!uniqueName || CFGetTypeID(uniqueName) != CFStringGetTypeID() ||
        !CFStringGetLength(uniqueName) || !AeroSpaceWorkspaceGroupsAvailable()) return 0;
    @autoreleasepool {
        // Option 1 assigns lifetime and visibility control to this connection.
        // WindowServer removes the group if the connection dies, including SIGKILL.
        uint64_t identifier = createGroup(groupConnection(), 1,
            (__bridge CFDictionaryRef)@{@"type": @0, @"name": (__bridge NSString *)uniqueName});
        // Retain the returned ID even if later validation fails: the caller must
        // keep its cleanup identity instead of losing a possibly live resource.
        return identifier;
    }
}

CFArrayRef AeroSpaceCopyAllWindowSpaces(CGWindowID windowId) {
    if (!windowId || !AeroSpaceWorkspaceGroupsAvailable()) return NULL;
    // Selector 7 omits connection-owned (type 3) memberships.
    return copyGroupMembership(groupConnection(), 15, (__bridge CFArrayRef)@[@(windowId)]);
}

bool AeroSpaceAssignWindowsToWorkspaceGroup(const CGWindowID *windowIds, size_t count,
                                           uint64_t groupId, CFStringRef uniqueName) {
    if ((!windowIds && count) || !uniqueName || !AeroSpaceWorkspaceGroupsAvailable()) return false;
    @autoreleasepool {
        if (groupState(groupId, (__bridge NSString *)uniqueName) != AeroSpaceParkingSpaceStateOwned) return false;
        if (!count) return true;
        @try {
            NSMutableArray *windows = [NSMutableArray arrayWithCapacity:count];
            for (size_t i = 0; i < count; ++i) {
                if (!windowIds[i]) return false;
                [windows addObject:@(windowIds[i])];
            }
            // Selector 15 removes a previous type 3 group as well as native home.
            // Selector 7 silently leaves both workspace memberships attached.
            id<AeroWorkspaceGroupAssignment> operation = [(id<AeroWorkspaceGroupAssignment>)[assignGroupClass alloc]
                initWithSpaceID:groupId windows:windows options:15];
            if (!operation) return false;
            [operation performWithWMBridgeDelegate];
            double deadline = NSProcessInfo.processInfo.systemUptime + 1;
            do {
                bool ready = true;
                for (NSNumber *window in windows) {
                    NSArray *membership = CFBridgingRelease(AeroSpaceCopyAllWindowSpaces(window.unsignedIntValue));
                    if (![membership isEqual:@[@(groupId)]]) ready = false;
                }
                if (ready) return true;
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.001]];
            } while (NSProcessInfo.processInfo.systemUptime < deadline);
        } @catch (NSException *exception) {
            return false;
        }
        return false;
    }
}

bool AeroSpaceCommitWorkspaceGroupVisibility(CFDictionaryRef rawShow, CFDictionaryRef rawHide) {
    if (!rawShow || !rawHide || !AeroSpaceWorkspaceGroupsAvailable()) return false;
    @autoreleasepool {
        NSDictionary *show = (__bridge NSDictionary *)rawShow, *hide = (__bridge NSDictionary *)rawHide;
        os_signpost_id_t timing = os_signpost_id_generate(workspaceGroupTiming);
        os_signpost_interval_begin(workspaceGroupTiming, timing, "validateWorkspaceGroups");
        bool valid = validGroups(show, false) && validGroups(hide, false);
        os_signpost_interval_end(workspaceGroupTiming, timing, "validateWorkspaceGroups");
        if (!valid) return false;
        for (NSNumber *identifier in show) if (hide[identifier]) return false;
        if (!show.count && !hide.count) return true;
        CFTypeRef transaction = createGroupTransaction(groupConnection());
        if (!transaction) return false;
        for (NSNumber *identifier in show) showGroup(transaction, identifier.unsignedLongLongValue);
        for (NSNumber *identifier in hide) hideGroup(transaction, identifier.unsignedLongLongValue);
        os_signpost_interval_begin(workspaceGroupTiming, timing, "commitWorkspaceGroups");
        commitGroupTransaction(transaction, true);
        os_signpost_interval_end(workspaceGroupTiming, timing, "commitWorkspaceGroups");
        CFRelease(transaction);
        return true;
    }
}

bool AeroSpaceRestoreWorkspaceGroups(CFDictionaryRef rawGroups, uint64_t home) {
    if (!rawGroups || !home || !AeroSpaceWorkspaceGroupsAvailable()) return false;
    @autoreleasepool {
        NSDictionary *groups = (__bridge NSDictionary *)rawGroups;
        if (!validGroups(groups, true)) return false;
        if (!groups.count) return true;
        NSArray *displays = CFBridgingRelease(AeroSpaceCopyNativeDisplays());
        bool homeExists = false;
        for (NSDictionary *display in displays) for (NSDictionary *space in display[@"Spaces"]) {
            if ([space[@"id64"] unsignedLongLongValue] == home && [space[@"type"] intValue] == 0) homeExists = true;
        }
        if (!homeExists) return false;
        NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
        if (!windows) return false;
        NSMutableArray<NSNumber *> *restore = [NSMutableArray array];
        NSSet *owned = [NSSet setWithArray:groups.allKeys];
        for (NSDictionary *window in windows) {
            NSNumber *identifier = window[(__bridge NSString *)kCGWindowNumber];
            NSArray *membership = CFBridgingRelease(AeroSpaceCopyAllWindowSpaces(identifier.unsignedIntValue));
            if (!membership) return false;
            NSSet *members = [NSSet setWithArray:membership];
            if ([members intersectsSet:owned] && [members isSubsetOfSet:owned]) [restore addObject:identifier];
        }
        for (NSNumber *identifier in restore) {
            CGWindowID wid = identifier.unsignedIntValue;
            if (!AeroSpaceMoveWindowsToNativeSpace(&wid, 1, home)) return false;
        }
        double deadline = NSProcessInfo.processInfo.systemUptime + 2;
        bool restored;
        do {
            restored = true;
            for (NSNumber *identifier in restore) {
                NSArray *membership = CFBridgingRelease(AeroSpaceCopyAllWindowSpaces(identifier.unsignedIntValue));
                // A closed window no longer needs restoration. An unknown query
                // is not equivalent to an empty membership list.
                if (!membership || (membership.count && ![membership containsObject:@(home)])) restored = false;
            }
            if (!restored) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
        } while (!restored && NSProcessInfo.processInfo.systemUptime < deadline);
        if (!restored || !validGroups(groups, true)) return false;
        for (NSNumber *identifier in groups) {
            if (groupState(identifier.unsignedLongLongValue, groups[identifier]) == AeroSpaceParkingSpaceStateOwned) {
                destroyGroup(groupConnection(), identifier.unsignedLongLongValue);
            }
        }
        for (NSNumber *identifier in groups) {
            if (groupState(identifier.unsignedLongLongValue, groups[identifier]) != AeroSpaceParkingSpaceStateAbsent) return false;
        }
        return true;
    }
}
