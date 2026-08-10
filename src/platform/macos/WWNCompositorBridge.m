//  WWNCompositorBridge.m
//  Direct C API - calling plain C exports from Rust

#import "WWNCompositorBridge.h"
#import "WWNPopupWindow.h"
#import "../../util/WWNLog.h"
#import "WWNPlatformCallbacks.h"
#import "WWNWindow.h"
#import <Cocoa/Cocoa.h>
#import <IOSurface/IOSurfaceRef.h>
#import <QuartzCore/QuartzCore.h> // For CALayer
#import <ApplicationServices/ApplicationServices.h> // CGSetDisplayTransferByTable, etc.
#include <stdatomic.h>
#include <string.h> // For strdup

// Plain C FFI functions exported from Rust with #[no_mangle]
extern void *WWNCoreNew(void);
extern bool WWNCoreStart(void *core, const char *socket_name);
extern bool WWNCoreStop(void *core);
extern bool WWNCoreIsRunning(const void *core);
extern char *WWNCoreGetSocketPath(const void *core);
extern char *WWNCoreGetSocketName(const void *core);
extern char *WWNCorePollCopiedText(void *core);
extern void WWNStringFree(char *s);
extern bool WWNCoreProcessEvents(void *core);
extern void WWNCoreSetOutputSize(void *core, uint32_t w, uint32_t h, float s);
extern void WWNCoreNotifyFramePresented(void *core, uint32_t surface_id,
                                        uint64_t buffer_id, uint32_t timestamp);
extern void WWNCoreFree(void *core);
extern void WWNCoreInjectWindowResize(void *core, uint64_t window_id,
                                      uint32_t width, uint32_t height);
extern void WWNCoreRequestWindowClose(void *core, uint64_t window_id);
extern void WWNCoreSetWindowActivated(void *core, uint64_t window_id,
                                      bool active);
extern void WWNCoreSetWindowActivatedSilent(void *core, uint64_t window_id,
                                            bool active);
extern void WWNCoreFlushClients(void *core);
extern void WWNCoreSetForceSSD(void *core, bool enabled);
extern void WWNCoreSetSafeAreaInsets(void *core, int32_t top, int32_t right,
                                     int32_t bottom, int32_t left);
extern void WWNCoreInjectPointerAxis(void *core, uint64_t window_id,
                                     uint32_t axis, double value,
                                     uint32_t timestamp_ms);
extern void WWNCoreTextInputCommit(void *core, const char *text);
extern void WWNCoreSetClipboardText(void *core, const char *text);
extern void WWNCoreTextInputPreedit(void *core, const char *text,
                                    int32_t cursor_begin, int32_t cursor_end);
extern void WWNCoreTextInputDeleteSurrounding(void *core, uint32_t before,
                                              uint32_t after);
extern void WWNCoreTextInputGetCursorRect(void *core, int32_t *out_x,
                                          int32_t *out_y, int32_t *out_width,
                                          int32_t *out_height);
extern CBufferData *WWNCorePopPendingBuffer(void *core);
extern void WWNBufferDataFree(CBufferData *data);
extern IOSurfaceRef IOSurfaceLookup(uint32_t csid);

// Screencopy (zwlr_screencopy)
typedef struct {
  uint64_t capture_id;
  void *ptr;
  uint32_t width;
  uint32_t height;
  uint32_t stride;
  size_t size;
} CScreencopyRequest;
extern CScreencopyRequest WWNCoreGetPendingScreencopy(void *core);
extern void WWNCoreScreencopyDone(void *core, uint64_t capture_id);
extern void WWNCoreScreencopyFailed(void *core, uint64_t capture_id);

// Image copy capture (ext-image-copy-capture-v1, same structure as screencopy)
extern CScreencopyRequest WWNCoreGetPendingImageCopyCapture(void *core);
extern void WWNCoreImageCopyCaptureDone(void *core, uint64_t capture_id);
extern void WWNCoreImageCopyCaptureFailed(void *core, uint64_t capture_id);

// Gamma control (zwlr_gamma_control_manager_v1)
typedef struct {
  uint32_t output_id;
  uint32_t size;
  const uint16_t *red;
  const uint16_t *green;
  const uint16_t *blue;
} CGammaApply;
extern CGammaApply *WWNCorePopPendingGammaApply(void *core);
extern void WWNGammaApplyFree(CGammaApply *apply);
extern uint32_t WWNCorePopPendingGammaRestore(void *core);

// Scene Graph types
typedef struct CRenderNode {
  uint64_t node_id;
  uint64_t window_id;
  uint32_t surface_id;
  uint64_t buffer_id;
  float x;
  float y;
  float width;
  float height;
  float scale;
  float opacity;
  float corner_radius;
  bool is_opaque;
  uint32_t buffer_width;
  uint32_t buffer_height;
  uint32_t buffer_stride;
  uint32_t buffer_format;
  uint32_t iosurface_id;
  float anchor_output_x;
  float anchor_output_y;
  float content_rect_x;
  float content_rect_y;
  float content_rect_w;
  float content_rect_h;
} CRenderNode;

typedef struct CRenderScene {
  CRenderNode *nodes;
  size_t count;
  size_t capacity;
  // Cursor state (Wayland client cursor surface)
  bool has_cursor;
  float cursor_x;
  float cursor_y;
  float cursor_hotspot_x;
  float cursor_hotspot_y;
  uint64_t cursor_buffer_id;
  uint32_t cursor_width;
  uint32_t cursor_height;
  uint32_t cursor_stride;
  uint32_t cursor_format;
  uint32_t cursor_iosurface_id;
} CRenderScene;

extern CRenderScene *WWNCoreGetRenderScene(void *core);
extern void WWNRenderSceneFree(CRenderScene *scene);

// MARK: - Cursor Shape Mapping

// static NSCursor *NSCursorFromWaylandShape(uint32_t shape) {
//   switch (shape) {
//   case 1:
//     return [NSCursor arrowCursor]; // default
//   case 2:
//     return [NSCursor arrowCursor]; // context-menu
//   case 3:
//     return [NSCursor arrowCursor]; // help
//   case 4:
//     return [NSCursor pointingHandCursor]; // pointer
//   case 5:
//     return [NSCursor arrowCursor]; // progress
//   case 6:
//     return [NSCursor arrowCursor]; // wait
//   case 7:
//     return [NSCursor crosshairCursor]; // cell
//   case 8:
//     return [NSCursor crosshairCursor]; // crosshair
//   case 9:
//     return [NSCursor IBeamCursor]; // text
//   case 10:
//     return [NSCursor IBeamCursor]; // vertical-text (fallback)
//   case 11:
//     return [NSCursor arrowCursor]; // alias
//   case 12:
//     return [NSCursor dragCopyCursor]; // copy
//   case 13:
//     return [NSCursor arrowCursor]; // move
//   case 14:
//     return [NSCursor operationNotAllowedCursor]; // no-drop
//   case 15:
//     return [NSCursor operationNotAllowedCursor]; // not-allowed
//   case 16:
//     return [NSCursor crosshairCursor]; // grab (fallback)
//   case 17:
//     return [NSCursor closedHandCursor]; // grabbing
//   case 18:
//     return [NSCursor resizeRightCursor]; // e-resize
//   case 19:
//     return [NSCursor resizeUpCursor]; // n-resize
//   case 20:
//     return [NSCursor arrowCursor]; // ne-resize
//   case 21:
//     return [NSCursor arrowCursor]; // nw-resize
//   case 22:
//     return [NSCursor resizeDownCursor]; // s-resize
//   case 23:
//     return [NSCursor arrowCursor]; // se-resize
//   case 24:
//     return [NSCursor arrowCursor]; // sw-resize
//   case 25:
//     return [NSCursor resizeLeftCursor]; // w-resize
//   case 26:
//     return [NSCursor resizeLeftRightCursor]; // ew-resize
//   case 27:
//     return [NSCursor resizeUpDownCursor]; // ns-resize
//   case 28:
//     return [NSCursor arrowCursor]; // nesw-resize
//   case 29:
//     return [NSCursor arrowCursor]; // nwse-resize
//   case 30:
//     return [NSCursor resizeLeftRightCursor]; // col-resize
//   case 31:
//     return [NSCursor resizeUpDownCursor]; // row-resize
//   case 32:
//     return [NSCursor arrowCursor]; // all-scroll
//   case 33:
//     return [NSCursor arrowCursor]; // zoom-in
//   case 34:
//     return [NSCursor arrowCursor]; // zoom-out
//   default:
//     return [NSCursor arrowCursor];
//   }
// }

// static void handle_cursor_shape_update(uint32_t shape) {
//   dispatch_async(dispatch_get_main_queue(), ^{
//     NSCursor *cursor = NSCursorFromWaylandShape(shape);
//     [cursor set];
//   });
// }

@implementation WWNCompositorBridge {
  void *_rustCore;
  NSTimer *_eventTimer;
  dispatch_source_t _protocolTimer;
  CADisplayLink *_displayLink;

  // Serial queue for all Rust FFI calls. Keeps heavy compositor work
  // (Wayland dispatch, buffer processing, scene graph building) off the
  // main thread so UIKit/AppKit stays responsive.
  dispatch_queue_t _compositorQueue;

  // Guards against frame pile-up: when YES, a compositor tick is in
  // flight and the next CADisplayLink/NSTimer callback is skipped.
  // Atomic because it is written on _compositorQueue and read on the
  // main thread; without barriers, ARM64 weak ordering can cause the
  // main thread to read a stale YES and skip ticks indefinitely.
  atomic_bool _compositorBusy;
  atomic_bool _protocolBusy;

  NSMutableDictionary<NSNumber *, id>
      *_windows; /* WWNWindow or NSWindow (popup) */
  NSMutableDictionary<NSNumber *, id<WWNPopupHost>> *_popups;
  // Scene Graph caches
  NSMutableDictionary<NSNumber *, id> *_bufferCache;
  NSMutableDictionary<NSNumber *, CALayer *> *_surfaceLayers;

  // Per-window resize coalescing.  Each window gets its own "latest"
  // dimensions so concurrent resizes of different windows never collide.
  // Key = window_id (NSNumber wrapping uint64_t).
  NSMutableDictionary<NSNumber *, NSValue *> *_latestResizeDims;
  NSMutableDictionary<NSNumber *, NSValue *> *_sentResizeDims;
  NSMutableSet<NSNumber *> *_resizeInFlightWindows;

  // Output-size coalescing (same pattern)
  BOOL _outputResizeInFlight;
  uint32_t _latestOutputW;
  uint32_t _latestOutputH;
  float _latestOutputScale;
  uint32_t _sentOutputW;
  uint32_t _sentOutputH;
  float _sentOutputScale;

  // Saved gamma for restore (nested compositor may not use; main display only)
  CGGammaValue *_savedGammaRed;
  CGGammaValue *_savedGammaGreen;
  CGGammaValue *_savedGammaBlue;
  uint32_t _savedGammaSize;
}

