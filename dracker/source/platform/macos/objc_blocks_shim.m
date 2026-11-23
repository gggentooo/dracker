/**
 * File:         source/platform/macos/objc_blocks_shim.m
 * Language:     Objective-C (compiled with -fobjc-arc)
 * Phase:        Phase 7.1 — Objective-C Runtime Discipline & Block Shim
 *
 * Purpose:
 *   Minimal ~60-LOC Objective-C helper bridging Apple Clang Blocks (^) to plain
 *   extern(C) function pointer + void* context callbacks, avoiding fragile manual
 *   Clang Block ABI struct construction in D's extern(Objective-C) bindings.
 *
 * Scope Policy:
 *   Strictly limited to macOS framework APIs that require Block arguments:
 *     1. MTLCommandBuffer completion handlers (triple-buffered GPU/CPU pacing)
 *     2. Async NSOpenPanel / NSSavePanel sheet presentation
 *
 * Dependencies:
 *   System Frameworks: Foundation, Metal, AppKit
 *
 * Exposed C ABI Functions:
 *   - st_mtl_cmdbuf_add_completed_handler
 *   - st_ns_panel_begin_open_sheet
 *   - st_ns_panel_begin_save_sheet
 *
 * See_Also:
 *   architecture_proposal.md (Section 4.5), source/platform/macos/objc_runtime.d
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <AppKit/AppKit.h>

typedef void (*STVoidCallback)(void *ctx);
typedef void (*STPanelCallback)(void *ctx, int accepted, const char *utf8Path);

void st_mtl_cmdbuf_add_completed_handler(void *cmdBufPtr,
                                         STVoidCallback callback,
                                         void *ctx) {
    if (!cmdBufPtr || !callback) {
        return;
    }
    id<MTLCommandBuffer> cmdBuf = (__bridge id<MTLCommandBuffer>)cmdBufPtr;
    [cmdBuf addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull completedBuf) {
        (void)completedBuf;
        callback(ctx);
    }];
}

void st_ns_panel_begin_open_sheet(void *panelPtr,
                                  void *windowPtr,
                                  STPanelCallback callback,
                                  void *ctx) {
    if (!panelPtr || !windowPtr || !callback) {
        return;
    }
    NSOpenPanel *panel = (__bridge NSOpenPanel *)panelPtr;
    NSWindow *window = (__bridge NSWindow *)windowPtr;
    [panel beginSheetModalForWindow:window
                  completionHandler:^(NSModalResponse result) {
        const char *path = NULL;
        if (result == NSModalResponseOK && panel.URL != nil) {
            path = panel.URL.fileSystemRepresentation;
        }
        callback(ctx, result == NSModalResponseOK ? 1 : 0, path);
    }];
}

void st_ns_panel_begin_save_sheet(void *panelPtr,
                                  void *windowPtr,
                                  STPanelCallback callback,
                                  void *ctx) {
    if (!panelPtr || !windowPtr || !callback) {
        return;
    }
    NSSavePanel *panel = (__bridge NSSavePanel *)panelPtr;
    NSWindow *window = (__bridge NSWindow *)windowPtr;
    [panel beginSheetModalForWindow:window
                  completionHandler:^(NSModalResponse result) {
        const char *path = NULL;
        if (result == NSModalResponseOK && panel.URL != nil) {
            path = panel.URL.fileSystemRepresentation;
        }
        callback(ctx, result == NSModalResponseOK ? 1 : 0, path);
    }];
}
