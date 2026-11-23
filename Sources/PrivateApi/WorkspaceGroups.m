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
static void (*setGroupAlpha)(CFTypeRef, uint64_t, float);
static Class assignGroupClass, leaveGroupClass;
static bool windowSwapAvailable;
static os_log_t workspaceGroupTiming;

@protocol AeroWorkspaceGroupAssignment <NSObject>
- (instancetype)initWithSpaceID:(uint64_t)spaceID windows:(NSArray *)windows options:(uint32_t)options;
- (void)performWithWMBridgeDelegate;
@end
@protocol AeroWorkspaceGroupRemoval <NSObject>
- (instancetype)initWithWindows:(NSArray *)windows spaces:(NSArray *)spaces;
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
        setGroupAlpha = dlsym(sky, "SLSTransactionSetSpaceAlpha");
        leaveGroupClass = NSClassFromString(@"SLSBridgedRemoveWindowsFromSpacesOperation");
        windowSwapAvailable = available && setGroupAlpha &&
            groupMethod(leaveGroupClass, @"initWithWindows:spaces:", 4, '@') &&
            groupMethod(leaveGroupClass, @"performWithWMBridgeDelegate", 2, 'v');
    });
    return available;
}

bool AeroSpaceWindowSwapAvailable(void) {
    return AeroSpaceWorkspaceGroupsAvailable() && windowSwapAvailable;
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

static bool normalHomeExists(uint64_t home) {
    if (!home || home > INT64_MAX) return false;
    NSArray *displays = CFBridgingRelease(AeroSpaceCopyNativeDisplays());
    if (![displays isKindOfClass:NSArray.class] || !displays.count) return false;
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
    bool foundHome = false;
    for (NSDictionary *display in displays) {
        if (![display isKindOfClass:NSDictionary.class] ||
            ![display[@"Display Identifier"] isKindOfClass:NSString.class] || ![display[@"Display Identifier"] length] ||
            ![display[@"Spaces"] isKindOfClass:NSArray.class] || ![display[@"Spaces"] count] ||
            ![display[@"Current Space"] isKindOfClass:NSDictionary.class]) return false;
        uint64_t current;
        if (!groupNumber(display[@"Current Space"][@"id64"], &current)) return false;
        bool foundCurrent = false;
        for (NSDictionary *space in display[@"Spaces"]) {
            uint64_t identifier;
            int64_t type;
            if (![space isKindOfClass:NSDictionary.class] || !groupNumber(space[@"id64"], &identifier) ||
                [seen containsObject:@(identifier)] || ![space[@"type"] isKindOfClass:NSNumber.class] ||
                CFGetTypeID((__bridge CFTypeRef)space[@"type"]) == CFBooleanGetTypeID() ||
                !CFNumberGetValue((__bridge CFNumberRef)space[@"type"], kCFNumberSInt64Type, &type) || type < 0) return false;
            [seen addObject:@(identifier)];
            if (identifier == current) foundCurrent = true;
            if (identifier == home && type == 0) foundHome = true;
        }
        if (!foundCurrent) return false;
    }
    return foundHome;
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

static NSArray<NSNumber *> *windowGroupSpaces(CGWindowID windowId) {
    NSArray *membership = CFBridgingRelease(AeroSpaceCopyAllWindowSpaces(windowId));
    if (![membership isKindOfClass:NSArray.class]) return nil;
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
    for (id value in membership) {
        uint64_t identifier;
        if (!groupNumber(value, &identifier) || [seen containsObject:@(identifier)]) return nil;
        [seen addObject:@(identifier)];
    }
    return membership;
}

static bool assignWindowsToSpace(NSArray<NSNumber *> *windows, uint64_t target) {
    if (!windows.count) return true;
    // Selector 15 removes type 3 groups as well as ordinary native memberships.
    id<AeroWorkspaceGroupAssignment> operation = [(id<AeroWorkspaceGroupAssignment>)[assignGroupClass alloc]
        initWithSpaceID:target windows:windows options:15];
    if (!operation) return false;
    [operation performWithWMBridgeDelegate];
    double deadline = NSProcessInfo.processInfo.systemUptime + 1;
    do {
        bool ready = true;
        for (NSNumber *window in windows) {
            if (![windowGroupSpaces(window.unsignedIntValue) isEqual:@[@(target)]]) ready = false;
        }
        if (ready) return true;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.001]];
    } while (NSProcessInfo.processInfo.systemUptime < deadline);
    return false;
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
            return assignWindowsToSpace(windows, groupId);
        } @catch (NSException *exception) {
            return false;
        }
    }
}