+ (instancetype)sharedBridge {
  static WWNCompositorBridge *sharedInstance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedInstance = [[WWNCompositorBridge alloc] init];
  });
  return sharedInstance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    WWNLog("BRIDGE", @"Creating WWNCore via direct C API");
    _rustCore = WWNCoreNew();

    if (!_rustCore) {
      WWNLog("BRIDGE", @"Error: Failed to create WWNCore");
      return nil;
    }

    // High-priority serial queue for all Rust compositor FFI work.
    // USER_INTERACTIVE QoS ensures low-latency event processing while
    // keeping the main thread free for UI.
    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
    _compositorQueue = dispatch_queue_create("com.muplar.wayland.compositor", attr);

    WWNLog("BRIDGE", @"WWNCore created successfully via C API!");
    _windows = [NSMutableDictionary dictionary];
    _popups = [NSMutableDictionary dictionary];
    _bufferCache = [NSMutableDictionary dictionary];
    _surfaceLayers = [NSMutableDictionary dictionary];
    _latestResizeDims = [NSMutableDictionary dictionary];
    _sentResizeDims = [NSMutableDictionary dictionary];
    _resizeInFlightWindows = [NSMutableSet set];
  }
  return self;
}

- (void)dealloc {
  if (_rustCore) {
    WWNCoreFree(_rustCore);
  }
}

// MARK: - Lifecycle

// MARK: - Lifecycle

- (void)_setupRuntimeEnvironmentWithSocketName:(NSString *)socketName {
  // 1. Set XDG_RUNTIME_DIR to a well-known, stable directory
  // On macOS, use /tmp/muplar-wayland-<uid> so clients in other terminals can find it.
  // On iOS, use NSTemporaryDirectory() (sandboxed).
  NSString *runtimeDir;

  // macOS: use /tmp/muplar-wayland-<uid> matching the client wrapper scripts in
  // flake.nix
  uid_t uid = getuid();
  runtimeDir = [NSString stringWithFormat:@"/tmp/muplar-wayland-%u", uid];

  // Ensure it exists with restricted permissions
  NSFileManager *fm = [NSFileManager defaultManager];
  NSError *dirError = nil;
  [fm createDirectoryAtPath:runtimeDir
      withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions : @0700}
                            error:&dirError];
  if (dirError) {
    WWNLog("BRIDGE", @"Warning: Could not create runtime dir %@: %@",
           runtimeDir, dirError);
  }

  // Important: overwrite=1 to ensure Rust sees the new path
  setenv("XDG_RUNTIME_DIR", [runtimeDir UTF8String], 1);
  WWNLog("BRIDGE", @"Configured XDG_RUNTIME_DIR: %@", runtimeDir);

  // 2. Cleanup stale socket files
  // If the app crashed, the socket file might still exist, causing
  // "Address in use"
  NSString *sockName = socketName ?: @"wayland-0";
  NSString *lockName = [sockName stringByAppendingString:@".lock"];

  NSArray *filesToRemove = @[ sockName, lockName ];

  for (NSString *filename in filesToRemove) {
    NSString *filePath = [runtimeDir stringByAppendingPathComponent:filename];
    if ([[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
      NSError *error = nil;
      [[NSFileManager defaultManager] removeItemAtPath:filePath error:&error];
      if (error) {
        WWNLog("BRIDGE", @"Warning: Failed to remove stale file %@: %@",
               filePath, error);
      } else {
        WWNLog("BRIDGE", @"Cleaned up stale file: %@", filePath);
      }
    }
  }
}

- (BOOL)startWithSocketName:(NSString *)socketName {
  [self _setupRuntimeEnvironmentWithSocketName:socketName];

  if (!_rustCore) {
    WWNLog("BRIDGE", @"Re-creating WWNCore...");
    _rustCore = WWNCoreNew();
  }

  if (!_rustCore) {
    WWNLog("BRIDGE", @"No Rust core");
    return NO;
  }

  const char *name = socketName ? [socketName UTF8String] : NULL;
  WWNLog("BRIDGE", @"Starting compositor...");

  bool success = WWNCoreStart(_rustCore, name);

  if (success) {
    // Export WAYLAND_DISPLAY so child processes and logs can reference it
    NSString *displayName = socketName ?: @"wayland-0";
    setenv("WAYLAND_DISPLAY", [displayName UTF8String], 1);

    char *socketPath = WWNCoreGetSocketPath(_rustCore);
    if (socketPath) {
      WWNLog("BRIDGE", @"Compositor started — socket: %s", socketPath);
      WWNLog("BRIDGE", @"Connect clients with:");
      WWNLog("BRIDGE", @"  export XDG_RUNTIME_DIR=%s",
             getenv("XDG_RUNTIME_DIR"));
      WWNLog("BRIDGE", @"  export WAYLAND_DISPLAY=%s",
             [displayName UTF8String]);
      free(socketPath);
    } else {
      WWNLog("BRIDGE", @"Compositor started successfully!");
    }

    // macOS: NSTimer at ~60fps for frame pacing
    // (CADisplayLink.displayLinkWithTarget:selector: is unavailable on macOS;
    //  CVDisplayLink is the macOS alternative but adds complexity.
    //  NSTimer at 60fps is sufficient for the compositor event loop.)
    _eventTimer =
        [NSTimer scheduledTimerWithTimeInterval:0.016
                                         target:self
                                       selector:@selector(onTimerTick:)
                                       userInfo:nil
                                        repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_eventTimer forMode:NSRunLoopCommonModes];
    WWNLog("BRIDGE", @"Using NSTimer for frame pacing (60fps)");

    _protocolTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                            _compositorQueue);
    if (_protocolTimer) {
      dispatch_source_set_timer(_protocolTimer, DISPATCH_TIME_NOW,
                                5 * NSEC_PER_MSEC, 1 * NSEC_PER_MSEC);
      __weak WWNCompositorBridge *weakSelf = self;
      dispatch_source_set_event_handler(_protocolTimer, ^{
        WWNCompositorBridge *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->_rustCore ||
            atomic_exchange(&strongSelf->_protocolBusy, true))
          return;

        bool ok = WWNCoreProcessEvents(strongSelf->_rustCore);
        if (ok)
          WWNCoreFlushClients(strongSelf->_rustCore);
        else
          WWNLog("BRIDGE", @"Protocol pump skipped after event-loop failure");
        atomic_store(&strongSelf->_protocolBusy, false);
      });
      dispatch_resume(_protocolTimer);
      WWNLog("BRIDGE", @"Using GCD protocol pump (5ms)");
    }

  } else {
    WWNLog("BRIDGE", @"Error: Start failed");
  }

  return success;
}

- (void)stop {
  WWNLog("BRIDGE", @"Stopping compositor bridge...");

  // 1. Stop timers first — no new ticks will be scheduled after this.
  if (_displayLink) {
    [_displayLink invalidate];
    _displayLink = nil;
  }
  if (_eventTimer) {
    [_eventTimer invalidate];
    _eventTimer = nil;
  }
  if (_protocolTimer) {
    dispatch_source_cancel(_protocolTimer);
    _protocolTimer = nil;
  }

  // 2. Drain the compositor queue: wait for any in-flight tick to finish,
  //    then stop the Rust compositor.  dispatch_sync is safe here because
  //    the in-flight tick only uses dispatch_async to bounce back to main
  //    (no deadlock — the async block will simply run after we return).
  if (_rustCore && _compositorQueue) {
    dispatch_sync(_compositorQueue, ^{
      WWNCoreStop(self->_rustCore);
      self->_rustCore = NULL;
      WWNLog("BRIDGE", @"Compositor stopped on compositor queue");
    });
  } else if (_rustCore) {
    WWNCoreStop(_rustCore);
    _rustCore = NULL;
    WWNLog("BRIDGE", @"Compositor stopped");
  }

  // 3. Close all windows gracefully (main thread UI work)
  NSUInteger windowCount = [_windows count];
  if (windowCount > 0) {
    WWNLog("BRIDGE", @"Closing %lu window(s)...", (unsigned long)windowCount);
    // Popup windows are also indexed in _windows for rendering. Dismiss them
    // through their sole owner before walking the remaining toplevels.
    for (id<WWNPopupHost> popup in [[_popups allValues] copy])
      [popup dismiss];
    [_popups removeAllObjects];

    for (NSNumber *key in [_windows allKeys]) {
      NSWindow *window = [_windows objectForKey:key];
      window.animationBehavior = NSWindowAnimationBehaviorNone;
      [window setDelegate:nil];
      [window orderOut:nil];
      [window setContentView:nil];
    }
    [_windows removeAllObjects];
  }

  [_bufferCache removeAllObjects];
  [_surfaceLayers removeAllObjects];
  atomic_store(&_compositorBusy, false);
  atomic_store(&_protocolBusy, false);
  [_latestResizeDims removeAllObjects];
  [_sentResizeDims removeAllObjects];
  [_resizeInFlightWindows removeAllObjects];
  _outputResizeInFlight = NO;
  _sentOutputW = _sentOutputH = 0;
}

- (BOOL)isRunning {
  return _rustCore ? WWNCoreIsRunning(_rustCore) : NO;
}

- (NSString *)socketPath {
  if (!_rustCore)
    return @"";

  char *path = WWNCoreGetSocketPath(_rustCore);
  if (!path)
    return @"";

  NSString *result = [NSString stringWithUTF8String:path];
  WWNStringFree(path);
  return result ?: @"";
}

- (NSString *)socketName {
  if (!_rustCore)
    return @"";

  char *name = WWNCoreGetSocketName(_rustCore);
  if (!name)
    return @"";

  NSString *result = [NSString stringWithUTF8String:name];
  WWNStringFree(name);
  return result ?: @"";
}

// MARK: - Event Processing


