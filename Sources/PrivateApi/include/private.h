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
// Tells an app that it's active and that windowId is its key window (active = true), or that it's inactive again,
// without making it the frontmost app. The app draws its windows accordingly: the title bar, and the shadow.
// The app that is really frontmost isn't told anything, and keeps the keyboard.
CGError AeroSpaceSetAppLooksActive(pid_t pid, CGWindowID windowId, bool active);

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
// Returns only windows belonging to the owned group/home, and waits for exclusive
// normal-home membership. The group is never activated or shown.
bool AeroSpaceReturnWindowsFromWorkspaceGroup(const CGWindowID *windowIds, size_t count,
                                             uint64_t groupId, CFStringRef uniqueName, uint64_t home);
// Dictionaries map group IDs (CFNumber) to their unique names (CFString).
bool AeroSpaceCommitWorkspaceGroupVisibility(CFDictionaryRef show, CFDictionaryRef hide);
// Restores windows with no other membership before destroying owned groups.
// Windows already in another native Space retain that membership.
bool AeroSpaceRestoreWorkspaceGroups(CFDictionaryRef groups, uint64_t home);

// A swap shows the windows of one workspace and hides the windows of another one in the same frame.
// A window can't join the desktop in a transaction of this connection: WindowManager shows it a few milliseconds
// after the request, at a moment of its own. But the alpha of a group that this connection owns can change in a
// transaction, and while a group is shown, its alpha applies to all its windows, also to a window that is on the
// desktop as well. So a swap needs two shown groups: `arriving` with alpha 0, and `leaving` with alpha 1.
//   1. Stage: the windows to reveal move from `parking` to `arriving` and join the desktop there, unseen.
//      The windows to hide join `leaving`, and stay on the desktop as they are.
//   2. Commit, once WindowServer lists the windows to reveal as on screen: one transaction gives `arriving`
//      alpha 1 and `leaving` alpha 0.
//   3. Settle: the hidden windows leave the desktop for `parking`, the revealed ones leave `arriving`, and the
//      groups get their alphas back. Nothing of it shows, but it must be over before a revealed window is focused:
//      as long as the window that had the keyboard is on the desktop, seen or not, macOS draws the window that
//      gets the keyboard as inactive for a frame or more.
typedef struct {
    uint64_t home;
    uint64_t parking;
    uint64_t arriving;
    uint64_t leaving;
} AeroSpaceWindowSwapSpaces;
bool AeroSpaceWindowSwapAvailable(void);
// Shows the two groups, `arriving` with alpha 0 and `leaving` with alpha 1. Both must be empty.
// `names` maps the IDs of both groups (CFNumber) to their unique names (CFString).
bool AeroSpacePrepareWindowSwapGroups(uint64_t arriving, uint64_t leaving, CFDictionaryRef names);
// `reveal` and `hide` are window IDs (CFNumber). The caller must have checked that every window to reveal is in
// `parking` only, and every window to hide on `home` only: the windows are moved without another look.
// Waits until WindowServer reports the new spaces of every window.
bool AeroSpaceStageWindowSwap(CFArrayRef reveal, CFArrayRef hide, AeroSpaceWindowSwapSpaces spaces);
bool AeroSpaceCommitWindowSwap(AeroSpaceWindowSwapSpaces spaces);
// Waits until the revealed windows are on `home` only, and the hidden ones in `parking` only.
bool AeroSpaceSettleWindowSwap(CFArrayRef reveal, CFArrayRef hide, AeroSpaceWindowSwapSpaces spaces);

#endif
