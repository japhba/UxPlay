// libuxplaynodock — keep the uxplay-bin helper out of the Dock.
//
// UxPlay.app is a menu-bar-only app (LSUIElement), but it launches its
// helper `uxplay-bin` directly (not via LaunchServices), so the bundle's
// LSUIElement is not applied to the helper.  uxplay-bin links GStreamer,
// whose gst_macos_main()/osxvideosink set the process activation policy to
// "regular" (which shows a Dock icon and app menu).  This shim is
// DYLD-inserted into uxplay-bin only (via DYLD_INSERT_LIBRARIES set by the
// menu-bar app); it swizzles -[NSApplication setActivationPolicy:] so any
// attempt to become a regular app is coerced to "accessory".  The video
// mirror window still appears; there is just no Dock icon, ever.
//
// This relies on DYLD_INSERT_LIBRARIES being honored, which it is for our
// ad-hoc-signed helper (no hardened runtime).  A future Developer ID build
// with `--options runtime` would need the
// com.apple.security.cs.allow-dyld-environment-variables entitlement.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

static BOOL (*g_orig_setActivationPolicy)(id, SEL, NSInteger) = NULL;

static BOOL uxplay_setActivationPolicy(id self, SEL _cmd, NSInteger policy) {
    if (policy == NSApplicationActivationPolicyRegular) {
        policy = NSApplicationActivationPolicyAccessory;
    }
    if (g_orig_setActivationPolicy) {
        return g_orig_setActivationPolicy(self, _cmd, policy);
    }
    return NO;
}

__attribute__((constructor))
static void uxplay_nodock_init(void) {
    Method m = class_getInstanceMethod([NSApplication class],
                                       @selector(setActivationPolicy:));
    if (m) {
        g_orig_setActivationPolicy =
            (BOOL (*)(id, SEL, NSInteger))method_getImplementation(m);
        method_setImplementation(m, (IMP)uxplay_setActivationPolicy);
    }
    // Force accessory as soon as the shared application object exists.
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSApplication sharedApplication]
            setActivationPolicy:NSApplicationActivationPolicyAccessory];
    });
}