/// Shared compositor tick implementation.
/// Called from CADisplayLink (iOS) or NSTimer (macOS).  The callback fires
/// on the main thread but we immediately dispatch the heavy Rust work to
/// _compositorQueue, then bounce lightweight UI updates back to main.
- (void)_compositorTick {
  if (!_rustCore || atomic_load(&_compositorBusy)) {
    return;
  }
  atomic_store(&_compositorBusy, true);

  dispatch_async(_compositorQueue, ^{
    // Guard: compositor may have been stopped between dispatch and execution
    if (!self->_rustCore) {
      atomic_store(&self->_compositorBusy, false);
      return;
    }

    // === Compositor Queue: heavy Rust FFI work ===

    // 1. Dispatch Wayland protocol events (accept connections, process
    //    client requests, build scene graph updates). This is the most
    //    expensive call and the primary reason we moved off main thread.
    bool processed = WWNCoreProcessEvents(self->_rustCore);
    if (!processed) {
      WWNLog("TICK",
             @"Skipping compositor tick after non-fatal event-loop failure");
      dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store(&self->_compositorBusy, false);
      });
      return;
    }

    // 2. Collect window-lifecycle events from Rust (cheap pops from a Vec)
    NSMutableArray *windowEvents = [NSMutableArray array];
    CWindowEvent *evt;
    while ((evt = WWNCorePopWindowEvent(self->_rustCore)) != NULL) {
      [windowEvents addObject:[NSValue valueWithPointer:evt]];
    }
    if (windowEvents.count > 0) {
      WWNLog("TICK", @"Collected %lu window event(s) this tick",
             (unsigned long)windowEvents.count);
    }

    // Poll clipboard updates from Rust
    char *copiedText = WWNCorePollCopiedText(self->_rustCore);
    if (copiedText != NULL) {
      NSString *textStr = [NSString stringWithUTF8String:copiedText];
      WWNStringFree(copiedText);
      if (textStr && textStr.length > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
          NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
          [pasteboard clearContents];
          [pasteboard setString:textStr forType:NSPasteboardTypeString];
          WWNLog("CLIPBOARD", @"Synchronized clipboard text to macOS: %@", textStr);
        });
      }
    }

    // 3. Process pending buffers: create CGImages / lookup IOSurfaces and
    //    tell Rust the frame has been presented so it can release or reuse
    //    the buffer.  Image creation from SHM data is CPU-bound work that
    //    benefits from running off main thread.
    CBufferData *buffer;
    NSUInteger poppedBufferCount = 0;
    while ((buffer = WWNCorePopPendingBuffer(self->_rustCore)) != NULL) {
      poppedBufferCount++;
      WWNLog("TICK",
             @"Popped buffer: win=%llu surf=%u buf=%llu %ux%u pixels=%p "
             @"iosurface=%u",
             buffer->window_id, buffer->surface_id, buffer->buffer_id,
             buffer->width, buffer->height, buffer->pixels,
             buffer->iosurface_id);
      [self cacheBuffer:buffer];
      uint32_t ts = (uint32_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
      WWNCoreNotifyFramePresented(self->_rustCore, buffer->surface_id,
                                  buffer->buffer_id, ts);
      WWNBufferDataFree(buffer);
    }

    // 3b. Flush all pending protocol events (frame_done, buffer_release)
    //     to clients unconditionally.  Events may have been generated by
    //     NotifyFramePresented above OR by SurfaceCommitted handlers inside
    //     ProcessEvents (step 1).  Flushing only when poppedBufferCount > 0
    //     would leave frame_done events stranded when a commit was processed
    //     but its buffer couldn't be popped (e.g. window not yet created,
    //     DMA-BUF type, SHM mapping failure).  For in-process waypipe on
    //     iOS this stalls the entire remote frame pipeline.
    WWNCoreFlushClients(self->_rustCore);

    // 4. Build the render scene graph (scene-graph traversal + buffer
    //    info lookups happen inside Rust; the returned CRenderScene is a
    //    self-contained snapshot safe to consume on any thread).
    CRenderScene *scene = WWNCoreGetRenderScene(self->_rustCore);
    if (!scene && (windowEvents.count > 0 || poppedBufferCount > 0)) {
      WWNLog("TICK",
             @"GetRenderScene returned NULL (events=%lu, buffers=%lu)",
             (unsigned long)windowEvents.count, (unsigned long)poppedBufferCount);
    }
    {
      static NSUInteger sPrevPoppedCount = 0;
      static size_t sPrevSceneCount = 0;
      static NSUInteger sPrevCacheSize = 0;
      size_t sc = scene ? scene->count : 0;
      NSUInteger cs = self->_bufferCache.count;
      if (poppedBufferCount != sPrevPoppedCount || sc != sPrevSceneCount ||
          cs != sPrevCacheSize) {
        WWNLog("TICK",
               @"Buffers popped: %lu, scene nodes: %zu, cache size: %lu",
               (unsigned long)poppedBufferCount, sc, (unsigned long)cs);
        sPrevPoppedCount = poppedBufferCount;
        sPrevSceneCount = sc;
        sPrevCacheSize = cs;
      }
    }

    // === Main Queue: lightweight UI updates ===
    // NOTE: _compositorBusy is reset at the END of this main-queue block,
    // NOT here on the compositor queue.  Resetting here would allow the
    // next tick's [self cacheBuffer:] to write _bufferCache concurrently
    // with updateLayerForNode: reading it — a data race on
    // NSMutableDictionary that causes visual flashing.
    dispatch_async(dispatch_get_main_queue(), ^{
      // Apply window events (create/destroy views, update titles)
      for (NSValue *val in windowEvents) {
        CWindowEvent *event = [val pointerValue];
        @try {
          [self _dispatchWindowEvent:event];
        } @catch (NSException *exception) {
          WWNLog("TICK",
                 @"Exception applying window event type=%llu win=%llu: %@ (%@)",
                 event->event_type, event->window_id, exception.name,
                 exception.reason);
        }
        WWNWindowEventFree(event);
      }

      // Apply render scene (update CALayer geometry and contents)
      if (scene) {
        @try {
          for (size_t i = 0; i < scene->count; i++) {
            [self updateLayerForNode:&scene->nodes[i]];
          }

        } @catch (NSException *exception) {
          WWNLog("TICK", @"Exception applying render scene: %@ (%@)",
                 exception.name, exception.reason);
        }
        WWNRenderSceneFree(scene);
      }

      // Screencopy: capture window and write to client buffer
      if (!self->_rustCore) {
        WWNLog("TICK", @"Rust core became NULL before post-scene tasks");
      }
      CScreencopyRequest screencopy =
          WWNCoreGetPendingScreencopy(self->_rustCore);
      if (screencopy.capture_id != 0 && screencopy.ptr != NULL &&
          screencopy.width > 0 && screencopy.height > 0) {
        [self _fulfillScreencopy:&screencopy];
      }
      // Image copy capture (ext-image-copy-capture-v1): same pixel path as
      // screencopy
      CScreencopyRequest imageCopy =
          WWNCoreGetPendingImageCopyCapture(self->_rustCore);
      if (imageCopy.capture_id != 0 && imageCopy.ptr != NULL &&
          imageCopy.width > 0 && imageCopy.height > 0) {
        [self _fulfillImageCopyCapture:&imageCopy];
      } else if (imageCopy.capture_id != 0) {
        WWNCoreImageCopyCaptureFailed(self->_rustCore, imageCopy.capture_id);
      }

      // Gamma control: apply or restore
      CGammaApply *gammaApply = WWNCorePopPendingGammaApply(self->_rustCore);
      if (gammaApply) {
        [self _applyGamma:gammaApply];
        WWNGammaApplyFree(gammaApply);
      }
      uint32_t restoreOutputId = WWNCorePopPendingGammaRestore(self->_rustCore);
      if (restoreOutputId != 0) {
        [self _restoreGamma];
      }

      // Reset AFTER all main-queue UI work is done so the next compositor
      // tick cannot mutate _bufferCache while we are still reading it.
      atomic_store(&self->_compositorBusy, false);
    });
  });
}

/// Runs on CADisplayLink (vsync-aligned frame callback) — iOS and macOS 14+
- (void)onDisplayLink:(CADisplayLink *)link {
  [self _compositorTick];
}

/// macOS: NSTimer fallback (pre-macOS 14)
- (void)onTimerTick:(NSTimer *)timer {
  [self _compositorTick];
}

// MARK: - Rendering

