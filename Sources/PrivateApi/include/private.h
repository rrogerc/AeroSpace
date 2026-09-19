#ifndef private_header_h
#define private_header_h

#import <ApplicationServices/ApplicationServices.h>

// Potential alternative 1?
// func allWindowsOnCurrentMacOsSpace() {
//     let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
//     let windowsListInfo = CGWindowListCopyWindowInfo(options, CGWindowID(0))
//     let infoList = windowsListInfo as! [[String:Any]]
//     let windows = infoList.filter { $0["kCGWindowLayer"] as! Int == 0 }
//     print(windows.count)
//     for window in windows {
//             print(window)
//             print("Name: \(window["kCGWindowOwnerName"].unsafelyUnwrapped)")
//             print("PID: \(window["kCGWindowOwnerPID"].unsafelyUnwrapped)")
//             print("window ID: \(window["kCGWindowNumber"])")
//             print("---")
//     }
// }
//
// Alternative 2:
// @_silgen_name("_AXUIElementGetWindow")
// @discardableResult
// func _AXUIElementGetWindow(_ axUiElement: AXUIElement, _ id: inout CGWindowID) -> AXError
AXError _AXUIElementGetWindow(AXUIElementRef element, uint32_t *identifier);

// Resolved at runtime so an unavailable private API can use the public focus path.
bool AeroSpacePrivateFocusAvailable(void);
CGError AeroSpaceMakeKeyWindow(pid_t pid, CGWindowID windowId);

typedef struct {
    CGWindowID windowId;
    pid_t pid;
    int32_t layer;
    CGRect bounds;
} AeroSpaceWindowInfo;

// Copies only geometry and ownership. Titles are never requested. Missing symbols
// or query failures return an error so callers can use public WindowServer APIs.
CGError AeroSpaceCopyWindowInfo(const CGWindowID *ids, size_t count,
                               AeroSpaceWindowInfo *output, size_t capacity,
                               size_t *outputCount);

// Native workspace visibility. All functions must run outside the main thread.
// A successful move reports submission; callers must observe membership before focus.
bool AeroSpaceNativeVisibilityAvailable(void);
CFArrayRef AeroSpaceCopyNativeDisplays(void) CF_RETURNS_RETAINED;
CFArrayRef AeroSpaceCopyNativeWindowSpaces(CGWindowID windowId) CF_RETURNS_RETAINED;
uint64_t AeroSpaceActiveNativeSpace(void);
uint64_t AeroSpaceCreateParkingSpace(CFStringRef uniqueName);
bool AeroSpaceMoveWindowsToNativeSpace(const CGWindowID *windowIds, size_t count, uint64_t spaceId);
typedef CF_ENUM(int32_t, AeroSpaceParkingSpaceState) {
    AeroSpaceParkingSpaceStateUnknown,
    AeroSpaceParkingSpaceStateAbsent,
    AeroSpaceParkingSpaceStateOwned,
    AeroSpaceParkingSpaceStateForeign,
};
// Pure inspection of one complete managed-display snapshot. Unknown must never
// be treated as permission to destroy a Space or evidence of successful recovery.
AeroSpaceParkingSpaceState AeroSpaceParkingSpaceStateInSnapshot(CFArrayRef displays,
                                                               uint64_t spaceId,
                                                               CFStringRef uniqueName);
// Only removes a Space whose ID and unique name both match. Deleting it returns
// its windows to a remaining desktop, including windows created after registration.
bool AeroSpaceRecoverParkingSpace(uint64_t spaceId, CFStringRef uniqueName);

// Connection-owned groups are not user-facing native desktops. Window membership
// stays fixed across workspace switches; visibility changes in one transaction.
bool AeroSpaceWorkspaceGroupsAvailable(void);
uint64_t AeroSpaceCreateWorkspaceGroup(CFStringRef uniqueName);
CFArrayRef AeroSpaceCopyAllWindowSpaces(CGWindowID windowId) CF_RETURNS_RETAINED;
bool AeroSpaceAssignWindowsToWorkspaceGroup(const CGWindowID *windowIds, size_t count,
                                           uint64_t groupId, CFStringRef uniqueName);
// Dictionaries map group IDs (CFNumber) to their unique names (CFString).
bool AeroSpaceCommitWorkspaceGroupVisibility(CFDictionaryRef show, CFDictionaryRef hide);
// Restores windows with no other membership before destroying owned groups.
// Windows already in another native Space retain that membership.
bool AeroSpaceRestoreWorkspaceGroups(CFDictionaryRef groups, uint64_t home);

#endif