bool AeroSpaceReturnWindowsFromWorkspaceGroup(const CGWindowID *windowIds, size_t count,
                                             uint64_t groupId, CFStringRef uniqueName, uint64_t home) {
    if ((!windowIds && count) || !uniqueName || !AeroSpaceWorkspaceGroupsAvailable()) return false;
    @autoreleasepool {
        @try {
            if (groupState(groupId, (__bridge NSString *)uniqueName) != AeroSpaceParkingSpaceStateOwned ||
                !normalHomeExists(home)) return false;
            NSSet *allowed = [NSSet setWithArray:@[@(groupId), @(home)]];
            NSMutableArray<NSNumber *> *windows = [NSMutableArray arrayWithCapacity:count];
            for (size_t i = 0; i < count; ++i) {
                if (!windowIds[i]) return false;
                NSArray *membership = windowGroupSpaces(windowIds[i]);
                // Validate every source before submitting the batch. Never pull a
                // window back from a desktop or fullscreen Space we do not own.
                if (!membership.count || ![[NSSet setWithArray:membership] isSubsetOfSet:allowed]) return false;
                if (![membership isEqual:@[@(home)]]) [windows addObject:@(windowIds[i])];
            }
            // Ordinary native moves leave the hidden group attached. Reassigning
            // with selector 15 restores exclusive home membership without showing the group.
            return assignWindowsToSpace(windows, home);
        } @catch (NSException *exception) {
            return false;
        }
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
        if (!normalHomeExists(home)) return false;
        NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
        if (!windows) return false;
        NSMutableArray<NSNumber *> *restore = [NSMutableArray array];
        NSSet *owned = [NSSet setWithArray:groups.allKeys];
        for (NSDictionary *window in windows) {
            NSNumber *identifier = window[(__bridge NSString *)kCGWindowNumber];
            NSArray *membership = windowGroupSpaces(identifier.unsignedIntValue);
            if (!membership) return false;
            NSSet *members = [NSSet setWithArray:membership];
            if ([members intersectsSet:owned] && [members isSubsetOfSet:owned]) [restore addObject:identifier];
        }
        for (NSNumber *identifier in restore) {
            CGWindowID wid = identifier.unsignedIntValue;
            NSArray *membership = windowGroupSpaces(wid);
            if (!membership || ![[NSSet setWithArray:membership] isSubsetOfSet:owned]) return false;
            if (!membership.count) continue;
            if (!AeroSpaceMoveWindowsToNativeSpace(&wid, 1, home)) return false;
        }
        double deadline = NSProcessInfo.processInfo.systemUptime + 2;
        bool restored;
        do {
            restored = true;
            for (NSNumber *identifier in restore) {
                NSArray *membership = windowGroupSpaces(identifier.unsignedIntValue);
                // A closed window no longer needs restoration. An unknown query
                // is not equivalent to an empty membership list.
                if (!membership || (membership.count && ![membership containsObject:@(home)])) restored = false;
            }
            if (!restored) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
        } while (!restored && NSProcessInfo.processInfo.systemUptime < deadline);
        if (!restored || !validGroups(groups, true)) return false;
        // A newly created window may have joined a group while restoration was
        // pending. Retry recovery instead of deleting its only Space.
        windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
        if (!windows) return false;
        for (NSDictionary *window in windows) {
            NSNumber *identifier = window[(__bridge NSString *)kCGWindowNumber];
            NSArray *membership = windowGroupSpaces(identifier.unsignedIntValue);
            if (!membership) return false;
            NSSet *members = [NSSet setWithArray:membership];
            if ([members intersectsSet:owned] && [members isSubsetOfSet:owned]) return false;
        }
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

// Unlike groupState, this doesn't list every Space first, so it can't tell a missing group from an unreadable one.
// Either way the group isn't ours to use
static bool ownsGroup(uint64_t identifier, NSString *name) {
    if (!identifier || ![name isKindOfClass:NSString.class] || !name.length) return false;
    NSDictionary *values = CFBridgingRelease(copyGroupValues(groupConnection(), identifier));
    uint64_t actualId, type;
    return [values isKindOfClass:NSDictionary.class] && groupNumber(values[@"id64"], &actualId) &&
        groupNumber(values[@"type"], &type) && actualId == identifier && type == 3 && [values[@"name"] isEqual:name];
}

static NSArray<NSNumber *> *windowNumbers(CFArrayRef raw) {
    NSArray *windows = (__bridge NSArray *)raw;
    if (![windows isKindOfClass:NSArray.class]) return nil;
    for (id window in windows) {
        uint64_t identifier;
        if (!groupNumber(window, &identifier) || identifier > UINT32_MAX) return nil;
    }
    return windows;
}

// WindowManager applies the operation a millisecond or two later: see awaitMemberships
static bool submitMove(NSArray<NSNumber *> *windows, uint64_t target, uint32_t removedTypes) {
    if (!windows.count) return true;
    id<AeroWorkspaceGroupAssignment> operation = [(id<AeroWorkspaceGroupAssignment>)[assignGroupClass alloc]
        initWithSpaceID:target windows:windows options:removedTypes];
    if (!operation) return false;
    [operation performWithWMBridgeDelegate];
    return true;
}

static bool windowExists(CGWindowID windowId) {
    CFMutableArrayRef ids = CFArrayCreateMutable(NULL, 1, NULL);
    if (!ids) return true;
    CFArrayAppendValue(ids, (void *)(uintptr_t)windowId);
    NSArray *records = CFBridgingRelease(CGWindowListCreateDescriptionFromArray(ids));
    CFRelease(ids);
    return !records || records.count;
}

static bool awaitMemberships(NSArray<NSNumber *> *windows, NSArray<NSNumber *> *spaces, useconds_t pause) {
    if (!windows.count) return true;
    NSSet<NSNumber *> *expected = [NSSet setWithArray:spaces];
    double deadline = NSProcessInfo.processInfo.systemUptime + 1;
    do {
        bool ready = true;
        for (NSNumber *window in windows) {
            NSArray<NSNumber *> *membership = windowGroupSpaces(window.unsignedIntValue);
            if (membership && [[NSSet setWithArray:membership] isEqual:expected]) continue;
            // A window that was closed meanwhile has no spaces, and nothing is left to wait for
            if (!membership.count && !windowExists(window.unsignedIntValue)) continue;
            ready = false;
            break;
        }
        if (ready) return true;
        usleep(pause);
    } while (NSProcessInfo.processInfo.systemUptime < deadline);
    return false;
}

static bool commitGroupAlphas(uint64_t first, float firstAlpha, uint64_t second, float secondAlpha) {
    CFTypeRef transaction = createGroupTransaction(groupConnection());
    if (!transaction) return false;
    setGroupAlpha(transaction, first, firstAlpha);
    setGroupAlpha(transaction, second, secondAlpha);
    commitGroupTransaction(transaction, true);
    CFRelease(transaction);
    return true;
}

bool AeroSpacePrepareWindowSwapGroups(uint64_t arriving, uint64_t leaving, CFDictionaryRef rawNames) {
    if (!rawNames || !arriving || !leaving || arriving == leaving || !AeroSpaceWindowSwapAvailable()) return false;
    @autoreleasepool {
        NSDictionary *names = (__bridge NSDictionary *)rawNames;
        if (!ownsGroup(arriving, names[@(arriving)]) || !ownsGroup(leaving, names[@(leaving)])) return false;
        CFTypeRef transaction = createGroupTransaction(groupConnection());
        if (!transaction) return false;
        setGroupAlpha(transaction, arriving, 0);
        setGroupAlpha(transaction, leaving, 1);
        showGroup(transaction, arriving);
        showGroup(transaction, leaving);
        commitGroupTransaction(transaction, true);
        CFRelease(transaction);
        return true;
    }
}

bool AeroSpaceStageWindowSwap(CFArrayRef reveal, CFArrayRef hide, AeroSpaceWindowSwapSpaces spaces) {
    if (!reveal || !hide || !AeroSpaceWindowSwapAvailable()) return false;
    NSNumber *home = @(spaces.home), *parking = @(spaces.parking), *arriving = @(spaces.arriving), *leaving = @(spaces.leaving);
    if (!parking.unsignedLongLongValue || !arriving.unsignedLongLongValue || !leaving.unsignedLongLongValue) return false;
    if (!home.unsignedLongLongValue) return false;
    @autoreleasepool {
        @try {
            NSArray<NSNumber *> *incoming = windowNumbers(reveal), *outgoing = windowNumbers(hide);
            if (!incoming || !outgoing) return false;
            // Unlike the functions above, this one doesn't ask WindowServer where the windows are before it moves
            // them: the caller has just done that, and asking again takes a millisecond of every switch.
            // Selector 15 takes the windows out of the parking group: they're on screen in `arriving`, with alpha 0.
            // Selector 8 removes other groups only: the windows stay on the desktop, and `leaving` draws them as before.
            if (!submitMove(incoming, arriving.unsignedLongLongValue, 15) ||
                !submitMove(outgoing, leaving.unsignedLongLongValue, 8)) return false;
            // The windows must be in `arriving` before they join the desktop: without its alpha they'd show
            if (!awaitMemberships(incoming, @[arriving], 250)) return false;
            // Selector 7 leaves groups alone: the windows join the desktop and stay in `arriving`
            if (!submitMove(incoming, home.unsignedLongLongValue, 7)) return false;
            return awaitMemberships(incoming, @[arriving, home], 250) && awaitMemberships(outgoing, @[home, leaving], 250);
        } @catch (NSException *exception) {
            return false;
        }
    }
}

bool AeroSpaceCommitWindowSwap(AeroSpaceWindowSwapSpaces spaces) {
    if (!spaces.arriving || !spaces.leaving || !AeroSpaceWindowSwapAvailable()) return false;
    return commitGroupAlphas(spaces.arriving, 1, spaces.leaving, 0);
}

bool AeroSpaceSettleWindowSwap(CFArrayRef reveal, CFArrayRef hide, AeroSpaceWindowSwapSpaces spaces) {
    if (!reveal || !hide || !AeroSpaceWindowSwapAvailable()) return false;
    NSNumber *home = @(spaces.home), *parking = @(spaces.parking), *arriving = @(spaces.arriving);
    uint64_t leaving = spaces.leaving;
    if (!parking.unsignedLongLongValue) return false;
    @autoreleasepool {
        @try {
            NSArray<NSNumber *> *incoming = windowNumbers(reveal), *outgoing = windowNumbers(hide);
            if (!incoming || !outgoing) return false;
            // Selector 15 again: off the desktop and out of `leaving`, whose alpha kept the windows unseen until now
            if (!submitMove(outgoing, parking.unsignedLongLongValue, 15)) return false;
            if (incoming.count) {
                id<AeroWorkspaceGroupRemoval> operation = [(id<AeroWorkspaceGroupRemoval>)[leaveGroupClass alloc]
                    initWithWindows:incoming spaces:@[arriving]];
                if (!operation) return false;
                [operation performWithWMBridgeDelegate];
            }
            if (!awaitMemberships(outgoing, @[parking], 250) || !awaitMemberships(incoming, @[home], 250)) return false;
            // Only now that both groups are empty: with alpha 0 in `arriving`, the revealed windows would vanish again
            return commitGroupAlphas(arriving.unsignedLongLongValue, 0, leaving, 1);
        } @catch (NSException *exception) {
            return false;
        }
    }
}