- (void)processPendingBuffers {
  if (!_rustCore) {
    return;
  }

  CBufferData *buffer;
  while ((buffer = WWNCorePopPendingBuffer(_rustCore)) != NULL) {
    [self cacheBuffer:buffer];

    // Notify Rust immediately (legacy behavior, can be refined with FrameClock)
    uint32_t ts = (uint32_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
    [self notifyFramePresentedForSurface:buffer->surface_id
                                  buffer:buffer->buffer_id
                               timestamp:ts];

    WWNBufferDataFree(buffer);
  }
}

- (void)cacheBuffer:(CBufferData *)buffer {
  NSNumber *bufId = @(buffer->buffer_id);

  // 1. IOSurface
  if (buffer->iosurface_id != 0) {
    IOSurfaceRef surf = IOSurfaceLookup(buffer->iosurface_id);
    if (surf) {
      _bufferCache[bufId] = (__bridge_transfer id)surf;
      WWNLog("CACHE", @"Cached IOSurface buf=%llu", buffer->buffer_id);
    } else {
      WWNLog("CACHE", @"FAILED IOSurface lookup for buf=%llu iosurface=%u",
             buffer->buffer_id, buffer->iosurface_id);
    }
    return;
  }

  // 2. SHM (Software)
  if (buffer->pixels) {
    CFDataRef pixelData =
        CFDataCreate(NULL, buffer->pixels, (CFIndex)buffer->size);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(pixelData);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo =
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst;

    CGImageRef image = CGImageCreate(
        buffer->width, buffer->height, 8, 32, buffer->stride, colorSpace,
        bitmapInfo, provider, NULL, false, kCGRenderingIntentDefault);

    if (image) {
      _bufferCache[bufId] = (__bridge_transfer id)image;
      WWNLog("CACHE", @"Cached SHM CGImage buf=%llu %ux%u stride=%u",
             buffer->buffer_id, buffer->width, buffer->height, buffer->stride);
    } else {
      WWNLog("CACHE", @"FAILED CGImageCreate for buf=%llu %ux%u",
             buffer->buffer_id, buffer->width, buffer->height);
    }

    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    CFRelease(pixelData);
  } else {
    WWNLog("CACHE", @"SKIP: buf=%llu has no pixels and no iosurface",
           buffer->buffer_id);
  }
}

- (void)renderScene {
  if (!_rustCore) {
    return;
  }

  CRenderScene *scene = WWNCoreGetRenderScene(_rustCore);
  if (!scene)
    return;

  // Track used layers to hide/remove unused ones (skip for now, simple update)

  if (scene->count > 0) {
    for (size_t i = 0; i < scene->count; i++) {
      [self updateLayerForNode:&scene->nodes[i]];
    }
  }

  WWNRenderSceneFree(scene);
}

- (void)updateLayerForNode:(CRenderNode *)node {
  NSNumber *winId = @(node->window_id);
  NSNumber *surfId = @(node->surface_id);

  // 1. Find or Create Layer
  CALayer *layer = _surfaceLayers[surfId];
  if (!layer) {
    layer = [CALayer layer];
    layer.contentsScale = node->scale;
    layer.contentsGravity = kCAGravityResize;
    _surfaceLayers[surfId] = layer;
  }

  /* 2. Bind the layer to the view hosting this node's window.
   *
   * Re-checked on every frame rather than once at creation. _surfaceLayers is
   * keyed by wl_surface id, and those are client object ids: the client frees
   * them on destroy and the next object reuses the number. A menu is a popup
   * surface that is created and destroyed on every open, so the second menu
   * came back on a recycled id, found the first menu's layer still cached, and
   * skipped attachment entirely -- leaving the layer parented to the popup view
   * that had already been torn down. The new popup window then had no content
   * at all, and since it is borderless and non-opaque an empty one is both
   * invisible and click-through, so it swallowed nothing and the pointer went
   * to the terminal underneath. That is a menu that never appears.
   */
  id host = _windows[winId];
  if (!host) {
    id<WWNPopupHost> popup = _popups[winId];
    host = popup.contentView;
  } else if ([host isKindOfClass:[NSWindow class]]) {
    host = [(NSWindow *)host contentView];
  }
  if ([host isKindOfClass:[WWNView class]] &&
      [host respondsToSelector:@selector(contentLayer)]) {
    CALayer *target = ((WWNView *)host).contentLayer;
    if (layer.superlayer != target) {
      [layer removeFromSuperlayer];
      [target addSublayer:layer];
    }
  }

  if (node->buffer_id != 0) {
    id w = _windows[winId];
    if (w && [w isKindOfClass:[NSWindow class]]) {
      NSWindow *window = (NSWindow *)w;
      if (![window isVisible] && ![window isMiniaturized]) {
        [window makeKeyAndOrderFront:nil];
      }
    }
  }

  // Disable implicit animations so layer property changes are instantaneous.
  // During rotation, an active animation context would capture these changes
  // and animate them, causing the surface to appear frozen/stretched.
  [CATransaction begin];
  [CATransaction setDisableActions:YES];

  // 2. Update Geometry — use anchor for window-local coords (subsurfaces)
  float localX = node->x - node->anchor_output_x;
  float localY = node->y - node->anchor_output_y;
  layer.position =
      CGPointMake(localX + node->width / 2, localY + node->height / 2);
  layer.bounds = CGRectMake(0, 0, node->width, node->height);
  layer.opacity = node->opacity;
  layer.cornerRadius = node->corner_radius;

  // 2b. Crop buffer to content area when CSD geometry is set.
  // The client's buffer may include shadow/frame around the content;
  // xdg_surface.set_window_geometry defines the content rect.
  // content_rect is pre-normalized (0..1) on the Rust side.
  if (node->content_rect_w > 0.0f && node->content_rect_h > 0.0f) {
    layer.contentsRect = CGRectMake(node->content_rect_x, node->content_rect_y,
                                    node->content_rect_w, node->content_rect_h);
  }

  // 3. Update Contents from Cache
  // We use node->buffer_id to look up the image
  id content = _bufferCache[@(node->buffer_id)];
  if (node->buffer_id != 0 && !content) {
    WWNLog(
        "RENDER",
        @"MISS: surf=%@ win=%@ buf=%llu not in cache (cache has %lu entries)",
        surfId, winId, node->buffer_id, (unsigned long)_bufferCache.count);
  }
  if (content) {
    layer.contents = content;
  }

  [CATransaction commit];
}

- (void)flushClients {
  if (!_rustCore)
    return;
  [self _dispatchToRust:^{
    WWNCoreFlushClients(self->_rustCore);
  }];
}

/// Write ARGB8888 screen capture to buffer. Returns YES on success.
- (BOOL)_writeCaptureToBuffer:(const CScreencopyRequest *)req {
  if (!req || req->capture_id == 0 || req->ptr == NULL || req->width == 0 ||
      req->height == 0)
    return NO;

  WWNWindow *window = nil;
  for (NSNumber *key in _windows) {
    id w = _windows[key];
    if ([w isKindOfClass:[WWNWindow class]]) {
      window = (WWNWindow *)w;
      break;
    }
  }
  if (!window)
    return NO;

  CGWindowID windowID = (CGWindowID)[window windowNumber];
  CGRect bounds = CGRectNull;
  CGImageRef cap = NULL;
#if __MAC_OS_X_VERSION_MAX_ALLOWED < 150000
  cap = CGWindowListCreateImage(bounds, kCGWindowListOptionIncludingWindow,
                                windowID, kCGWindowImageBoundsIgnoreFraming);
#else
  (void)windowID;
  (void)bounds;
  /* CGWindowListCreateImage obsoleted in macOS 15 - ScreenCaptureKit required
   */
#endif
  if (!cap)
    return NO;

  size_t imgWidth = CGImageGetWidth(cap);
  size_t imgHeight = CGImageGetHeight(cap);
  if (imgWidth == 0 || imgHeight == 0) {
    CGImageRelease(cap);
    return NO;
  }

  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGBitmapInfo bmpInfo =
      kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst;
  CGContextRef ctx = CGBitmapContextCreate(req->ptr, req->width, req->height, 8,
                                           req->stride, cs, bmpInfo);
  if (!ctx) {
    CGColorSpaceRelease(cs);
    CGImageRelease(cap);
    return NO;
  }

  CGContextTranslateCTM(ctx, 0, req->height);
  CGContextScaleCTM(ctx, 1.0, -1.0);
  CGContextDrawImage(ctx, CGRectMake(0, 0, req->width, req->height), cap);

  CGContextRelease(ctx);
  CGColorSpaceRelease(cs);
  CGImageRelease(cap);
  return YES;
}

- (void)_fulfillScreencopy:(const CScreencopyRequest *)req {
  if ([self _writeCaptureToBuffer:req])
    WWNCoreScreencopyDone(_rustCore, req->capture_id);
  else
    WWNCoreScreencopyFailed(_rustCore, req->capture_id);
}

- (void)_fulfillImageCopyCapture:(const CScreencopyRequest *)req {
  if ([self _writeCaptureToBuffer:req])
    WWNCoreImageCopyCaptureDone(_rustCore, req->capture_id);
  else
    WWNCoreImageCopyCaptureFailed(_rustCore, req->capture_id);
}

- (void)_applyGamma:(const CGammaApply *)apply {
  if (!apply || apply->size == 0 || !apply->red || !apply->green ||
      !apply->blue)
    return;

  CGDirectDisplayID displayId = CGMainDisplayID();
  uint32_t n = apply->size;

  CGGammaValue *redF = (CGGammaValue *)malloc(n * sizeof(CGGammaValue));
  CGGammaValue *greenF = (CGGammaValue *)malloc(n * sizeof(CGGammaValue));
  CGGammaValue *blueF = (CGGammaValue *)malloc(n * sizeof(CGGammaValue));
  if (!redF || !greenF || !blueF) {
    free(redF);
    free(greenF);
    free(blueF);
    return;
  }

  for (uint32_t i = 0; i < n; i++) {
    redF[i] = (CGGammaValue)apply->red[i] / 65535.0f;
    greenF[i] = (CGGammaValue)apply->green[i] / 65535.0f;
    blueF[i] = (CGGammaValue)apply->blue[i] / 65535.0f;
  }

  if (_savedGammaRed == NULL) {
    _savedGammaSize = n;
    _savedGammaRed = (CGGammaValue *)malloc(n * sizeof(CGGammaValue));
    _savedGammaGreen = (CGGammaValue *)malloc(n * sizeof(CGGammaValue));
    _savedGammaBlue = (CGGammaValue *)malloc(n * sizeof(CGGammaValue));
    if (_savedGammaRed && _savedGammaGreen && _savedGammaBlue) {
      uint32_t sampleCount = n;
      CGGetDisplayTransferByTable(displayId, n, _savedGammaRed,
                                  _savedGammaGreen, _savedGammaBlue,
                                  &sampleCount);
      _savedGammaSize = sampleCount;
    } else {
      free(_savedGammaRed);
      free(_savedGammaGreen);
      free(_savedGammaBlue);
      _savedGammaRed = _savedGammaGreen = _savedGammaBlue = NULL;
      _savedGammaSize = 0;
    }
  }

  CGSetDisplayTransferByTable(displayId, n, redF, greenF, blueF);

  free(redF);
  free(greenF);
  free(blueF);
}

- (void)_restoreGamma {
  if (_savedGammaRed && _savedGammaGreen && _savedGammaBlue &&
      _savedGammaSize > 0) {
    CGSetDisplayTransferByTable(CGMainDisplayID(), _savedGammaSize,
                                _savedGammaRed, _savedGammaGreen,
                                _savedGammaBlue);
    free(_savedGammaRed);
    free(_savedGammaGreen);
    free(_savedGammaBlue);
    _savedGammaRed = _savedGammaGreen = _savedGammaBlue = NULL;
    _savedGammaSize = 0;
  }
}

// MARK: - Input (Stubs)

// C FFI for input injection
extern void WWNCoreInjectPointerMotion(void *core, uint64_t window_id, double x,
                                       double y, uint32_t timestamp);
extern void WWNCoreInjectPointerButton(void *core, uint64_t window_id,
                                       uint32_t button, uint32_t state,
                                       uint32_t timestamp);
extern void WWNCoreInjectPointerEnter(void *core, uint64_t window_id, double x,
                                      double y, uint32_t timestamp);
extern void WWNCoreInjectPointerLeave(void *core, uint64_t window_id,
                                      uint32_t timestamp);
extern void WWNCoreInjectKey(void *core, uint32_t keycode, uint32_t state,
                             uint32_t timestamp);
extern void WWNCoreInjectKeyboardEnter(void *core, uint64_t window_id,
                                       const uint32_t *keys, size_t count,
                                       uint32_t timestamp);
extern void WWNCoreInjectKeyboardLeave(void *core, uint64_t window_id);
extern void WWNCoreInjectModifiers(void *core, uint32_t depressed,
                                   uint32_t latched, uint32_t locked,
                                   uint32_t group);

extern void WWNCoreInjectTouchDown(void *core, int32_t id, double x, double y,
                                   uint32_t timestamp);
extern void WWNCoreInjectTouchUp(void *core, int32_t id, uint32_t timestamp);
extern void WWNCoreInjectTouchMotion(void *core, int32_t id, double x, double y,
                                     uint32_t timestamp);
extern void WWNCoreInjectTouchCancel(void *core);
extern void WWNCoreInject_touch_frame(void *core);

/// Dispatch a block to the compositor's serial queue.
/// All Rust FFI calls (input injection, configuration changes, etc.) go
/// through here so they are serialized with the compositor tick and never
/// contend for Rust-internal locks on the main thread.
- (void)_dispatchToRust:(dispatch_block_t)block {
  if (_compositorQueue) {
    dispatch_async(_compositorQueue, block);
  } else {
    // Fallback: queue not yet created (should not happen in practice)
    block();
  }
}

- (void)injectTouchDown:(NSInteger)touchId
                      x:(double)x
                      y:(double)y
              timestamp:(uint32_t)timestampMs {
  if (!_rustCore) {
    return;
  }
  [self _dispatchToRust:^{
    WWNCoreInjectTouchDown(self->_rustCore, (int32_t)touchId, x, y,
                           timestampMs);
  }];
}

- (void)injectTouchUp:(NSInteger)touchId timestamp:(uint32_t)timestampMs {
  if (!_rustCore) {
    return;
  }
  [self _dispatchToRust:^{
    WWNCoreInjectTouchUp(self->_rustCore, (int32_t)touchId, timestampMs);
  }];
}

- (void)injectTouchMotion:(NSInteger)touchId
                        x:(double)x
                        y:(double)y
                timestamp:(uint32_t)timestampMs {
  if (!_rustCore) {
    return;
  }
  [self _dispatchToRust:^{
    WWNCoreInjectTouchMotion(self->_rustCore, (int32_t)touchId, x, y,
                             timestampMs);
  }];
}

- (void)injectTouchCancel {
  if (!_rustCore) {
    return;
  }
  [self _dispatchToRust:^{
    WWNCoreInjectTouchCancel(self->_rustCore);
  }];
}

- (void)injectTouchFrame {
  if (!_rustCore) {
    return;
  }
  [self _dispatchToRust:^{
    WWNCoreInject_touch_frame(self->_rustCore);
  }];
}

// MARK: - Text Input (IME / Emoji)

- (void)textInputCommitString:(NSString *)text {
  if (!_rustCore || !text) {
    return;
  }
  const char *utf8 = [text UTF8String];
  if (!utf8) {
    return;
  }
  [self _dispatchToRust:^{
    WWNCoreTextInputCommit(self->_rustCore, utf8);
  }];
}

- (void)setClipboardText:(NSString *)text {
  if (!_rustCore || !text) {
    return;
  }
  const char *utf8 = [text UTF8String];
  if (!utf8) {
    return;
  }
  [self _dispatchToRust:^{
    WWNCoreSetClipboardText(self->_rustCore, utf8);
  }];
}

- (void)textInputPreeditString:(NSString *)text
                   cursorBegin:(int32_t)cursorBegin
                     cursorEnd:(int32_t)cursorEnd {
  if (!_rustCore || !text) {
    return;
  }
  const char *utf8 = [text UTF8String];
  if (!utf8) {
    return;
  }
  [self _dispatchToRust:^{
    WWNCoreTextInputPreedit(self->_rustCore, utf8, cursorBegin, cursorEnd);
  }];
}

- (void)textInputDeleteSurrounding:(uint32_t)beforeLength
                       afterLength:(uint32_t)afterLength {
  if (!_rustCore) {
    return;
  }
  [self _dispatchToRust:^{
    WWNCoreTextInputDeleteSurrounding(self->_rustCore, beforeLength,
                                      afterLength);
  }];
}

- (CGRect)textInputCursorRect {
  if (!_rustCore) {
    return CGRectZero;
  }
  int32_t x = 0, y = 0, w = 0, h = 0;
  WWNCoreTextInputGetCursorRect(_rustCore, &x, &y, &w, &h);
  return CGRectMake((CGFloat)x, (CGFloat)y, (CGFloat)w, (CGFloat)h);
}

- (void)injectPointerMotionForWindow:(uint64_t)windowId
                                   x:(double)x
                                   y:(double)y
                           timestamp:(uint32_t)timestampMs {
  if (!_rustCore) {
    return;
  }
  [self _dispatchToRust:^{
    WWNCoreInjectPointerMotion(self->_rustCore, windowId, x, y, timestampMs);
  }];
}

- (void)injectPointerEnterForWindow:(uint64_t)windowId
                                  x:(double)x
                                  y:(double)y
                          timestamp:(uint32_t)timestampMs {
  if (!_rustCore) {
    return;
  }
  [self _dispatchToRust:^{
    WWNCoreInjectPointerEnter(self->_rustCore, windowId, x, y, timestampMs);
  }];
}

- (void)injectPointerLeaveForWindow:(uint64_t)windowId
                          timestamp:(uint32_t)timestampMs {
  if (!_rustCore) {
    return;
  }
  [self _dispatchToRust:^{
    WWNCoreInjectPointerLeave(self->_rustCore, windowId, timestampMs);
  }];
}

- (void)injectPointerButtonForWindow:(uint64_t)windowId
                              button:(uint32_t)button
                             pressed:(BOOL)pressed
                           timestamp:(uint32_t)timestampMs {
  if (!_rustCore) {
    return;
  }
  uint32_t state = pressed ? 1 : 0;
  [self _dispatchToRust:^{
    WWNCoreInjectPointerButton(self->_rustCore, windowId, button, state,
                               timestampMs);
  }];
}
- (void)injectPointerAxisForWindow:(uint64_t)windowId
                              axis:(uint32_t)axis
                             value:(double)value
                          discrete:(int32_t)discrete
                         timestamp:(uint32_t)timestampMs {
  if (!_rustCore) {
    return;
  }
  [self _dispatchToRust:^{
    WWNCoreInjectPointerAxis(self->_rustCore, windowId, axis, value,
                             timestampMs);
  }];
}
- (void)injectKeyWithKeycode:(uint32_t)keycode
                     pressed:(BOOL)pressed
                   timestamp:(uint32_t)timestampMs {
  if (!_rustCore) {
    return;
  }
  uint32_t state = pressed ? 1 : 0;
  [self _dispatchToRust:^{
    WWNCoreInjectKey(self->_rustCore, keycode, state, timestampMs);
  }];
}

- (void)injectKeyboardEnterForWindow:(uint64_t)windowId
                                keys:(NSArray<NSNumber *> *)keys {
  if (!_rustCore) {
    return;
  }
  // Copy array for the async block
  NSArray *keysCopy = [keys copy];
  [self _dispatchToRust:^{
    size_t count = keysCopy.count;
    uint32_t *keyArray = malloc(sizeof(uint32_t) * count);
    for (size_t i = 0; i < count; i++) {
      keyArray[i] = [keysCopy[i] unsignedIntValue];
    }
    WWNCoreInjectKeyboardEnter(self->_rustCore, windowId, keyArray, count, 0);
    free(keyArray);
  }];
}

- (void)injectKeyboardLeaveForWindow:(uint64_t)windowId {
  if (!_rustCore) {
    return;
  }
  [self _dispatchToRust:^{
    WWNCoreInjectKeyboardLeave(self->_rustCore, windowId);
  }];
}

- (void)injectWindowResize:(uint64_t)windowId
                     width:(uint32_t)width
                    height:(uint32_t)height {
  if (!_rustCore)
    return;

  NSNumber *key = @(windowId);
  CGSize dims = CGSizeMake(width, height);
  _latestResizeDims[key] = [NSValue value:&dims withObjCType:@encode(CGSize)];
  [self _drainPendingWindowResizeForId:key];
}

/// Dispatch at most one resize block per window to the compositor queue.
/// When the block completes, it checks whether newer dimensions arrived
/// for that window while it was running and re-dispatches if necessary.
- (void)_drainPendingWindowResizeForId:(NSNumber *)key {
  if ([_resizeInFlightWindows containsObject:key])
    return;

  NSValue *latestVal = _latestResizeDims[key];
  NSValue *sentVal = _sentResizeDims[key];
  if (!latestVal)
    return;
  CGSize latestDims, sentDims;
  [latestVal getValue:&latestDims];
  if (sentVal) {
    [sentVal getValue:&sentDims];
    if (CGSizeEqualToSize(latestDims, sentDims))
      return;
  }

  [_resizeInFlightWindows addObject:key];
  _sentResizeDims[key] = latestVal;
  CGSize dims = latestDims;
  uint32_t w = (uint32_t)dims.width;
  uint32_t h = (uint32_t)dims.height;
  uint64_t wid = key.unsignedLongLongValue;

  [self _dispatchToRust:^{
    WWNCoreInjectWindowResize(self->_rustCore, wid, w, h);
    dispatch_async(dispatch_get_main_queue(), ^{
      [self->_resizeInFlightWindows removeObject:key];
      [self _drainPendingWindowResizeForId:key];
    });
  }];
}

- (void)setWindowActivated:(uint64_t)windowId active:(BOOL)active {
  if (!_rustCore) {
    return;
  }
  [self _dispatchToRust:^{
    WWNCoreSetWindowActivated(self->_rustCore, windowId, active);
  }];
}

- (void)requestWindowClose:(uint64_t)windowId {
  if (!_rustCore) {
    return;
  }
  [self _dispatchToRust:^{
    WWNCoreRequestWindowClose(self->_rustCore, windowId);
  }];
}
- (void)injectModifiersWithDepressed:(uint32_t)depressed
                             latched:(uint32_t)latched
                              locked:(uint32_t)locked
                               group:(uint32_t)group {
  if (!_rustCore) {
    return;
  }
  [self _dispatchToRust:^{
    WWNLog("BRIDGE",
           @"Injecting modifiers: depressed=0x%x latched=0x%x "
           @"locked=0x%x",
           depressed, latched, locked);
    WWNCoreInjectModifiers(self->_rustCore, depressed, latched, locked, group);
  }];
}

// MARK: - Configuration

- (void)setOutputWidth:(uint32_t)w height:(uint32_t)h scale:(float)s {
  if (!_rustCore)
    return;

  _latestOutputW = w;
  _latestOutputH = h;
  _latestOutputScale = s;
  [self _drainPendingOutputResize];
}

/// Same coalescing pattern as window resize — at most one output-resize
/// block on the compositor queue at a time.
- (void)_drainPendingOutputResize {
  if (_outputResizeInFlight)
    return;
  uint32_t w = _latestOutputW;
  uint32_t h = _latestOutputH;
  float s = _latestOutputScale;
  if (w == _sentOutputW && h == _sentOutputH && s == _sentOutputScale)
    return;

  _outputResizeInFlight = YES;
  _sentOutputW = w;
  _sentOutputH = h;
  _sentOutputScale = s;

  [self _dispatchToRust:^{
    WWNCoreSetOutputSize(self->_rustCore, w, h, s);
    WWNLog("BRIDGE", @"Output: %ux%u @ %.1fx", w, h, s);
    dispatch_async(dispatch_get_main_queue(), ^{
      self->_outputResizeInFlight = NO;
      [self _drainPendingOutputResize];
    });
  }];
}

- (void)setSafeAreaInsetsTop:(int32_t)top
                       right:(int32_t)right
                      bottom:(int32_t)bottom
                        left:(int32_t)left {
  if (!_rustCore) {
    return;
  }
  [self _dispatchToRust:^{
    WWNCoreSetSafeAreaInsets(self->_rustCore, top, right, bottom, left);
    WWNLog("BRIDGE", @"Safe area insets: top=%d right=%d bottom=%d left=%d",
           top, right, bottom, left);
  }];
}

- (void)setForceSSD:(BOOL)enabled {
  if (!_rustCore) {
    return;
  }
  WWNCoreSetForceSSD(_rustCore, enabled);
  WWNLog("BRIDGE", @"Force SSD set to: %d", enabled);
}
- (void)setKeyboardRepeatRate:(int32_t)rate delay:(int32_t)delay {
}
- (void)notifyFrameComplete {
}
- (void)notifyFramePresentedForSurface:(uint32_t)surfaceId
                                buffer:(uint64_t)bufferId
                             timestamp:(uint32_t)timestamp {
  if (_rustCore) {
    WWNCoreNotifyFramePresented(_rustCore, surfaceId, bufferId, timestamp);
  }
}
- (void)flushFrameCallbacks {
}
- (NSArray<NSNumber *> *)pollRedrawRequests {
  return @[];
}

// MARK: - Window Event Polling

// C FFI for window events
typedef enum : uint32_t {
  CWindowEventTypeCreated = 0,
  CWindowEventTypeDestroyed = 1,
  CWindowEventTypeTitleChanged = 2,
  CWindowEventTypeSizeChanged = 3,
  CWindowEventTypePopupCreated = 4,
  CWindowEventTypePopupRepositioned = 5,
  CWindowEventTypeMoveRequested = 6,
  CWindowEventTypeResizeRequested = 7,
  CWindowEventTypeDecorationModeChanged = 8,
  CWindowEventTypeMinimizeRequested = 9,
  CWindowEventTypeMaximizeRequested = 10,
  CWindowEventTypeUnmaximizeRequested = 11,
  CWindowEventTypeCloseRequested = 12,
  CWindowEventTypeParentChanged = 13,
} CWindowEventType;

typedef struct CWindowEvent {
  uint64_t event_type;
  uint64_t window_id;
  uint32_t surface_id;
  char *title;
  uint32_t width;
  uint32_t height;
  uint64_t parent_id;
  int32_t x;
  int32_t y;
  uint8_t decoration_mode;  // 0 = ClientSide, 1 = ServerSide
  uint8_t fullscreen_shell; // 0 = no, 1 = yes (kiosk - no host chrome)
  uint8_t edges;            // xdg_toplevel resize_edge
  uint8_t padding;
} CWindowEvent;

extern CWindowEvent *WWNCorePopWindowEvent(void *core);
extern void WWNWindowEventFree(CWindowEvent *event);

// Legacy struct for compatibility if needed
typedef struct CWindowInfo {
  uint64_t window_id;
  uint32_t width;
  uint32_t height;
  char *title;
} CWindowInfo;

extern uint32_t WWNCorePendingWindowCount(const void *core);
extern CWindowInfo *WWNCorePopPendingWindow(void *core);
extern void WWNWindowInfoFree(CWindowInfo *info);

/// Route a single window event to the appropriate handler.
/// Must be called on the main thread (handlers create/modify UIKit/AppKit
/// views).
- (void)_dispatchWindowEvent:(CWindowEvent *)event {
  switch (event->event_type) {
  case CWindowEventTypeCreated:
    [self handleWindowCreated:event];
    break;
  case CWindowEventTypeDestroyed:
    [self handleWindowDestroyed:event];
    break;
  case CWindowEventTypeTitleChanged:
    [self handleWindowTitleChanged:event];
    break;
  case CWindowEventTypeSizeChanged:
    [self handleWindowSizeChanged:event];
    break;
  case CWindowEventTypePopupCreated:
    [self handlePopupCreated:event];
    break;
  case CWindowEventTypePopupRepositioned:
    [self handlePopupRepositioned:event];
    break;
  case CWindowEventTypeMoveRequested:
    [self handleWindowMoveRequested:event];
    break;
  case CWindowEventTypeResizeRequested:
    [self handleWindowResizeRequested:event];
    break;
  case CWindowEventTypeDecorationModeChanged:
    [self handleDecorationModeChanged:event];
    break;
  case CWindowEventTypeMinimizeRequested:
    [self handleWindowMinimizeRequested:event];
    break;
  case CWindowEventTypeMaximizeRequested:
    [self handleWindowMaximizeRequested:event];
    break;
  case CWindowEventTypeUnmaximizeRequested:
    [self handleWindowUnmaximizeRequested:event];
    break;
  case CWindowEventTypeCloseRequested:
    [self handleWindowCloseRequested:event];
    break;
  case CWindowEventTypeParentChanged:
    [self handleWindowParentChanged:event];
    break;
  }
}

/// Legacy entry point: pops and handles all pending window events
/// synchronously.  In the new architecture the compositor tick handles
/// this via _dispatchWindowEvent:, but this method is kept for any
/// external callers that need manual polling.
- (void)pollAndHandleWindowEvents {
  if (!_rustCore) {
    return;
  }

  while (true) {
    CWindowEvent *event = WWNCorePopWindowEvent(_rustCore);
    if (!event)
      break;

    [self _dispatchWindowEvent:event];
    WWNWindowEventFree(event);
  }
}

// Window Management
- (NSMutableDictionary<NSNumber *, WWNWindow *> *)windows {
  return (NSMutableDictionary<NSNumber *, WWNWindow *> *)_windows;
}


- (void)handleWindowCreated:(CWindowEvent *)event {
  WWNLog("BRIDGE",
         @"handleWindowCreated: id=%llu size=%ux%u decoration_mode=%u "
         @"fullscreen_shell=%u",
         event->window_id, event->width, event->height, event->decoration_mode,
         event->fullscreen_shell);

  CGFloat screenW = [NSScreen mainScreen].frame.size.width;
  CGFloat screenH = [NSScreen mainScreen].frame.size.height;
  BOOL shouldInjectResize = NO;
  BOOL shouldUpdateOutput = NO; // Whether wl_output.mode must also change.

  NSRect contentRect;
  if (event->fullscreen_shell) {
    // Fullscreen-shell surfaces fill the output at whatever size the output
    // reports.  When Force SSD is active the NSWindow gets a native macOS
    // titlebar, which consumes height from the content area and shrinks the
    // drawable region below the output dimensions Weston expects.
    //
    // We must inject a resize after window creation so that:
    //   • wl_output.mode is updated to the actual content area (not the
    //     full output including the titlebar region), and
    //   • the fullscreen_shell surface receives a configure at the correct
    //     drawable size.
    //
    // Without this, Weston renders its desktop shell at the full output size
    // and the bottom strip is clipped/hidden behind the window chrome.
    contentRect = NSMakeRect(100, 100, event->width, event->height);
    if (event->decoration_mode == 1) {
      // Force SSD: titlebar will eat into the content rect after window init.
      shouldInjectResize = YES;
      shouldUpdateOutput = YES;
    }
  } else if (event->width >= (uint32_t)screenW &&
             event->height >= (uint32_t)screenH) {
    // xdg_toplevel requesting full-screen dimensions (e.g. a nested
    // compositor like Weston).  Place it in a reasonable windowed size,
    // then update BOTH wl_output.mode and xdg_toplevel configure to the
    // new content-area size.
    //
    // Critical: nested compositors (Weston) size their *virtual display*
    // to wl_output.mode, not to xdg_toplevel.configure.  If we only send
    // a new configure without also updating the output mode, Weston renders
    // at the old, full-screen output dimensions and the content is clipped
    // or misaligned inside the smaller macOS host window.
    CGFloat defaultW = fmin(1024, screenW * 0.75);
    CGFloat defaultH = fmin(768, screenH * 0.75);
    contentRect = NSMakeRect(100, 100, defaultW, defaultH);
    shouldInjectResize = YES;
    shouldUpdateOutput = YES;
  } else if (event->width > (uint32_t)(screenW * 0.85) ||
             event->height > (uint32_t)(screenH * 0.85)) {
    // Some clients initially inherit the compositor output size even though
    // they are ordinary windowed applications.  On mixed-scale displays that
    // size can be just below the full-screen test above, producing an enormous
    // mostly blank window until the first manual resize.  Keep the initial
    // content comfortably on-screen and immediately configure the client to
    // the same dimensions.  Do not alter wl_output for ordinary toplevels.
    CGFloat defaultW = fmin(1024, screenW * 0.75);
    CGFloat defaultH = fmin(768, screenH * 0.75);
    contentRect = NSMakeRect(100, 100, defaultW, defaultH);
    shouldInjectResize = YES;
  } else {
    contentRect = NSMakeRect(100, 100, event->width, event->height);
    // For SSD windows the actual content area must be communicated back
    // to the Rust compositor so wl_output stays in sync.  Nested
    // compositors like Weston rely on wl_output.mode matching the
    // content area.
    if (event->decoration_mode == 1) {
      shouldInjectResize = YES;
    }
  }
  NSWindowStyleMask styleMask;
  if (event->fullscreen_shell || event->decoration_mode == 1) {
    styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
  } else {
    styleMask = NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable |
                NSWindowStyleMaskMiniaturizable;
  }

  WWNWindow *window =
      [[WWNWindow alloc] initWithContentRect:contentRect
                                   styleMask:styleMask
                                     backing:NSBackingStoreBuffered
                                       defer:NO];

  window.wwnWindowId = event->window_id;

  NSString *title = (event->title && strlen(event->title) > 0)
                        ? [NSString stringWithUTF8String:event->title]
                        : @"";
  [window setTitle:title];

  // Create content view
  WWNView *contentView =
      [[WWNView alloc] initWithFrame:NSMakeRect(0, 0,
                                               contentRect.size.width,
                                               contentRect.size.height)];
  contentView.wantsLayer = YES;
  contentView.layer.backgroundColor = [[NSColor blackColor] CGColor];
  contentView.layer.contentsGravity = kCAGravityResize;

  [window setContentView:contentView];
  [window makeFirstResponder:contentView];

  [window center];
  // Deferred: Window remains hidden until a buffer is attached (xdg-shell
  // semantics)

  [_windows setObject:window forKey:@(event->window_id)];
  WWNLog("BRIDGE", @"Created window %llu: %@ (total windows: %lu)",
         event->window_id, title, (unsigned long)[_windows count]);

  // If the window was placed at a default size (smaller than what the
  // Wayland client requested), update wl_output.mode first, then inject
  // the xdg_toplevel configure resize.
  //
  // Order matters: the output-mode update must arrive at the Rust core
  // BEFORE the configure so that nested compositors (Weston) see a
  // consistent wl_output.mode matching the configure dimensions.  Both
  // calls use the same serial compositor queue, so FIFO ordering is
  // guaranteed as long as we call setOutputWidth:… before injectWindowResize:.
  if (shouldInjectResize) {
    NSSize contentSize = [window contentLayoutRect].size;
    WWNLog("BRIDGE", @"Injecting initial resize for window %llu: %.0fx%.0f%@",
           event->window_id, contentSize.width, contentSize.height,
           shouldUpdateOutput ? @" (+ output mode update)" : @"");

    if (shouldUpdateOutput && contentSize.width > 0 && contentSize.height > 0) {
      // Update wl_output.mode to the new windowed content-area size so
      // nested compositors configure their virtual display correctly.
      [self setOutputWidth:(uint32_t)contentSize.width
                    height:(uint32_t)contentSize.height
                     scale:_latestOutputScale > 0 ? _latestOutputScale : 1.0f];
    }

    [self injectWindowResize:event->window_id
                       width:(uint32_t)contentSize.width
                      height:(uint32_t)contentSize.height];
  }
}

- (void)handleWindowMoveRequested:(CWindowEvent *)event {
  WWNLog("BRIDGE", @"handleWindowMoveRequested: id=%llu", event->window_id);
  WWNWindow *window = _windows[@(event->window_id)];
  if (!window)
    return;

  NSEvent *currentEvent = [NSApp currentEvent];
  if (currentEvent && (currentEvent.type == NSEventTypeLeftMouseDown ||
                       currentEvent.type == NSEventTypeLeftMouseDragged)) {
    [window performWindowDragWithEvent:currentEvent];
  } else if (window.lastMouseDownEvent) {
    [window performWindowDragWithEvent:window.lastMouseDownEvent];
  }
}

- (void)handleDecorationModeChanged:(CWindowEvent *)event {
  WWNWindow *window = _windows[@(event->window_id)];
  if (!window || ![window isKindOfClass:[WWNWindow class]])
    return;
  NSWindowStyleMask styleMask;
  if (event->decoration_mode == 1) {
    styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
  } else {
    styleMask = NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable |
                NSWindowStyleMaskMiniaturizable;
  }
  [window setStyleMask:styleMask];

  // After changing the style mask the content area may have shrunk (e.g. a
  // titlebar was added for SSD mode).  Inject the new content-area size
  // immediately so the Rust compositor state is correct before
  // reconfigure_window_decorations sends an xdg_toplevel.configure to the
  // client.  Without this, nested compositors receive the pre-titlebar
  // dimensions and render at the wrong size.
  NSSize contentSize = [window contentLayoutRect].size;
  if (contentSize.width > 0 && contentSize.height > 0) {
    WWNLog("BRIDGE",
           @"Decoration mode changed for window %llu: %s — injecting "
           @"content resize %.0fx%.0f",
           event->window_id,
           event->decoration_mode == 1 ? "ServerSide" : "ClientSide",
           contentSize.width, contentSize.height);
    [self injectWindowResize:event->window_id
                       width:(uint32_t)contentSize.width
                      height:(uint32_t)contentSize.height];
  } else {
    WWNLog("BRIDGE", @"Decoration mode changed for window %llu: %s",
           event->window_id,
           event->decoration_mode == 1 ? "ServerSide" : "ClientSide");
  }
}

- (void)handleWindowResizeRequested:(CWindowEvent *)event {
  WWNLog("BRIDGE", @"handleWindowResizeRequested: id=%llu edges=%u",
         event->window_id, event->edges);
  WWNWindow *window = _windows[@(event->window_id)];
  if (!window)
    return;

  NSEvent *mouseEvent = [NSApp currentEvent];
  if (!mouseEvent || (mouseEvent.type != NSEventTypeLeftMouseDown &&
                      mouseEvent.type != NSEventTypeLeftMouseDragged)) {
    mouseEvent = window.lastMouseDownEvent;
  }
  if (!mouseEvent)
    return;

  uint8_t edges = event->edges;
  NSPoint startLoc = [NSEvent mouseLocation];
  NSRect startFrame = window.frame;

  // Track the mouse and resize the window according to the requested edge
  [window
      trackEventsMatchingMask:(NSEventMaskLeftMouseDragged |
                               NSEventMaskLeftMouseUp)
                      timeout:NSEventDurationForever
                         mode:NSEventTrackingRunLoopMode
                      handler:^(NSEvent *trackEvent, BOOL *stop) {
                        if (trackEvent.type == NSEventTypeLeftMouseUp) {
                          *stop = YES;
                          return;
                        }

                        NSPoint curLoc = [NSEvent mouseLocation];
                        CGFloat dx = curLoc.x - startLoc.x;
                        CGFloat dy = curLoc.y - startLoc.y;

                        NSRect newFrame = startFrame;

                        // Horizontal edges
                        if (edges & 8) { // Right
                          newFrame.size.width =
                              MAX(100, startFrame.size.width + dx);
                        } else if (edges & 4) { // Left
                          CGFloat newW = MAX(100, startFrame.size.width - dx);
                          newFrame.origin.x = startFrame.origin.x +
                                              startFrame.size.width - newW;
                          newFrame.size.width = newW;
                        }

                        // Vertical edges (macOS y is flipped: origin is
                        // bottom-left)
                        if (edges & 1) { // Top (Wayland top → macOS top →
                                         // increase height, keep top)
                          CGFloat newH = MAX(100, startFrame.size.height + dy);
                          newFrame.size.height = newH;
                        } else if (edges & 2) { // Bottom (Wayland bottom →
                                                // macOS bottom)
                          CGFloat newH = MAX(100, startFrame.size.height - dy);
                          newFrame.origin.y = startFrame.origin.y +
                                              startFrame.size.height - newH;
                          newFrame.size.height = newH;
                        }

                        [window setFrame:newFrame display:YES];
                      }];
}

- (void)handleWindowMinimizeRequested:(CWindowEvent *)event {
  WWNLog("BRIDGE", @"handleWindowMinimizeRequested: id=%llu", event->window_id);
  WWNWindow *window = _windows[@(event->window_id)];
  if (window) {
    [window miniaturize:nil];
  }
}

- (void)handleWindowMaximizeRequested:(CWindowEvent *)event {
  WWNLog("BRIDGE", @"handleWindowMaximizeRequested: id=%llu", event->window_id);
  WWNWindow *window = _windows[@(event->window_id)];
  if (window) {
    if (![window isZoomed]) {
      window.processingResize = YES;
      [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        [window zoom:nil];
      }
          completionHandler:^{
            window.processingResize = NO;
            NSNotification *note = [NSNotification
                notificationWithName:NSWindowDidResizeNotification
                              object:window];
            [window windowDidResize:note];
          }];
    }
  }
}

- (void)handleWindowUnmaximizeRequested:(CWindowEvent *)event {
  WWNLog("BRIDGE", @"handleWindowUnmaximizeRequested: id=%llu",
         event->window_id);
  WWNWindow *window = _windows[@(event->window_id)];
  if (window) {
    if ([window isZoomed]) {
      window.processingResize = YES;
      [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        [window zoom:nil];
      }
          completionHandler:^{
            window.processingResize = NO;
            NSNotification *note = [NSNotification
                notificationWithName:NSWindowDidResizeNotification
                              object:window];
            [window windowDidResize:note];
          }];
    }
  }
}

- (void)handleWindowCloseRequested:(CWindowEvent *)event {
  WWNLog("BRIDGE", @"handleWindowCloseRequested: id=%llu", event->window_id);
  NSWindow *window = [_windows objectForKey:@(event->window_id)];
  if (window) {
    if ([window isKindOfClass:[WWNWindow class]]) {
      ((WWNWindow *)window).suppressCompositorCallbacks = YES;
    }
    [window orderOut:nil];
    [self requestWindowClose:event->window_id];
  }
}

/* Forget the cached surface layers hosted by a view that is going away.
 *
 * updateLayerForNode: re-parents a layer whose host no longer matches, so a
 * leftover entry is not a correctness problem on its own. Dropping it here
 * keeps _surfaceLayers from accumulating one dead layer per surface id for the
 * lifetime of the compositor -- popup surfaces churn on every menu open.
 */
- (void)dropCachedLayersHostedBy:(id)contentView {
  if (![contentView isKindOfClass:[WWNView class]]) {
    return;
  }
  CALayer *hostLayer = ((WWNView *)contentView).contentLayer;
  NSMutableArray<NSNumber *> *stale = [NSMutableArray array];
  for (NSNumber *key in _surfaceLayers) {
    if (_surfaceLayers[key].superlayer == hostLayer) {
      [stale addObject:key];
    }
  }
  for (NSNumber *key in stale) {
    [_surfaceLayers[key] removeFromSuperlayer];
    [_surfaceLayers removeObjectForKey:key];
  }
}

- (void)handleWindowDestroyed:(CWindowEvent *)event {
  // Popup host windows are also present in _windows so render layers can find
  // them. They must be removed only through WWNPopupHost; treating one as a
  // toplevel first releases its content/animation state twice.
  id<WWNPopupHost> popupHost = [_popups objectForKey:@(event->window_id)];
  if (popupHost) {
    [self dropCachedLayersHostedBy:popupHost.contentView];
    [popupHost dismiss];
    [_popups removeObjectForKey:@(event->window_id)];
    [_windows removeObjectForKey:@(event->window_id)];
    WWNLog("BRIDGE", @"Destroyed popup %llu", event->window_id);
    return;
  }

  NSWindow *window = [_windows objectForKey:@(event->window_id)];
  if (window) {
    @try {
      if ([window isKindOfClass:[WWNWindow class]]) {
        ((WWNWindow *)window).suppressCompositorCallbacks = YES;
      }

      // Detach known surface layers from this host view before teardown.
      // This prevents stale layer tree references after client disconnect.
      id contentView = [window contentView];
      [self dropCachedLayersHostedBy:contentView];
      if ([contentView isKindOfClass:[WWNView class]]) {
        CALayer *hostLayer = ((WWNView *)contentView).contentLayer;
        NSArray<CALayer *> *children = [hostLayer.sublayers copy];
        for (CALayer *layer in children) {
          [layer removeFromSuperlayer];
        }
      }

      [_windows removeObjectForKey:@(event->window_id)];

      // Avoid NSWindow close-time delegate/first-responder cascades when the
      // Wayland client has already been torn down. AppKit may still have close
      // or transform animations queued for this host window, so only hide and
      // detach it here.
      [window setDelegate:nil];
      [window orderOut:nil];
      [window setContentView:nil];
    } @catch (NSException *exception) {
      WWNLog("BRIDGE",
             @"Exception while destroying window %llu: %@ (%@)",
             event->window_id, exception.name, exception.reason);
      [_windows removeObjectForKey:@(event->window_id)];
      @try {
        [window orderOut:nil];
      } @catch (NSException *inner) {
        WWNLog("BRIDGE", @"Suppressed orderOut exception for window %llu: %@",
               event->window_id, inner.reason);
      }
    }
    WWNLog("BRIDGE", @"Destroyed window %llu", event->window_id);
  }

  id<WWNPopupHost> popup = [_popups objectForKey:@(event->window_id)];
  if (popup) {
    [popup dismiss];
    [_popups removeObjectForKey:@(event->window_id)];
    [_windows removeObjectForKey:@(event->window_id)];
    WWNLog("BRIDGE", @"Destroyed popup %llu", event->window_id);
  }
}

- (void)handleWindowTitleChanged:(CWindowEvent *)event {
  if (!event->title)
    return;
  NSString *newTitle = [NSString stringWithUTF8String:event->title];

  NSWindow *window = [self.windows objectForKey:@(event->window_id)];
  if (window) {
    [window setTitle:newTitle];
    WWNLog("BRIDGE", @"Updated title for window %llu to '%@'", event->window_id,
           newTitle);
    if (newTitle.length > 0) {
      [[NSProcessInfo processInfo] setProcessName:newTitle];
    }
  } else {
    WWNLog("BRIDGE",
           @"Warning: handleWindowTitleChanged for unknown window %llu",
           event->window_id);
  }
}

- (void)handleWindowSizeChanged:(CWindowEvent *)event {
  WWNWindow *window = [self.windows objectForKey:@(event->window_id)];
  if (window) {
    // Check if size actually changed to avoid loop
    if (window.contentView.bounds.size.width != event->width ||
        window.contentView.bounds.size.height != event->height) {

      window.processingResize = YES;
      NSRect frame =
          [window frameRectForContentRect:NSMakeRect(0, 0, event->width,
                                                     event->height)];
      frame.origin = window.frame.origin; // Keep origin
      [window setFrame:frame display:YES];
      window.processingResize = NO;
    }
  }
}

- (void)handleWindowParentChanged:(CWindowEvent *)event {
  NSWindow *child = [self.windows objectForKey:@(event->window_id)];
  if (!child) {
    WWNLog("BRIDGE", @"ParentChanged for unknown window %llu",
           event->window_id);
    return;
  }

  // Detach from whatever it was attached to first: set_parent can retarget, and
  // AppKit keeps a window in its old parent's child list otherwise.
  if (child.parentWindow) {
    [child.parentWindow removeChildWindow:child];
  }

  if (event->parent_id == 0) {
    WWNLog("BRIDGE", @"Window %llu parent unset", event->window_id);
    return;
  }

  NSWindow *parent = [self.windows objectForKey:@(event->parent_id)];
  if (!parent) {
    WWNLog("BRIDGE", @"ParentChanged: parent %llu not found for window %llu",
           event->parent_id, event->window_id);
    return;
  }

  // Ordering it above the parent is what makes a modal dialog visible. The
  // client has already grabbed input on the parent by this point, so a dialog
  // left unstacked reads to the user as a frozen window with nothing on screen.
  [parent addChildWindow:child ordered:NSWindowAbove];
  WWNLog("BRIDGE", @"Window %llu is now a child of %llu", event->window_id,
         event->parent_id);
}

- (void)handlePopupCreated:(CWindowEvent *)event {
  NSView *parentView = nil;
  NSWindow *parentWindow = [self.windows objectForKey:@(event->parent_id)];

  WWNLog("BRIDGE",
         @"Popup create request: surface %u, window %llu, parent %llu",
         event->surface_id, event->window_id, event->parent_id);

  if (parentWindow) {
    WWNLog("BRIDGE", @"Found parent as Window: %p", parentWindow);
    parentView = parentWindow.contentView;
  } else {
    id<WWNPopupHost> parentPopup = [_popups objectForKey:@(event->parent_id)];
    if (parentPopup) {
      WWNLog("BRIDGE", @"Found parent as Popup: %p", parentPopup);
      parentView = parentPopup.contentView;
    } else {
      WWNLog("BRIDGE", @"Parent %llu NOT found in windows or popups",
             event->parent_id);
    }
  }

  if (!parentView) {
    WWNLog("BRIDGE",
           @"Warning: Popup created for unknown parent %llu, falling "
           @"back to key "
           @"window",
           event->parent_id);
    parentWindow = [NSApp keyWindow];
    parentView = parentWindow.contentView;
  }

  if (parentView) {
    WWNLog("BRIDGE",
           @"Creating popup (NSWindow) for surface %u (window %llu) "
           @"anchored to parent %llu at %d,%d (%ux%u)",
           event->surface_id, event->window_id, event->parent_id, event->x,
           event->y, event->width, event->height);

    id<WWNPopupHost> popup =
        [[WWNPopupWindow alloc] initWithParentView:parentView];

    [popup setContentSize:CGSizeMake(event->width, event->height)];
    [popup setWindowId:event->window_id];

    [_popups setObject:popup forKey:@(event->window_id)];
    _windows[@(event->window_id)] = ((WWNPopupWindow *)popup).window;

    // The C event belongs to the polling batch and is freed after this method
    // returns. Capture the scalar ID, not the transient event pointer.
    const uint64_t popupWindowId = event->window_id;
    __unsafe_unretained typeof(self) weakSelf = self;
    popup.onDismiss = ^{
      [weakSelf handlePopupDismissed:popupWindowId];
    };

    // Compute screen point for popup top-left (Wayland x,y is parent-relative)
    NSRect windowRect =
        [parentView convertRect:CGRectMake(event->x, event->y, 1, 1)
                         toView:nil];
    NSRect screenRect = [parentView.window convertRectToScreen:windowRect];
    CGPoint topLeft =
        CGPointMake(screenRect.origin.x, screenRect.origin.y - event->height);

    [popup showAtScreenPoint:topLeft];
  }
}

- (void)handlePopupDismissed:(uint64_t)windowId {
  WWNLog("BRIDGE", @"Popup dismissed locally: %llu", windowId);
  [_popups removeObjectForKey:@(windowId)];
  [_windows removeObjectForKey:@(windowId)];
  // TODO: Notify Rust core of dismissal if needed (xdg_popup.popup_done)
}

- (void)handlePopupRepositioned:(CWindowEvent *)event {
  id<WWNPopupHost> popup = [_popups objectForKey:@(event->window_id)];
  if (!popup) {
    WWNLog("BRIDGE", @"Warning: PopupRepositioned for unknown window %llu",
           event->window_id);
    return;
  }

  WWNLog("BRIDGE", @"Repositioning popup %llu to %d,%d (%ux%u)",
         event->window_id, event->x, event->y, event->width, event->height);

  [popup setContentSize:CGSizeMake(event->width, event->height)];

  NSView *parentView = popup.parentView;
  if (!parentView || !parentView.window) {
    WWNLog("BRIDGE", @"Error: Popup %llu has no parent view/window",
           event->window_id);
    return;
  }

  NSRect windowRect =
      [parentView convertRect:CGRectMake(event->x, event->y, 1, 1) toView:nil];
  NSRect screenRect = [parentView.window convertRectToScreen:windowRect];
  CGPoint topLeft =
      CGPointMake(screenRect.origin.x, screenRect.origin.y - event->height);

  [popup showAtScreenPoint:topLeft];
}


- (NSUInteger)pendingWindowCount {
  if (!_rustCore) {
    return 0;
  }
  return WWNCorePendingWindowCount(_rustCore);
}

- (NSDictionary *)popPendingWindow {
  return nil;
}


// MARK: - Buffer updates

- (nullable CBufferData *)popPendingBuffer {
  if (!_rustCore) {
    return NULL;
  }
  return WWNCorePopPendingBuffer(_rustCore);
}

- (void)freeBufferData:(CBufferData *)data {
  WWNBufferDataFree(data);
}

@end

#ifdef __cplusplus
extern "C" {
#endif
  /* Send the compositor's diagnostics to the requested log file.
   *
   * Both wlog! and WWNLog write to stderr, which goes nowhere reachable when
   * the instance manager is launched the normal way: it is not in the unified
   * log, and starting the bundle binary from a terminal to watch stderr hangs.
   * Redirecting the stream itself captures every existing call site without
   * touching any of them. Set MUPLAR_WAYLAND_LOG_FILE with `launchctl setenv`
   * so a normally-launched app inherits it. WAWONA_LOG_FILE remains supported
   * for existing developer workflows.
   */
  static void wwn_redirect_log_if_requested(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      const char *path = getenv("MUPLAR_WAYLAND_LOG_FILE");
      if (!path || !path[0])
        path = getenv("WAWONA_LOG_FILE");
      if (!path || !path[0])
        return;
      FILE *f = freopen(path, "a", stderr);
      if (!f) {
        return;
      }
      setvbuf(stderr, NULL, _IOLBF, 0);
      WWNLog("BRIDGE", @"log redirected to %s (pid %d)", path, (int) getpid());
    });
  }

  void MuplarWawonaStartInProcess(const char *socket_name) {
    wwn_redirect_log_if_requested();
    void (^block)(void) = ^{
      NSScreen *screen = [NSScreen mainScreen];
      CGFloat scale = screen ? screen.backingScaleFactor : 1.0;
      
      WWNCompositorBridge *bridge = [WWNCompositorBridge sharedBridge];
      [bridge setOutputWidth:1024 height:768 scale:(float)scale];
      [bridge setForceSSD:NO];
      
      NSString *socketNS = socket_name ? [NSString stringWithUTF8String:socket_name] : @"wayland-0";
      [bridge startWithSocketName:socketNS];
    };
    if ([NSThread isMainThread]) {
      block();
    } else {
      dispatch_sync(dispatch_get_main_queue(), block);
    }
  }

  void MuplarWawonaStopInProcess(void) {
    void (^block)(void) = ^{
      [[WWNCompositorBridge sharedBridge] stop];
    };
    if ([NSThread isMainThread]) {
      block();
    } else {
      dispatch_sync(dispatch_get_main_queue(), block);
    }
  }

  bool MuplarWawonaIsRunningInProcess(void) {
    __block BOOL running = NO;
    void (^block)(void) = ^{
      running = [[WWNCompositorBridge sharedBridge] isRunning];
    };
    if ([NSThread isMainThread]) {
      block();
    } else {
      dispatch_sync(dispatch_get_main_queue(), block);
    }
    return running;
  }
#ifdef __cplusplus
}
#endif
