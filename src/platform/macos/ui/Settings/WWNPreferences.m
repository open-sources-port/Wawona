#import "WWNPreferences.h"
#import "../Machines/WWNMachinesCoordinator.h"
#import "../../platform/macos/WWNCompositorBridge.h"
#import "../../../../util/WWNLog.h"
#import "../Helpers/WWNImageLoader.h"
#import "WWNPreferencesManager.h"
#import "WWNSettingsModel.h"
#import "WWNWaypipeRunner.h"
// #if TARGET_OS_IPHONE || TARGET_OS_SIMULATOR
// #import <HIAHKernel/HIAHKernel.h>
// #endif
//  #import "../../core/WWNKernel.h" // Removed
#import <Network/Network.h>
#import <objc/runtime.h>

// System headers removed as they are now used in WWNWaypipeRunner or unused
#import <AppKit/AppKit.h>
#import <arpa/inet.h>
#import <errno.h>
#import <ifaddrs.h>
#import <netdb.h>
#import <spawn.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <sys/wait.h>
#import <unistd.h>

#ifndef WAWONA_VERSION
#define WAWONA_VERSION "0.0.0-unknown"
#endif

#ifndef WAWONA_WAYLAND_VERSION
#define WAWONA_WAYLAND_VERSION "Bundled"
#endif

// Similar logic for other versions...
#ifndef WAWONA_WAYPIPE_VERSION
#define WAWONA_WAYPIPE_VERSION "unknown"
#endif

#ifndef WAWONA_MESA_VERSION
#define WAWONA_MESA_VERSION "Bundled"
#endif

#ifndef WAWONA_EPOLL_SHIM_VERSION
#define WAWONA_EPOLL_SHIM_VERSION "Bundled"
#endif

#ifndef WAWONA_LIBSSH2_VERSION
#define WAWONA_LIBSSH2_VERSION "Bundled"
#endif

#ifndef WAWONA_LIBFFI_VERSION
#define WAWONA_LIBFFI_VERSION "Bundled"
#endif

#ifndef WAWONA_LZ4_VERSION
#define WAWONA_LZ4_VERSION "Bundled"
#endif

#ifndef WAWONA_ZSTD_VERSION
#define WAWONA_ZSTD_VERSION "Bundled"
#endif

#ifndef WAWONA_XKBCOMMON_VERSION
#define WAWONA_XKBCOMMON_VERSION "Bundled"
#endif

#ifndef WAWONA_SSHPASS_VERSION
#define WAWONA_SSHPASS_VERSION "Bundled"
#endif

// MARK: - Helper Class Interfaces

@interface WWNPreferencesSidebar
    : NSViewController <NSOutlineViewDataSource, NSOutlineViewDelegate>
@property(nonatomic, weak) WWNPreferences *parent;
@property(nonatomic, strong) NSOutlineView *outlineView;
@end

@interface WWNPreferencesContent
    : NSViewController <NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic, strong) WWNPreferencesSection *section;
@property(nonatomic, strong) NSTableView *tableView;
@end

// MARK: - Main Class Extension

@interface WWNPreferences () <WWNWaypipeRunnerDelegate
                              ,
                              NSTextFieldDelegate, NSToolbarDelegate
                              >
@property(nonatomic, strong, readwrite)
    NSArray<WWNPreferencesSection *> *sections;
@property(nonatomic, strong) NSMutableString *waypipeStatusText;
@property(nonatomic, assign) BOOL waypipeMarkedConnected;
@property(nonatomic, strong) NSSplitViewController *splitVC;
@property(nonatomic, strong) WWNPreferencesSidebar *sidebar;
@property(nonatomic, strong) WWNPreferencesContent *content;
@property(nonatomic, strong) NSWindowController *winController;
@property(nonatomic, strong) NSPanel *waypipeStatusPanel;
@property(nonatomic, strong) NSTextView *waypipeStatusTextView;
@property(nonatomic, strong) NSButton *waypipeStopButton;
- (NSArray<WWNPreferencesSection *> *)buildSections;
- (void)runWaypipe;
- (NSString *)localIPAddress;
- (NSString *)getLibSSH2Version;
- (NSString *)getSocketPath;
- (void)pingHost;
- (void)pingSSHHost;
- (void)testSSHConnection;
- (void)debouncedReloadData;
- (void)showSection:(NSInteger)idx;
- (void)toggleMacOSPasswordVisibility:(NSButton *)sender;
@end

// MARK: - Main Implementation

@implementation WWNPreferences


+ (instancetype)sharedPreferences {
  static WWNPreferences *sharedInstance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedInstance = [[self alloc] init];
  });
  return sharedInstance;
}


- (instancetype)init {
  self = [super init];
  if (self) {
    [WWNWaypipeRunner sharedRunner].delegate = self;
    self.sections = [self buildSections];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(defaultsChanged:)
               name:NSUserDefaultsDidChangeNotification
             object:nil];
  }
  return self;
}

- (void)defaultsChanged:(NSNotification *)notification {
  static BOOL sLastForceSSD = NO;
  static BOOL sHasCheckedForceSSD = NO;

  NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
  BOOL enabled = [defs boolForKey:@"ForceServerSideDecorations"];
  if ([defs objectForKey:@"ForceServerSideDecorations"] || enabled) {
    if (!sHasCheckedForceSSD || sLastForceSSD != enabled) {
      sLastForceSSD = enabled;
      sHasCheckedForceSSD = YES;
      [[WWNCompositorBridge sharedBridge] setForceSSD:enabled];
      WWNLog("PREFS", @"Force SSD changed to: %d", enabled);
    }
  }

  [NSObject
      cancelPreviousPerformRequestsWithTarget:self
                                     selector:@selector(debouncedReloadData)
                                       object:nil];
  [self performSelector:@selector(debouncedReloadData)
             withObject:nil
             afterDelay:0.1];
}

- (void)debouncedReloadData {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.sidebar.outlineView) {
      [self.sidebar.outlineView reloadData];
    }
  });
}


#define ITEM(t, k, ty, def, d)                                                 \
  [WWNSettingItem itemWithTitle:t key:k type:ty default:(def)desc:(d)]


- (NSArray<WWNPreferencesSection *> *)buildSections {
  NSMutableArray *sects = [NSMutableArray array];

  // DISPLAY
  WWNPreferencesSection *display = [[WWNPreferencesSection alloc] init];
  display.title = @"Display";
  display.icon = @"display";
  display.iconColor = [NSColor systemBlueColor];
  NSMutableArray *displayItems = [NSMutableArray arrayWithArray:@[
    ITEM(@"Force Server-Side Decorations", @"ForceServerSideDecorations",
         WSettingSwitch, @NO, @"Forces macOS-style window decorations."),
    ITEM(@"Auto Scale", @"AutoScale", WSettingSwitch, @YES,
         @"Matches macOS UI Scaling.")
  ]];

  // Show macOS Cursor option only on macOS
  [displayItems insertObject:ITEM(@"Show macOS Cursor", @"RenderMacOSPointer",
                                  WSettingSwitch, @NO,
                                  @"Toggles macOS cursor visibility.")
                     atIndex:1];

  display.items = displayItems;
  [sects addObject:display];

  // INPUT
  WWNPreferencesSection *input = [[WWNPreferencesSection alloc] init];
  input.title = @"Input";
  input.icon = @"keyboard";
  input.iconColor = [NSColor systemPurpleColor];
  WWNSettingItem *touchInputItem =
      ITEM(@"Touch Input Type", @"TouchInputType", WSettingPopup,
           @"Multi-Touch", @"Input method for touch interactions.");
  touchInputItem.options = @[ @"Multi-Touch", @"Touchpad" ];

  input.items = @[
    touchInputItem,
    ITEM(@"Swap CMD with ALT", @"SwapCmdWithAlt", WSettingSwitch, @YES,
         @"Swaps Command and Alt keys."),
    ITEM(@"Universal Clipboard", @"UniversalClipboard", WSettingSwitch, @YES,
         @"Syncs clipboard with macOS."),
    // --- Text Assist divider ---
    ITEM(@"Text Assist", nil, WSettingInfo, nil,
         @"Autocorrection, text suggestions, and dictation for Wayland "
         @"clients."),
    ITEM(@"Enable Text Assist", @"EnableTextAssist", WSettingSwitch, @NO,
         @"Enables autocorrect, text suggestions, smart punctuation, "
         @"swipe-to-type, and text replacements powered by the native "
         @"platform keyboard."),
    ITEM(@"Enable Dictation", @"EnableDictation", WSettingSwitch, @NO,
         @"Enables voice dictation input. Spoken text is transcribed and "
         @"sent to the focused Wayland client.")
  ];
  [sects addObject:input];

  // GRAPHICS
  WWNPreferencesSection *graphics = [[WWNPreferencesSection alloc] init];
  graphics.title = @"Graphics";
  graphics.icon = @"cpu";
  graphics.iconColor = [NSColor systemRedColor];
  WWNSettingItem *vulkanDriverItem =
      ITEM(@"Vulkan Driver", @"VulkanDriver", WSettingPopup, @"moltenvk",
           @"Select Vulkan implementation. None disables Vulkan.");
  vulkanDriverItem.options = @[ @"None", @"MoltenVK", @"KosmicKrisp" ];
  vulkanDriverItem.optionValues = @[ @"none", @"moltenvk", @"kosmickrisp" ];

  WWNSettingItem *openGLDriverItem =
      ITEM(@"OpenGL Driver", @"OpenGLDriver", WSettingPopup, @"angle",
           @"Select OpenGL/GLES implementation. None disables OpenGL.");
  openGLDriverItem.options = @[ @"None", @"ANGLE", @"MoltenGL" ];
  openGLDriverItem.optionValues = @[ @"none", @"angle", @"moltengl" ];

  graphics.items = @[
    vulkanDriverItem, openGLDriverItem,
    ITEM(@"Enable DMABUF", @"DmabufEnabled", WSettingSwitch, @YES,
         @"Zero-copy texture sharing.")
  ];
  [sects addObject:graphics];

  // CONNECTION
  WWNPreferencesSection *connection = [[WWNPreferencesSection alloc] init];
  connection.title = @"Connection";
  connection.icon = @"network";
  connection.iconColor = [NSColor systemOrangeColor];

  // Build dynamic environment variable values
  NSString *socketDir = [self getSocketPath];
  NSString *socketName = [[WWNCompositorBridge sharedBridge] socketName];
  if (!socketName || socketName.length == 0)
    socketName = @"wayland-0";
  NSString *socketFullPath =
      [socketDir stringByAppendingPathComponent:socketName];

  NSString *envSnippet = [NSString
      stringWithFormat:
          @"export XDG_RUNTIME_DIR=\"%@\"\nexport WAYLAND_DISPLAY=\"%@\"",
          socketDir, socketName];

  connection.items = @[
    ITEM(@"XDG_RUNTIME_DIR", @"XDGRuntimeDir", WSettingInfo, socketDir,
         @"Runtime directory where the Wayland socket lives. "
         @"Set this in your shell to connect clients."),
    ITEM(@"WAYLAND_DISPLAY", @"WaylandDisplay", WSettingInfo, socketName,
         @"Socket name clients connect to (e.g. wayland-0)."),
    ITEM(@"Socket Path", @"WaylandSocketPath", WSettingInfo, socketFullPath,
         @"Full path to the Wayland socket."),
    ITEM(@"Shell Setup", @"WaylandShellSetup", WSettingInfo, envSnippet,
         @"Copy and paste into your terminal to connect "
         @"Wayland clients to Muplar Wayland."),
    ITEM(@"TCP Port", @"TCPListenerPort", WSettingNumber, @6000,
         @"Port for TCP listener.")
  ];
  [sects addObject:connection];

  // ADVANCED
  WWNPreferencesSection *advanced = [[WWNPreferencesSection alloc] init];
  advanced.title = @"Advanced";
  advanced.icon = @"gearshape.2";
  advanced.iconColor = [NSColor systemGrayColor];
  advanced.items = @[
    ITEM(@"Color Operations", @"ColorOperations", WSettingSwitch, @NO,
         @"Color profiles and HDR."),
    ITEM(@"Nested Compositors", @"NestedCompositorsSupport", WSettingSwitch,
         @YES, @"Support for nested compositors."),
    ITEM(@"Multiple Clients", @"MultipleClients", WSettingSwitch,
         @YES,
         @"Allow multiple Wayland clients to connect simultaneously."),
    ITEM(@"Enable Muplar Wayland Shell", @"EnableLauncher", WSettingSwitch, @NO,
         @"Start the built-in Wayland Shell."),
    ITEM(@"Enable Weston Simple SHM", @"WestonSimpleSHMEnabled", WSettingSwitch,
         @NO, @"Start weston-simple-shm on launch."),
    ITEM(@"Enable Native Weston", @"WestonEnabled", WSettingSwitch, @NO,
         @"Start Weston natively inside Muplar Wayland."),
    ITEM(@"Enable Weston Terminal", @"WestonTerminalEnabled", WSettingSwitch,
         @NO, @"Start Weston Terminal natively.")
  ];
  [sects addObject:advanced];

  // MACHINES (stubs in v0.2.3)
  WWNPreferencesSection *machines = [[WWNPreferencesSection alloc] init];
  machines.title = @"Machines";
  machines.icon = @"server.rack";
  machines.iconColor = [NSColor systemCyanColor];
  machines.items = @[
    ITEM(@"Virtual Machine Provider", @"MachineVMProviderStub", WSettingText,
         @"utm-se", @"Stub setting for future VM integration."),
    ITEM(@"Virtual Machine VSock Port", @"MachineVMDefaultVsockStub",
         WSettingNumber, @"1024",
         @"Stub default VSock port for future VM launches."),
    ITEM(@"Container Runtime", @"MachineContainerRuntimeStub", WSettingText,
         @"docker", @"Stub setting for future container integration."),
    ITEM(@"Container Namespace", @"MachineContainerNamespaceStub", WSettingText,
         @"default", @"Stub namespace for future container runtime hooks."),
    ITEM(
        @"Status", nil, WSettingInfo, @"Coming Soon",
        @"VM and container entries are persistent stubs in v0.2.3 and "
        @"intentionally non-functional until runtime integration lands.")
  ];
  [sects addObject:machines];

  // WAYPIPE
  WWNPreferencesSection *waypipe = [[WWNPreferencesSection alloc] init];
  waypipe.title = @"Waypipe";
  waypipe.icon = @"arrow.triangle.2.circlepath";
  waypipe.iconColor = [NSColor systemGreenColor];

  __weak typeof(self) weakSelf = self;
  WWNSettingItem *previewBtn =
      ITEM(@"Preview Command", @"WaypipePreview", WSettingButton, nil,
           @"View and copy the generated command.");
  previewBtn.actionBlock = ^{
    [weakSelf previewWaypipeCommand];
  };

  WWNSettingItem *stopBtn =
      ITEM(@"Stop Waypipe", @"WaypipeStop", WSettingButton, nil,
           @"Stop the running waypipe session.");
  stopBtn.actionBlock = ^{
    [[WWNWaypipeRunner sharedRunner] stopWaypipe];
  };

  WWNSettingItem *compressItem =
      ITEM(@"Compression", @"WaypipeCompress", WSettingPopup, @"lz4",
           @"Compression method.");
  compressItem.options = @[ @"none", @"lz4", @"zstd" ];

  WWNSettingItem *videoItem =
      ITEM(@"Video Codec", @"WaypipeVideo", WSettingPopup, @"none",
           @"Lossy video codec.");
  videoItem.options = @[ @"none", @"h264", @"vp9", @"av1" ];

  WWNSettingItem *vEnc = ITEM(@"Encoding", @"WaypipeVideoEncoding",
                              WSettingPopup, @"hw", @"Hardware vs Software.");
  vEnc.options = @[ @"hw", @"sw", @"hwenc", @"swenc" ];

  WWNSettingItem *vDec = ITEM(@"Decoding", @"WaypipeVideoDecoding",
                              WSettingPopup, @"hw", @"Hardware vs Software.");
  vDec.options = @[ @"hw", @"sw", @"hwdec", @"swdec" ];

  waypipe.items = @[
    ITEM(@"Waypipe", nil, WSettingInfo, [self getWaypipeVersion],
         @"Remote Wayland display proxy."),
    ITEM(@"Local IP", nil, WSettingInfo, [self localIPAddress], nil),
    ITEM(@"Display Number", @"WaylandDisplayNumber", WSettingNumber, @0,
         @"Display number for socket and waypipe (e.g., 0 = wayland-0)."),
    compressItem,
    ITEM(@"Comp. Level", @"WaypipeCompressLevel", WSettingNumber, @7,
         @"Zstd level (1-22)."),
    ITEM(@"Threads", @"WaypipeThreads", WSettingNumber, @0, @"0 = auto."),
    videoItem,
    vEnc,
    vDec,
    ITEM(@"Bits Per Frame", @"WaypipeVideoBpf", WSettingNumber, @"",
         @"Target bit rate per frame for video encoding. Recommended range: "
         @"1000-10000 bits per frame. Higher values provide better quality but "
         @"use more bandwidth. Leave empty for automatic bit rate."),
    ITEM(@"Use SSH Config", @"WaypipeUseSSHConfig", WSettingSwitch, @YES,
         @"Use SSH configuration from SSH section."),
    ITEM(@"Remote Command", @"WaypipeRemoteCommand", WSettingText, @"",
         @"Command to run remotely."),
    ITEM(@"Debug Mode", @"WaypipeDebug", WSettingSwitch, @NO,
         @"Print debug logs."),
    ITEM(@"Disable GPU", @"WaypipeNoGpu", WSettingSwitch, @NO,
         @"Block GPU protocols."),
    ITEM(@"One-shot", @"WaypipeOneshot", WSettingSwitch, @NO,
         @"Exit when client disconnects."),
    ITEM(@"Unlink Socket", @"WaypipeUnlinkSocket", WSettingSwitch, @NO,
         @"Unlink socket on exit."),
    ITEM(@"Login Shell", @"WaypipeLoginShell", WSettingSwitch, @NO,
         @"Run in login shell."),
    ITEM(@"VSock", @"WaypipeVsock", WSettingSwitch, @NO, @"Use VSock."),
    ITEM(@"XWayland", @"WaypipeXwls", WSettingSwitch, @NO,
         @"Enable XWayland support."),
    ITEM(
        @"Title Prefix", @"WaypipeTitlePrefix", WSettingText, @"",
        @"Prefix added to window titles. Example: \"Remote:\" will show "
        @"windows as \"Remote: Application Name\". Leave empty for no prefix."),
    ITEM(@"Sec Context", @"WaypipeSecCtx", WSettingText, @"",
         @"SELinux security context for waypipe processes. This is a Linux "
         @"security feature that labels processes with security attributes "
         @"(e.g., \"system_u:system_r:waypipe_t:s0\"). Only needed if SELinux "
         @"is enabled on the remote system. Leave empty to use default "
         @"context."),
    previewBtn,
    stopBtn
  ];
  [sects addObject:waypipe];

  // SSH (libssh2 on iOS, OpenSSH on macOS)
  WWNPreferencesSection *ssh = [[WWNPreferencesSection alloc] init];
  ssh.title = @"OpenSSH";
  ssh.icon = @"lock.shield";
  ssh.iconColor = [NSColor systemBlueColor];

  WWNSettingItem *sshAuthMethodItem =
      ITEM(@"Auth Method", @"SSHAuthMethod", WSettingPopup, @"Password",
           @"Authentication method.");
  sshAuthMethodItem.options = @[ @"Password", @"Public Key" ];

  WWNSettingItem *sshPingBtn =
      ITEM(@"Ping Host", @"SSHPingHost", WSettingButton, nil,
           @"Test network connectivity to SSH host (no authentication).");
  sshPingBtn.actionBlock = ^{
    [weakSelf pingSSHHost];
  };

  WWNSettingItem *sshTestBtn =
      ITEM(@"Test SSH Connection", @"SSHTestConnection", WSettingButton, nil,
           @"Test SSH connection with authentication (password or key).");
  sshTestBtn.actionBlock = ^{
    [weakSelf testSSHConnection];
  };

  // Build items list based on current auth method
  NSMutableArray *sshItems = [NSMutableArray array];

  // Version info
  [sshItems addObject:ITEM(@"SSH Library", nil, WSettingInfo,
                           [self getOpenSSHVersion],
                           @"OpenSSH SSH client used for connections.")];
  [sshItems addObject:ITEM(@"sshpass", nil, WSettingInfo,
                           [self getSshpassVersion],
                           @"Password auth helper for non-interactive SSH.")];

  // Basic connection settings (always shown)
  [sshItems addObject:ITEM(@"SSH Host", @"SSHHost", WSettingText, @"",
                           @"Remote host address.")];
  [sshItems addObject:ITEM(@"SSH User", @"SSHUser", WSettingText, @"",
                           @"SSH username.")];
  [sshItems addObject:sshAuthMethodItem];

  // Get current auth method to show appropriate nested options
  NSInteger authMethod =
      [[NSUserDefaults standardUserDefaults] integerForKey:@"SSHAuthMethod"];

  if (authMethod == 0) {
    // Password authentication
    [sshItems addObject:ITEM(@"Password", @"SSHPassword", WSettingPassword, @"",
                             @"SSH password.")];
  } else {
    // Public Key authentication
    // macOS: Use system SSH - allow key path
    [sshItems
        addObject:ITEM(@"Key Path", @"SSHKeyPath", WSettingText,
                       @"~/.ssh/id_ed25519",
                       @"Path to private key file (e.g., ~/.ssh/id_ed25519).")];
    // Key passphrase (for encrypted keys)
    [sshItems
        addObject:
            ITEM(@"Key Passphrase", @"SSHKeyPassphrase", WSettingPassword, @"",
                 @"Passphrase for encrypted private key (stored securely).")];
  }

  // Action buttons (always shown)
  [sshItems addObject:sshPingBtn];
  [sshItems addObject:sshTestBtn];

  ssh.items = sshItems;
  [sects addObject:ssh];

  // ABOUT
  WWNPreferencesSection *about = [[WWNPreferencesSection alloc] init];
  about.title = @"About";
  about.icon = @"info.circle";
  about.iconColor = [NSColor systemPurpleColor];

  WWNSettingItem *headerItem =
      ITEM(@"muplar-wayland", nil, WSettingHeader, nil,
           @"A Wayland Compositor for macOS, iOS & Android");
  headerItem.imageName = @"Wawona";

  WWNSettingItem *sourceItem =
      ITEM(@"Source Code", nil, WSettingLink, nil, @"View on GitHub");
  sourceItem.urlString = @"https://github.com/aspauldingcode/Wawona";
  sourceItem.iconURL = @"https://github.githubassets.com/images/modules/logos_"
                       @"page/GitHub-Mark.png";

  WWNSettingItem *donateItem =
      ITEM(@"GitHub Sponsors", nil, WSettingLink, nil, @"Sponsor on GitHub");
  donateItem.urlString = @"https://github.com/sponsors/aspauldingcode";
  donateItem.iconURL = @"https://encrypted-tbn0.gstatic.com/images?q=tbn:"
                       @"ANd9GcRp_gdQoe-SxKGw3IvS-1G_JPsMY70HkqxAPg&s";

  WWNSettingItem *authorItem =
      ITEM(@"Author", nil, WSettingInfo, @"Alex Spaulding", nil);
  authorItem.iconURL = @"https://github.com/aspauldingcode.png?size=160";

  WWNSettingItem *githubItem =
      ITEM(@"GitHub", nil, WSettingLink, nil, @"View GitHub Profile");
  githubItem.urlString = @"https://github.com/aspauldingcode";
  githubItem.iconURL = @"https://github.githubassets.com/images/modules/logos_"
                       @"page/GitHub-Mark.png";

  WWNSettingItem *xItem = ITEM(@"X", nil, WSettingLink, nil, @"Follow on X");
  xItem.urlString = @"https://x.com/aspauldingcode";
  xItem.iconURL = @"https://x.com/favicon.ico";

  WWNSettingItem *linkedinItem =
      ITEM(@"LinkedIn", nil, WSettingLink, nil, @"Connect on LinkedIn");
  linkedinItem.urlString = @"https://www.linkedin.com/in/aspauldingcode/";
  linkedinItem.iconURL = @"https://upload.wikimedia.org/wikipedia/commons/c/"
                         @"ca/LinkedIn_logo_initials.png";

  WWNSettingItem *websiteItem =
      ITEM(@"Portfolio", nil, WSettingLink, nil, @"Visit Website");
  websiteItem.urlString = @"https://aspauldingcode.com";
  websiteItem.iconURL = @"https://aspauldingcode.com/favicon.ico";

  WWNSettingItem *kofiItem =
      ITEM(@"Ko-fi", nil, WSettingLink, nil, @"Buy me a coffee ☕");
  kofiItem.urlString = @"https://ko-fi.com/aspauldingcode";
  kofiItem.iconURL = @"https://ko-fi.com/android-icon-192x192.png";

  about.items = @[
    headerItem, ITEM(@"Version", nil, WSettingInfo, [self getWWNVersion], nil),
    ITEM(@"Platform", nil, WSettingInfo,
         @"macOS",
         nil),
    authorItem, websiteItem, githubItem, xItem, linkedinItem, kofiItem,
    donateItem
  ];
  [sects addObject:about];

  // DEPENDENCIES
  WWNPreferencesSection *deps = [[WWNPreferencesSection alloc] init];
  deps.title = @"Dependencies";
  deps.icon = @"shippingbox";
  deps.iconColor = [NSColor systemBrownColor];

  NSMutableArray *depItems = [NSMutableArray array];

  // Core dependencies
  [depItems
      addObject:ITEM(@"Waypipe", nil, WSettingInfo, [self getWaypipeVersion],
                     @"Remote Wayland display proxy")];
  [depItems addObject:ITEM(@"OpenSSH", nil, WSettingInfo,
                           [self getOpenSSHVersion], @"Secure shell client")];
  [depItems
      addObject:ITEM(@"sshpass", nil, WSettingInfo, [self getSshpassVersion],
                     @"Non-interactive SSH password auth")];
  [depItems
      addObject:ITEM(@"libwayland", nil, WSettingInfo,
                     [self getLibwaylandVersion], @"Wayland protocol library")];
  [depItems
      addObject:ITEM(@"xkbcommon", nil, WSettingInfo,
                     [self getXkbcommonVersion], @"Keyboard handling library")];

  // Compression
  [depItems addObject:ITEM(@"LZ4", nil, WSettingInfo, [self getLz4Version],
                           @"Fast compression algorithm")];
  [depItems addObject:ITEM(@"Zstd", nil, WSettingInfo, [self getZstdVersion],
                           @"Zstandard compression")];

  // Other libraries
  [depItems
      addObject:ITEM(@"libffi", nil, WSettingInfo, [self getLibffiVersion],
                     @"Foreign function interface")];


  deps.items = depItems;
  [sects addObject:deps];

  return sects;
}

- (NSString *)findWaypipeBinary {
  return [[WWNWaypipeRunner sharedRunner] findWaypipeBinary];
}

- (NSString *)getSocketPath {
  const char *xdg_runtime_dir = getenv("XDG_RUNTIME_DIR");
  if (xdg_runtime_dir) {
    return [NSString stringWithUTF8String:xdg_runtime_dir];
  }
  // Fallback to /tmp/uid-runtime logic matching core
  uid_t uid = getuid();
  return [NSString stringWithFormat:@"/tmp/%d-runtime", uid];
}

- (NSString *)localIPAddress {
  NSString *address = @"Not available";
  struct ifaddrs *interfaces = NULL;
  struct ifaddrs *temp_addr = NULL;
  int success = 0;

  // Retrieve the current interfaces - returns 0 on success
  success = getifaddrs(&interfaces);
  if (success == 0) {
    // Loop through linked list of interfaces
    temp_addr = interfaces;
    while (temp_addr != NULL) {
      if (temp_addr->ifa_addr->sa_family == AF_INET) {
        // Check if interface is en0 (WiFi) or en1 (Ethernet) or similar
        NSString *ifname = [NSString stringWithUTF8String:temp_addr->ifa_name];
        if ([ifname hasPrefix:@"en"] || [ifname hasPrefix:@"eth"]) {
          // Get NSString from C String
          char *ipCString =
              inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr);
          NSString *ipString = [NSString stringWithUTF8String:ipCString];

          // Skip localhost
          if (![ipString isEqualToString:@"127.0.0.1"]) {
            address = ipString;
            break;
          }
        }
      }
      temp_addr = temp_addr->ifa_next;
    }
  }

  // Free memory
  freeifaddrs(interfaces);
  return address;
}

- (NSString *)cleanVersion:(NSString *)raw {
  if (!raw || raw.length == 0)
    return @"v0.0.0";

  NSMutableString *clean = [NSMutableString stringWithString:@"v"];
  NSCharacterSet *digitsAndDots =
      [NSCharacterSet characterSetWithCharactersInString:@"0123456789."];

  // Find numeric content
  BOOL foundStart = NO;
  for (NSUInteger i = 0; i < raw.length; i++) {
    unichar c = [raw characterAtIndex:i];
    if ([digitsAndDots characterIsMember:c]) {
      [clean appendFormat:@"%C", c];
      foundStart = YES;
    } else if (foundStart) {
      // Stop at first non-numeric char after finding some numbers
      break;
    }
  }

  if (clean.length == 1)
    return @"v0.0.0";
  return clean;
}

- (NSString *)getOpenSSHVersion {
  NSString *sshPath = nil;
  NSFileManager *fm = [NSFileManager defaultManager];

  // macOS: Use system ssh and run ssh -V
  sshPath = @"/usr/bin/ssh";
  if (![fm fileExistsAtPath:sshPath])
    return @"Not found";

  NSTask *task = [[NSTask alloc] init];
  task.launchPath = sshPath;
  task.arguments = @[ @"-V" ];

  NSPipe *pipe = [NSPipe pipe];
  task.standardError = pipe; // ssh -V outputs to stderr

  @try {
    [task launch];
    [task waitUntilExit];

    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    NSString *output =
        [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

    // Parse "OpenSSH_X.Xp2, ..." to just "OpenSSH X.X"
    if ([output hasPrefix:@"OpenSSH_"]) {
      NSRange commaRange = [output rangeOfString:@","];
      if (commaRange.location != NSNotFound) {
        output = [output substringToIndex:commaRange.location];
      }

      // Preserve "OpenSSH" at the start
      NSString *versionPart =
          [output substringFromIndex:8]; // Length of "OpenSSH_"
      versionPart = [versionPart stringByReplacingOccurrencesOfString:@"p"
                                                           withString:@"."];
      versionPart = [versionPart stringByReplacingOccurrencesOfString:@"_"
                                                           withString:@" "];

      NSString *finalVer =
          [versionPart stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
      return [self cleanVersion:finalVer];
    }
    return [self cleanVersion:output];
  } @catch (NSException *e) {
    return @"v0.0.0";
  }
}

- (NSString *)getLibSSH2Version {
  return @"v0.0.0";
}

- (NSString *)getWaypipeVersion {
  NSString *waypipePath = [self findWaypipeBinary];
  if (!waypipePath) {
    NSString *ver = [NSString stringWithUTF8String:WAWONA_WAYPIPE_VERSION];
    return [self cleanVersion:ver];
  }

  NSTask *task = [[NSTask alloc] init];
  task.launchPath = waypipePath;
  task.arguments = @[ @"--version" ];

  NSPipe *pipe = [NSPipe pipe];
  task.standardOutput = pipe;
  task.standardError = pipe;

  @try {
    [task launch];
    [task waitUntilExit];

    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    NSString *output =
        [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

    // Parse "waypipe X.X.X" or similar
    output = [output
        stringByTrimmingCharactersInSet:[NSCharacterSet
                                            whitespaceAndNewlineCharacterSet]];
    if (output.length > 0) {
      // If it contains "waypipe", extract version number
      NSRange waypipeRange =
          [output rangeOfString:@"waypipe" options:NSCaseInsensitiveSearch];
      if (waypipeRange.location != NSNotFound) {
        NSString *afterWaypipe = [output
            substringFromIndex:waypipeRange.location + waypipeRange.length];
        afterWaypipe = [afterWaypipe
            stringByTrimmingCharactersInSet:[NSCharacterSet
                                                whitespaceCharacterSet]];
        // Take first word (version number)
        NSArray *parts = [afterWaypipe
            componentsSeparatedByCharactersInSet:[NSCharacterSet
                                                     whitespaceCharacterSet]];
        if (parts.count > 0 && [parts[0] length] > 0) {
          return [self cleanVersion:parts[0]];
        }
      }
      return output;
    }
    return @"v0.0.0";
  } @catch (NSException *e) {
    return @"v0.0.0";
  }
}

- (NSString *)getSshpassVersion {
  NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
  NSString *execPath = [[NSBundle mainBundle] executablePath];
  NSString *execDir = [execPath stringByDeletingLastPathComponent];
  NSFileManager *fm = [NSFileManager defaultManager];

  NSArray *candidates = @[
    [bundlePath stringByAppendingPathComponent:@"Contents/MacOS/sshpass"],
    [bundlePath
        stringByAppendingPathComponent:@"Contents/Resources/bin/sshpass"],
    [execDir stringByAppendingPathComponent:@"sshpass"]
  ];

  NSString *sshpassPath = nil;
  for (NSString *path in candidates) {
    if ([fm isExecutableFileAtPath:path]) {
      sshpassPath = path;
      break;
    }
  }

  if (!sshpassPath) {
    NSString *ver = [NSString stringWithUTF8String:WAWONA_SSHPASS_VERSION];
    return [self cleanVersion:ver];
  }

  NSTask *task = [[NSTask alloc] init];
  task.launchPath = sshpassPath;
  task.arguments = @[ @"-V" ];

  NSPipe *pipe = [NSPipe pipe];
  task.standardOutput = pipe;
  task.standardError = pipe;

  @try {
    [task launch];
    [task waitUntilExit];

    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    NSString *output =
        [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

    // Parse "sshpass X.X" or similar
    output = [output
        stringByTrimmingCharactersInSet:[NSCharacterSet
                                            whitespaceAndNewlineCharacterSet]];
    if ([output containsString:@"sshpass"]) {
      // Extract version number
      NSRange spaceRange = [output rangeOfString:@" "];
      if (spaceRange.location != NSNotFound) {
        NSString *version = [output substringFromIndex:spaceRange.location + 1];
        version =
            [version stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        // Take first word/line
        NSRange newlineRange = [version
            rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]];
        if (newlineRange.location != NSNotFound) {
          version = [version substringToIndex:newlineRange.location];
        }
        return [self cleanVersion:version];
      }
    }
    return [self cleanVersion:output];
  } @catch (NSException *e) {
    return @"v0.0.0";
  }
}

- (NSString *)getWWNVersion {
  // Use Nix-sourced version if available
  NSString *version = @WAWONA_VERSION;

  // If macro is default or unknown, fall back to bundle info
  if ([version isEqualToString:@"0.0.0-unknown"] ||
      [version containsString:@"unknown"]) {
    version = [[NSBundle mainBundle]
        objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
  }

  // Ensure 'v' prefix
  if (version && ![version hasPrefix:@"v"]) {
    version = [@"v" stringByAppendingString:version];
  }

  return version ?: @"v0.0.0";
}

- (NSString *)getLibffiVersion {
  return
      [self cleanVersion:[NSString stringWithUTF8String:WAWONA_LIBFFI_VERSION]];
}

- (NSString *)getLz4Version {
  return [self cleanVersion:[NSString stringWithUTF8String:WAWONA_LZ4_VERSION]];
}

- (NSString *)getZstdVersion {
  return
      [self cleanVersion:[NSString stringWithUTF8String:WAWONA_ZSTD_VERSION]];
}

- (NSString *)getXkbcommonVersion {
  return [self
      cleanVersion:[NSString stringWithUTF8String:WAWONA_XKBCOMMON_VERSION]];
}

- (NSString *)getLibwaylandVersion {
  return [self
      cleanVersion:[NSString stringWithUTF8String:WAWONA_WAYLAND_VERSION]];
}


- (void)openURL:(NSString *)urlString {
  NSURL *url = [NSURL URLWithString:urlString];
  if (url) {
    [[NSWorkspace sharedWorkspace] openURL:url];
  }
}

- (void)runWaypipe {
  // Save any pending text field changes first (macOS only - iOS uses alerts)
  // On macOS, text fields might have unsaved changes
  // Force end editing to commit any pending changes
  [self.window makeFirstResponder:nil];

  // Initialize status text
  if (!self.waypipeStatusText) {
    self.waypipeStatusText = [NSMutableString string];
  }
  [self.waypipeStatusText setString:@""];
  self.waypipeMarkedConnected = NO;

  WWNWaypipeRunner *runner = [WWNWaypipeRunner sharedRunner];

  // Check if already running
  if (runner.isRunning) {
    [self.waypipeStatusText appendString:@"Waypipe is already running.\n"];
    return;
  }

  // macOS: Show status panel
  [self showWaypipeStatusPanel];

  // Launch waypipe
  WWNLog("UI", @"Launching Waypipe...");
  [[WWNWaypipeRunner sharedRunner]
      launchWaypipe:[WWNPreferencesManager sharedManager]];

  // Note: We do NOT automatically dismiss the settings view here.
  // Waypipe launch might require user interaction (e.g., password prompt)
  // or show errors that the user needs to see.
  // The user can manually dismiss the settings when they are ready.
}

- (void)showWaypipeStatusPanel {
  // Close existing panel if any
  if (self.waypipeStatusPanel) {
    [self.waypipeStatusPanel close];
    self.waypipeStatusPanel = nil;
  }

  // Create a floating panel for waypipe status
  NSRect panelRect = NSMakeRect(0, 0, 500, 350);
  NSPanel *panel = [[NSPanel alloc]
      initWithContentRect:panelRect
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                          NSWindowStyleMaskResizable |
                          NSWindowStyleMaskUtilityWindow
                  backing:NSBackingStoreBuffered
                    defer:NO];
  panel.title = @"Waypipe Status";
  panel.floatingPanel = YES;
  panel.becomesKeyOnlyIfNeeded = YES;
  panel.level = NSFloatingWindowLevel;
  panel.releasedWhenClosed = NO;

  // Create scroll view for text
  NSScrollView *scrollView =
      [[NSScrollView alloc] initWithFrame:NSMakeRect(10, 50, 480, 290)];
  scrollView.hasVerticalScroller = YES;
  scrollView.hasHorizontalScroller = NO;
  scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  scrollView.borderType = NSBezelBorder;

  // Create text view
  NSTextView *textView =
      [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 480, 290)];
  textView.editable = NO;
  textView.selectable = YES;
  textView.font =
      [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
  textView.backgroundColor = [NSColor colorWithCalibratedWhite:0.1 alpha:1.0];
  textView.textColor = [NSColor colorWithCalibratedRed:0.0
                                                 green:1.0
                                                  blue:0.0
                                                 alpha:1.0]; // Terminal green
  textView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [textView.textStorage
      setAttributedString:[[NSAttributedString alloc]
                              initWithString:self.waypipeStatusText
                                  attributes:@{
                                    NSFontAttributeName : textView.font,
                                    NSForegroundColorAttributeName :
                                        textView.textColor
                                  }]];

  scrollView.documentView = textView;
  [panel.contentView addSubview:scrollView];
  self.waypipeStatusTextView = textView;

  // Create buttons at bottom
  NSButton *copyButton = [NSButton buttonWithTitle:@"Copy Log"
                                            target:self
                                            action:@selector(copyWaypipeLog:)];
  copyButton.frame = NSMakeRect(10, 10, 100, 30);
  copyButton.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
  [panel.contentView addSubview:copyButton];

  NSButton *stopButton = [NSButton buttonWithTitle:@"Stop Waypipe"
                                            target:self
                                            action:@selector(stopWaypipe:)];
  stopButton.frame = NSMakeRect(120, 10, 120, 30);
  stopButton.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
  [panel.contentView addSubview:stopButton];
  self.waypipeStopButton = stopButton;

  NSButton *closeButton =
      [NSButton buttonWithTitle:@"Close"
                         target:self
                         action:@selector(closeWaypipePanel:)];
  closeButton.frame = NSMakeRect(390, 10, 100, 30);
  closeButton.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
  [panel.contentView addSubview:closeButton];

  self.waypipeStatusPanel = panel;

  // Position near settings window
  if (self.window) {
    NSRect settingsFrame = self.window.frame;
    NSRect panelFrame = panel.frame;
    panelFrame.origin.x = NSMaxX(settingsFrame) + 20;
    panelFrame.origin.y = NSMinY(settingsFrame);
    [panel setFrame:panelFrame display:YES];
  } else {
    [panel center];
  }

  [panel makeKeyAndOrderFront:nil];
}

- (void)updateWaypipeStatusPanel {
  if (self.waypipeStatusTextView && self.waypipeStatusText) {
    dispatch_async(dispatch_get_main_queue(), ^{
      NSDictionary *attrs = @{
        NSFontAttributeName : self.waypipeStatusTextView.font
            ?: [NSFont monospacedSystemFontOfSize:11
                                           weight:NSFontWeightRegular],
        NSForegroundColorAttributeName : self.waypipeStatusTextView.textColor
            ?: [NSColor greenColor]
      };
      [self.waypipeStatusTextView.textStorage
          setAttributedString:[[NSAttributedString alloc]
                                  initWithString:self.waypipeStatusText
                                      attributes:attrs]];
      // Auto-scroll to bottom
      [self.waypipeStatusTextView
          scrollRangeToVisible:NSMakeRange(self.waypipeStatusText.length, 0)];

      // Update panel title based on connection status
      if (self.waypipeMarkedConnected && self.waypipeStatusPanel) {
        self.waypipeStatusPanel.title = @"Waypipe - Connected";
      }
    });
  }
}

- (void)copyWaypipeLog:(id)sender {
  if (self.waypipeStatusText) {
    [[NSPasteboard generalPasteboard] clearContents];
    [[NSPasteboard generalPasteboard] setString:self.waypipeStatusText
                                        forType:NSPasteboardTypeString];
  }
}

- (void)stopWaypipe:(id)sender {
  [[WWNWaypipeRunner sharedRunner] stopWaypipe];
  [self.waypipeStatusText appendString:@"\n[User requested stop]\n"];
  [self updateWaypipeStatusPanel];
}

- (void)closeWaypipePanel:(id)sender {
  if (self.waypipeStatusPanel) {
    [self.waypipeStatusPanel close];
    self.waypipeStatusPanel = nil;
  }
}

- (void)testSSHConnection {
  WWNPreferencesManager *prefs = [WWNPreferencesManager sharedManager];
  NSString *host = prefs.sshHost;
  NSString *user = prefs.sshUser;

  WWNLog("SSH", @"Attempting to test SSH connection to: '%@%@'",
         user ?: @"(nil)", host ?: @"(nil)");

  if (!host || host.length == 0) {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"No Host Specified";
    alert.informativeText = @"Please enter an SSH host address first.";
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
    return;
  }

  if (!user || user.length == 0) {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"No User Specified";
    alert.informativeText = @"Please enter an SSH username first.";
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
    return;
  }

  // macOS implementation using sshpass (if available) or expect-like pty
  // approach Run the SSH test asynchronously to avoid blocking UI
  dispatch_async(
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        WWNLog("SSH", @"Starting SSH test to %@@%@ (macOS)", user, host);

        NSString *password = prefs.sshPassword;
        BOOL usePasswordAuth =
            (prefs.sshAuthMethod == 0 && password.length > 0);

        // Check if sshpass is available for password auth
        NSString *sshpassPath = nil;
        if (usePasswordAuth) {
          NSFileManager *fm = [NSFileManager defaultManager];
          NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
          NSString *execPath = [[NSBundle mainBundle] executablePath];
          NSString *execDir = [execPath stringByDeletingLastPathComponent];

          WWNLog("SSH", @"Bundle path: %@", bundlePath);
          WWNLog("SSH", @"Executable path: %@", execPath);

          // Check for bundled sshpass first (Nix-built), then fallback to
          // system locations macOS bundle structure:
          // Wawona.app/Contents/MacOS/sshpass or Contents/Resources/bin/sshpass
          // iOS bundle structure: Wawona.app/bin/sshpass
          // Nix store structure: The binary at /nix/store/.../bin/Wawona is a
          // symlink,
          //   actual app bundle is at /nix/store/.../Applications/Wawona.app/
          NSString *nixStoreBase = [[execDir stringByDeletingLastPathComponent]
              stringByDeletingLastPathComponent];
          NSString *nixAppPath =
              [[nixStoreBase stringByAppendingPathComponent:@"Applications"]
                  stringByAppendingPathComponent:@"Wawona.app"];

          NSArray *sshpassPaths = @[
            // Nix: App bundle in same store path as binary symlink
            [[nixAppPath stringByAppendingPathComponent:@"Contents/MacOS"]
                stringByAppendingPathComponent:@"sshpass"],
            [[nixAppPath
                stringByAppendingPathComponent:@"Contents/Resources/bin"]
                stringByAppendingPathComponent:@"sshpass"],
            // Also check parent's parent (for
            // /nix/store/xxx-wawona-macos/bin/Wawona ->
            // ../Applications/Wawona.app)
            [[[[execDir stringByDeletingLastPathComponent]
                stringByAppendingPathComponent:
                    @"Applications/Wawona.app/Contents/MacOS"]
                stringByAppendingPathComponent:@"sshpass"]
                stringByStandardizingPath],
            // macOS: Same directory as executable (Contents/MacOS/)
            [execDir stringByAppendingPathComponent:@"sshpass"],
            // macOS: Resources bin directory
            [[[NSBundle mainBundle] resourcePath]
                stringByAppendingPathComponent:@"bin/sshpass"],
            // macOS: Bundle resource lookup
            [[NSBundle mainBundle] pathForResource:@"sshpass" ofType:nil]
                ?: @"",
            // iOS: Flat app bundle structure
            [bundlePath stringByAppendingPathComponent:@"bin/sshpass"],
            [bundlePath stringByAppendingPathComponent:@"sshpass"],
            // Fallback: relative paths
            [execDir stringByAppendingPathComponent:@"../bin/sshpass"],
            [[execDir stringByDeletingLastPathComponent]
                stringByAppendingPathComponent:@"bin/sshpass"],
            // System locations (Homebrew, etc.)
            @"/opt/homebrew/bin/sshpass", @"/usr/local/bin/sshpass",
            @"/usr/bin/sshpass"
          ];

          WWNLog("SSH", @"Searching for sshpass in %lu paths...",
                 (unsigned long)sshpassPaths.count);
          for (NSString *path in sshpassPaths) {
            if (path.length > 0) {
              BOOL exists = [fm fileExistsAtPath:path];
              BOOL executable = [fm isExecutableFileAtPath:path];
              WWNLog(
                  "SSH",
                  @"[SSH Test macOS]   Checking: %@ (exists=%d, executable=%d)",
                  path, exists, executable);
              if (executable) {
                sshpassPath = path;
                WWNLog("SSH", @"Found sshpass at: %@", sshpassPath);
                break;
              }
            }
          }

          if (!sshpassPath) {
            WWNLog("SSH",
                   @"sshpass not found in any location. Password auth may "
                   @"fail.");
            WWNLog("SSH", @"To install sshpass: brew install "
                          @"hudochenkov/sshpass/sshpass");
          }
        }

        // Build SSH command arguments
        NSMutableArray *sshArgs = [NSMutableArray array];
        NSString *executablePath = @"/usr/bin/ssh";
        NSString *askpassScriptPath = nil;

        if (usePasswordAuth && sshpassPath) {
          // Use sshpass for password authentication
          executablePath = sshpassPath;
          [sshArgs addObject:@"-p"];
          [sshArgs addObject:password];
          [sshArgs addObject:@"ssh"];
          WWNLog("SSH", @"Using sshpass at: %@", sshpassPath);
        }

        [sshArgs addObject:@"-v"]; // Verbose for debugging
        [sshArgs addObject:@"-o"];
        [sshArgs addObject:@"ConnectTimeout=10"];
        [sshArgs addObject:@"-o"];
        [sshArgs addObject:@"StrictHostKeyChecking=no"];
        [sshArgs addObject:@"-o"];
        [sshArgs addObject:@"UserKnownHostsFile=/dev/null"];

        // Only use BatchMode if we're NOT doing password auth
        // Note: sshpass requires password prompts to work, so we cannot use
        // BatchMode with it
        if (!usePasswordAuth) {
          [sshArgs addObject:@"-o"];
          [sshArgs addObject:@"BatchMode=yes"];
        }

        // Add authentication method specific options
        if (prefs.sshAuthMethod == 1) { // Public Key
          [sshArgs addObject:@"-o"];
          [sshArgs addObject:@"PreferredAuthentications=publickey"];
          if (prefs.sshKeyPath.length > 0) {
            [sshArgs addObject:@"-i"];
            [sshArgs addObject:prefs.sshKeyPath];
          }
        } else { // Password auth
          [sshArgs addObject:@"-o"];
          [sshArgs
              addObject:
                  @"PreferredAuthentications=password,keyboard-interactive"];
          [sshArgs addObject:@"-o"];
          [sshArgs addObject:@"PubkeyAuthentication=no"];
          [sshArgs addObject:@"-o"];
          [sshArgs addObject:@"NumberOfPasswordPrompts=1"];
        }

        [sshArgs addObject:@"-4"]; // IPv4 only for faster connection

        NSString *target = [NSString stringWithFormat:@"%@@%@", user, host];
        [sshArgs addObject:target];
        [sshArgs addObject:@"uname -a"];

        WWNLog("SSH", @"Running: %@ %@", executablePath,
               [sshArgs componentsJoinedByString:@" "]);

        NSTask *task = [[NSTask alloc] init];
        task.launchPath = executablePath;
        task.arguments = sshArgs;

        NSMutableDictionary *env =
            [[[NSProcessInfo processInfo] environment] mutableCopy];

        // Password auth fallback when sshpass is unavailable:
        // use SSH_ASKPASS in forced mode so ssh does not require /dev/tty.
        if (usePasswordAuth && !sshpassPath) {
          NSString *scriptName =
              [NSString stringWithFormat:@"muplar-wayland-askpass-%@.sh",
                                         [[NSUUID UUID] UUIDString]];
          askpassScriptPath = [NSTemporaryDirectory()
              stringByAppendingPathComponent:scriptName];
          NSString *script = @"#!/bin/sh\n"
                              "printf '%s\\n' \"$WAWONA_SSH_PASSWORD\"\n";
          NSError *scriptError = nil;
          BOOL wrote = [script writeToFile:askpassScriptPath
                                atomically:YES
                                  encoding:NSUTF8StringEncoding
                                     error:&scriptError];
          if (wrote &&
              chmod([askpassScriptPath fileSystemRepresentation], 0700) == 0) {
            env[@"SSH_ASKPASS"] = askpassScriptPath;
            env[@"SSH_ASKPASS_REQUIRE"] = @"force";
            env[@"DISPLAY"] = env[@"DISPLAY"] ?: @"muplar-wayland-ssh-test";
            env[@"WAWONA_SSH_PASSWORD"] = password ?: @"";
            WWNLog("SSH",
                   @"[SSH Test macOS] Using temporary SSH_ASKPASS helper");
          } else {
            WWNLog("SSH",
                   @"[SSH Test macOS] Failed to create SSH_ASKPASS helper: %@",
                   scriptError.localizedDescription ?: @"unknown error");
            askpassScriptPath = nil;
          }
        }
        task.environment = env;

        NSPipe *outputPipe = [NSPipe pipe];
        NSPipe *errorPipe = [NSPipe pipe];

        task.standardOutput = outputPipe;
        task.standardError = errorPipe;

        NSError *launchError = nil;
        [task launchAndReturnError:&launchError];

        if (launchError) {
          WWNLog("SSH", @"Launch error: %@", launchError);
          if (askpassScriptPath.length > 0) {
            [[NSFileManager defaultManager] removeItemAtPath:askpassScriptPath
                                                       error:nil];
          }
          dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert *errorAlert = [[NSAlert alloc] init];
            errorAlert.messageText = @"SSH Launch Failed";
            errorAlert.informativeText =
                [NSString stringWithFormat:@"Failed to launch SSH: %@",
                                           launchError.localizedDescription];
            [errorAlert addButtonWithTitle:@"OK"];
            [errorAlert runModal];
          });
          return;
        }

        // Wait for task with timeout
        dispatch_semaphore_t taskSemaphore = dispatch_semaphore_create(0);
        dispatch_async(
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
              [task waitUntilExit];
              dispatch_semaphore_signal(taskSemaphore);
            });

        dispatch_time_t taskTimeout =
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC));
        BOOL timedOut =
            (dispatch_semaphore_wait(taskSemaphore, taskTimeout) != 0);

        if (timedOut) {
          [task terminate];
          WWNLog("SSH", @"Timed out after 15 seconds");
          if (askpassScriptPath.length > 0) {
            [[NSFileManager defaultManager] removeItemAtPath:askpassScriptPath
                                                       error:nil];
          }
          dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert *errorAlert = [[NSAlert alloc] init];
            errorAlert.messageText = @"SSH Connection Timeout";
            errorAlert.informativeText =
                @"SSH connection test timed out after 15 seconds.\n\nThis may "
                @"indicate:\n- Network connectivity issues\n- SSH server not "
                @"responding\n- Authentication hanging";
            [errorAlert addButtonWithTitle:@"OK"];
            [errorAlert runModal];
          });
          return;
        }

        int exitCode = task.terminationStatus;
        NSData *outputData =
            [outputPipe.fileHandleForReading readDataToEndOfFile];
        NSData *errorData =
            [errorPipe.fileHandleForReading readDataToEndOfFile];
        NSString *outputString =
            [[NSString alloc] initWithData:outputData
                                  encoding:NSUTF8StringEncoding]
                ?: @"";
        NSString *errorString =
            [[NSString alloc] initWithData:errorData
                                  encoding:NSUTF8StringEncoding]
                ?: @"";

        WWNLog("SSH", @"Exit code: %d", exitCode);
        WWNLog("SSH", @"Output: %@", outputString);
        WWNLog("SSH", @"Stderr: %@", errorString);

        dispatch_async(dispatch_get_main_queue(), ^{
          if (askpassScriptPath.length > 0) {
            [[NSFileManager defaultManager] removeItemAtPath:askpassScriptPath
                                                       error:nil];
          }
          NSAlert *resultAlert = [[NSAlert alloc] init];

          if (exitCode == 0) {
            resultAlert.messageText = @"SSH Connection Successful";
            NSString *unameOutput = [outputString
                stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (unameOutput.length > 0) {
              resultAlert.informativeText = [NSString
                  stringWithFormat:@"Connected to %@@%@\n\nRemote system:\n%@",
                                   user, host, unameOutput];
            } else {
              resultAlert.informativeText = [NSString
                  stringWithFormat:
                      @"Successfully connected and authenticated to %@@%@",
                      user, host];
            }
            resultAlert.alertStyle = NSAlertStyleInformational;
          } else {
            resultAlert.messageText = @"SSH Connection Failed";
            NSMutableString *details = [NSMutableString
                stringWithFormat:@"SSH connection failed (exit code %d).\n\n",
                                 exitCode];

            // Parse common errors
            if ([errorString containsString:@"Permission denied"]) {
              [details appendString:
                           @"Authentication failed. Please check:\n- Username "
                           @"is correct\n- Password/key is correct\n- Auth "
                           @"method matches server config\n"];

              // Add specific note about sshpass for password auth
              if (usePasswordAuth && !sshpassPath) {
                [details appendString:@"\n⚠️ Password auth on macOS requires "
                                      @"'sshpass'.\nInstall via: brew install "
                                      @"hudochenkov/sshpass/sshpass\n"];
              }
            } else if ([errorString containsString:@"Connection refused"]) {
              [details appendString:@"Connection refused. Please check:\n- SSH "
                                    @"server is running on the host\n- Port 22 "
                                    @"is open\n- Firewall settings\n"];
            } else if ([errorString
                           containsString:@"Host key verification failed"]) {
              [details appendString:@"Host key verification failed.\n"];
            } else if ([errorString containsString:@"No route to host"]) {
              [details appendString:@"Network error: No route to host.\n"];
            } else if ([errorString containsString:@"Connection timed out"]) {
              [details appendString:@"Connection timed out.\n"];
            } else {
              // Show last few lines of error
              NSArray *lines = [errorString componentsSeparatedByString:@"\n"];
              if (lines.count > 3) {
                NSArray *lastLines =
                    [lines subarrayWithRange:NSMakeRange(lines.count - 4, 3)];
                [details
                    appendFormat:@"Last output:\n%@",
                                 [lastLines componentsJoinedByString:@"\n"]];
              } else {
                [details appendString:errorString];
              }
            }

            resultAlert.informativeText = details;
            resultAlert.alertStyle = NSAlertStyleWarning;
          }

          [resultAlert addButtonWithTitle:@"OK"]; // First: OK (Right/Default)
          [resultAlert
              addButtonWithTitle:@"Copy Log"]; // Second: Copy Log (Left)

          NSModalResponse response = [resultAlert runModal];
          if (response == NSAlertSecondButtonReturn) {
            // Copy log to clipboard
            NSString *fullLog =
                [NSString stringWithFormat:
                              @"SSH Test Log\n============\nHost: %@@%@\nExit "
                              @"Code: %d\n\nOutput:\n%@\n\nStderr:\n%@",
                              user, host, exitCode, outputString, errorString];
            NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
            [pasteboard clearContents];
            [pasteboard setString:fullLog forType:NSPasteboardTypeString];
          }
        });
      });
}

- (void)pingSSHHost {
  WWNLog("UI", @"Ping SSH Host button pressed");
  WWNPreferencesManager *prefs = [WWNPreferencesManager sharedManager];
  NSString *host = prefs.sshHost;

  WWNLog("SSH", @"Attempting to ping SSH host: '%@'", host ?: @"(nil)");

  if (!host || host.length == 0) {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"No Host Specified";
    alert.informativeText = @"Please enter an SSH host address first.";
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
    return;
  }


  // Use Network framework for ping asynchronously
  nw_endpoint_t endpoint = nw_endpoint_create_host([host UTF8String], "22");
  nw_parameters_t parameters = nw_parameters_create_secure_tcp(
      NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
  nw_connection_t connection = nw_connection_create(endpoint, parameters);

  if (!connection) {
    NSString *errorMessage = @"Failed to create Network.framework connection";
    dispatch_async(dispatch_get_main_queue(), ^{
      NSAlert *resultAlert = [[NSAlert alloc] init];
      resultAlert.messageText = @"Ping Failed";
      resultAlert.informativeText = [NSString
          stringWithFormat:@"Failed to reach %@\n%@", host, errorMessage];
      [resultAlert addButtonWithTitle:@"OK"];
      [resultAlert runModal];
    });
    return;
  }

  dispatch_queue_t connectionQueue = dispatch_queue_create(
      "com.muplar.wayland.sshping", DISPATCH_QUEUE_SERIAL);
  nw_connection_set_queue(connection, connectionQueue);

  __block BOOL completed = NO;
  NSDate *startTime = [NSDate date];

  nw_connection_set_state_changed_handler(connection, ^(
                                              nw_connection_state_t state,
                                              nw_error_t nw_error) {
    if (completed)
      return;

    if (state == nw_connection_state_ready) {
      completed = YES;
      NSTimeInterval latency =
          [[NSDate date] timeIntervalSinceDate:startTime] * 1000;
      nw_connection_cancel(connection);

      dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert *resultAlert = [[NSAlert alloc] init];
            resultAlert.messageText = @"Ping Successful";
            resultAlert.informativeText = [NSString
                stringWithFormat:@"Successfully reached %@\nLatency: %.0f ms",
                                 host, latency];
            [resultAlert addButtonWithTitle:@"OK"];
            [resultAlert runModal];
      });
    } else if (state == nw_connection_state_failed ||
               state == nw_connection_state_cancelled) {
      if (completed)
        return;
      completed = YES;

      NSString *errorMessage = @"Connection failed";
      if (nw_error) {
        int error_code = nw_error_get_error_code(nw_error);
        errorMessage = [NSString stringWithFormat:@"Error %d", error_code];
      }

      dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert *resultAlert = [[NSAlert alloc] init];
            resultAlert.messageText = @"Ping Failed";
            resultAlert.informativeText = [NSString
                stringWithFormat:@"Failed to reach %@\n%@", host, errorMessage];
            [resultAlert addButtonWithTitle:@"OK"];
            [resultAlert runModal];
      });
    }
  });

  nw_connection_start(connection);

  // Timeout
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
      connectionQueue, ^{
        if (!completed) {
          completed = YES;
          nw_connection_cancel(connection);
          dispatch_async(dispatch_get_main_queue(), ^{
                       NSAlert *resultAlert = [[NSAlert alloc] init];
                       resultAlert.messageText = @"Ping Failed";
                       resultAlert.informativeText = [NSString
                           stringWithFormat:@"Connection waiting timeout to %@",
                                            host];
                       [resultAlert addButtonWithTitle:@"OK"];
                       [resultAlert runModal];
          });
        }
      });
}

- (void)pingHost {
  WWNLog("UI", @"Ping Host button pressed");
  WWNPreferencesManager *prefs = [WWNPreferencesManager sharedManager];
  NSString *host = prefs.waypipeSSHHost ?: prefs.sshHost;

  WWNLog("SSH", @"Attempting to ping host: '%@'", host ?: @"(nil)");

  if (!host || host.length == 0) {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"No Host Specified";
    alert.informativeText = @"Please enter an SSH host address first.";
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
    return;
  }


  // Perform ping on background thread using Network.framework
  nw_endpoint_t endpoint = nw_endpoint_create_host([host UTF8String], "22");

  // Explicitly configure for TCP without TLS, and enable local network access
  nw_parameters_t parameters = nw_parameters_create_secure_tcp(
      NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
  nw_parameters_set_include_peer_to_peer(parameters, true);

  nw_connection_t connection = nw_connection_create(endpoint, parameters);

  if (!connection) {
    NSString *errorMessage = @"Failed to create Network.framework connection";
    dispatch_async(dispatch_get_main_queue(), ^{
      NSAlert *resultAlert = [[NSAlert alloc] init];
      resultAlert.messageText = @"Ping Failed";
      resultAlert.informativeText = [NSString
          stringWithFormat:@"Failed to reach %@\n%@", host, errorMessage];
      [resultAlert addButtonWithTitle:@"OK"];
      [resultAlert runModal];
    });
    return;
  }

  dispatch_queue_t connectionQueue = dispatch_queue_create(
      "com.muplar.wayland.ping", DISPATCH_QUEUE_SERIAL);
  nw_connection_set_queue(connection, connectionQueue);

  __block BOOL completed = NO;
  NSDate *startTime = [NSDate date];

  nw_connection_set_state_changed_handler(connection, ^(
                                              nw_connection_state_t state,
                                              nw_error_t nw_error) {
    if (completed)
      return;

    if (state == nw_connection_state_ready) {
      completed = YES;
      NSTimeInterval latency =
          [[NSDate date] timeIntervalSinceDate:startTime] * 1000;
      nw_connection_cancel(connection);

      dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert *resultAlert = [[NSAlert alloc] init];
            resultAlert.messageText = @"Ping Successful";
            resultAlert.informativeText = [NSString
                stringWithFormat:@"Host %@ is reachable.\nLatency: %.0f ms",
                                 host, latency];
            [resultAlert addButtonWithTitle:@"OK"];
            [resultAlert runModal];
      });
    } else if (state == nw_connection_state_failed ||
               state == nw_connection_state_cancelled) {
      if (completed)
        return;
      completed = YES;

      NSString *errorMessage = @"Connection failed";
      if (nw_error) {
        int error_code = nw_error_get_error_code(nw_error);
        errorMessage = [NSString stringWithFormat:@"Error %d", error_code];
      }

      dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert *resultAlert = [[NSAlert alloc] init];
            resultAlert.messageText = @"Ping Failed";
            resultAlert.informativeText =
                [NSString stringWithFormat:@"Could not reach %@.\n%@", host,
                                           errorMessage];
            [resultAlert addButtonWithTitle:@"OK"];
            [resultAlert runModal];
      });
    }
  });

  nw_connection_start(connection);

  // Timeout
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
      connectionQueue, ^{
        if (!completed) {
          completed = YES;
          nw_connection_cancel(connection);
          dispatch_async(dispatch_get_main_queue(), ^{
                       NSAlert *resultAlert = [[NSAlert alloc] init];
                       resultAlert.messageText = @"Ping Failed";
                       resultAlert.informativeText = [NSString
                           stringWithFormat:
                               @"Connection waiting timeout after 10 seconds to %@",
                               host];
                       [resultAlert addButtonWithTitle:@"OK"];
                       [resultAlert runModal];
          });
        }
      });
}

#pragma mark - WWNWaypipeRunnerDelegate

- (void)runnerDidReceiveSSHPasswordPrompt:(NSString *)prompt {
  dispatch_async(dispatch_get_main_queue(), ^{
    WWNLog("SSH", @"SSH password prompt: %@", prompt);
  // macOS: Use NSAlert with secure text field and eyeball toggle
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"SSH Password Required";
  alert.informativeText = prompt ? prompt : @"Enter your SSH password:";
  [alert addButtonWithTitle:@"Save & Connect"];
  [alert addButtonWithTitle:@"Cancel"];
  alert.alertStyle = NSAlertStyleInformational;

  // Create container view with password field and toggle button
  NSView *containerView =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];

  // Create secure text field (hidden by default)
  NSSecureTextField *secureField =
      [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 250, 24)];
  secureField.placeholderString = @"Enter a Password...";
  secureField.stringValue = @"";
  [containerView addSubview:secureField];

  // Create plain text field (for showing password)
  NSTextField *plainField =
      [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 250, 24)];
  plainField.placeholderString = @"Enter a Password...";
  plainField.stringValue = @"";
  plainField.hidden = YES;
  [containerView addSubview:plainField];

  // Create eyeball toggle button
  NSButton *toggleButton =
      [[NSButton alloc] initWithFrame:NSMakeRect(255, 2, 20, 20)];
  toggleButton.bezelStyle = NSBezelStyleInline;
  toggleButton.bordered = NO;
  toggleButton.image = [NSImage imageWithSystemSymbolName:@"eye"
                                 accessibilityDescription:@"Show password"];

  // Store references for toggle action
  objc_setAssociatedObject(toggleButton, "secureField", secureField,
                           OBJC_ASSOCIATION_RETAIN);
  objc_setAssociatedObject(toggleButton, "plainField", plainField,
                           OBJC_ASSOCIATION_RETAIN);
  objc_setAssociatedObject(toggleButton, "isSecure", @YES,
                           OBJC_ASSOCIATION_RETAIN);

  toggleButton.target = self;
  toggleButton.action = @selector(toggleMacOSPasswordVisibility:);

  [containerView addSubview:toggleButton];

  alert.accessoryView = containerView;

  NSModalResponse response = [alert runModal];
  if (response == NSAlertFirstButtonReturn) {
      // Logic for saving password on macOS
      NSString *password = nil;
      NSNumber *isSecure = objc_getAssociatedObject(toggleButton, "isSecure");
      if ([isSecure boolValue]) {
          password = secureField.stringValue;
      } else {
          password = plainField.stringValue;
      }
      
      if (password.length > 0) {
          WWNPreferencesManager *prefs = [WWNPreferencesManager sharedManager];
          prefs.waypipeSSHPassword = password;
           dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                       (int64_t)(0.1 * NSEC_PER_SEC)),
                         dispatch_get_main_queue(), ^{
                           [self runWaypipe];
                         });
      }
  }
  });
}

// Action for toggling password visibility in macOS dialog
- (void)toggleMacOSPasswordVisibility:(NSButton *)sender {
  NSSecureTextField *secureField =
      objc_getAssociatedObject(sender, "secureField");
  NSTextField *plainField = objc_getAssociatedObject(sender, "plainField");
  NSNumber *isSecureNum = objc_getAssociatedObject(sender, "isSecure");
  BOOL isSecure = isSecureNum ? isSecureNum.boolValue : YES;

  if (isSecure) {
    plainField.stringValue = secureField.stringValue;
    secureField.hidden = YES;
    plainField.hidden = NO;
    sender.image = [NSImage imageWithSystemSymbolName:@"eye.slash"
                             accessibilityDescription:@"Hide password"];
    objc_setAssociatedObject(sender, "isSecure", @NO, OBJC_ASSOCIATION_RETAIN);
  } else {
    secureField.stringValue = plainField.stringValue;
    plainField.hidden = YES;
    secureField.hidden = NO;
    sender.image = [NSImage imageWithSystemSymbolName:@"eye"
                             accessibilityDescription:@"Show password"];
    objc_setAssociatedObject(sender, "isSecure", @YES, OBJC_ASSOCIATION_RETAIN);
  }
}

- (void)runnerDidReceiveSSHError:(NSString *)error {
  // Log error to status text
  NSString *errorLine =
      [NSString stringWithFormat:@"\n[SSH ERROR] %@\n", error];
  [self.waypipeStatusText appendString:errorLine];

  dispatch_async(dispatch_get_main_queue(), ^{
    // Update status panel with error
    if (self.waypipeStatusPanel) {
      self.waypipeStatusPanel.title = @"Waypipe - Error";
    }
    [self updateWaypipeStatusPanel];

    // Also show an alert
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"SSH/Waypipe Error";
    alert.informativeText = error;
    alert.alertStyle = NSAlertStyleCritical;
    [alert addButtonWithTitle:@"Copy Error"];
    [alert addButtonWithTitle:@"OK"];

    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) {
      [[NSPasteboard generalPasteboard] clearContents];
      [[NSPasteboard generalPasteboard] setString:error
                                          forType:NSPasteboardTypeString];
    }
  });
}

- (void)runnerDidFinishWithExitCode:(int)exitCode {
  NSString *line =
      [NSString stringWithFormat:@"\n[Exited with code %d]\n", exitCode];
  [self.waypipeStatusText appendString:line];

  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.waypipeStatusPanel) {
      NSString *title =
          exitCode == 0 ? @"Waypipe - Exited" : @"Waypipe - Error";
      self.waypipeStatusPanel.title = title;
    }
    [self updateWaypipeStatusPanel];
  });
}

- (void)runnerDidReceiveOutput:(NSString *)output isError:(BOOL)isError {
  if (!output || output.length == 0)
    return;

  dispatch_async(dispatch_get_main_queue(), ^{
    if (!self.waypipeStatusText) {
      self.waypipeStatusText = [NSMutableString string];
    }

    // Prefix errors for clarity in the log
    NSString *formattedOutput =
        isError ? [NSString stringWithFormat:@"[stderr] %@", output] : output;
    [self.waypipeStatusText appendString:formattedOutput];

    // Limit log size
    NSUInteger maxLen = 50000;
    if (self.waypipeStatusText.length > maxLen) {
      [self.waypipeStatusText
          deleteCharactersInRange:NSMakeRange(0, self.waypipeStatusText.length -
                                                     maxLen)];
    }

    // Update text view if visible
    if (self.waypipeStatusTextView) {
      [self.waypipeStatusTextView.textStorage.mutableString
          setString:self.waypipeStatusText];
      [self.waypipeStatusTextView
          scrollRangeToVisible:NSMakeRange(self.waypipeStatusText.length, 0)];
    }

    // Re-use existing checks for connection success
    [self checkWaypipeSuccessIndicators:output];
  });
}

- (void)checkWaypipeSuccessIndicators:(NSString *)s {
  if (!self.waypipeMarkedConnected) {
    if ([s containsString:@"Authenticated to"] ||
        [s containsString:@"Entering interactive session"] ||
        [s containsString:@"Entering session"] ||
        [s containsString:@"debug1: Authentication succeeded"] ||
        [s containsString:@"Connection established"] ||
        [s containsString:@"Authenticated successfully"] ||
        [s containsString:@"SSH tunnel established"] ||
        [s containsString:@"pump threads started"]) {
      self.waypipeMarkedConnected = YES;
      if (self.waypipeStatusPanel) {
        self.waypipeStatusPanel.title = @"Waypipe - Connected";
      }
    }
  }
}

- (void)runnerDidReadData:(NSData *)data {
  if (!data || data.length == 0) {
    return;
  }
  NSString *s =
      [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (!s) {
    s = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
  }
  [self runnerDidReceiveOutput:s isError:NO];
}


// MARK: - macOS Interface

- (void)showPreferences:(id)sender {
  if (self.winController) {
    [self.winController.window makeKeyAndOrderFront:sender];
    return;
  }

  NSWindow *win = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(0, 0, 700, 500)
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                          NSWindowStyleMaskResizable |
                          NSWindowStyleMaskFullSizeContentView
                  backing:NSBackingStoreBuffered
                    defer:NO];
  win.title = @"Muplar Wayland Settings";
  win.movableByWindowBackground = YES;

  // Add Toolbar (Liquid Glass Style)
  NSToolbar *toolbar =
      [[NSToolbar alloc] initWithIdentifier:@"WWNPreferencesToolbar"];
  toolbar.delegate = self;
  toolbar.displayMode = NSToolbarDisplayModeIconOnly;
  win.toolbar = toolbar;

  // Use the glass content view we just configured
  NSView *v = win.contentView;

  self.sidebar = [[WWNPreferencesSidebar alloc] init];
  self.sidebar.parent = self;
  self.content = [[WWNPreferencesContent alloc] init];

  self.splitVC = [[NSSplitViewController alloc] init];
  NSSplitViewItem *sItem =
      [NSSplitViewItem sidebarWithViewController:self.sidebar];
  sItem.minimumThickness = 160; // Ensure enough width for "Connection" text
  sItem.maximumThickness = 220;
  NSSplitViewItem *cItem =
      [NSSplitViewItem contentListWithViewController:self.content];
  [self.splitVC addSplitViewItem:sItem];
  [self.splitVC addSplitViewItem:cItem];

  // Embed SplitVC in Visual Effect View
  self.splitVC.view.frame = v.bounds;
  self.splitVC.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [v addSubview:self.splitVC.view];

  self.winController = [[NSWindowController alloc] initWithWindow:win];
  [win center];
  [win makeKeyAndOrderFront:sender];

  if (self.sections.count > 0) {
    [self.sidebar.outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                          byExtendingSelection:NO];
  }
}

- (void)showSection:(NSInteger)idx {
  self.content.section = self.sections[idx];
  [self.content.tableView reloadData];
}

- (void)selectSectionWithTitle:(NSString *)title {
  if (title.length == 0) {
    return;
  }
  NSUInteger idx = [self.sections
      indexOfObjectPassingTest:^BOOL(WWNPreferencesSection *_Nonnull section,
                                     NSUInteger i, BOOL *_Nonnull stop) {
        (void)i;
        (void)stop;
        return [section.title caseInsensitiveCompare:title] == NSOrderedSame;
      }];
  if (idx == NSNotFound) {
    return;
  }

  [self showSection:(NSInteger)idx];
  if (self.sidebar.outlineView) {
    [self.sidebar.outlineView
        selectRowIndexes:[NSIndexSet indexSetWithIndex:idx]
      byExtendingSelection:NO];
  }
}

- (void)openMachinesConfiguration:(id)sender {
  (void)sender;
  [[WWNMachinesCoordinator sharedCoordinator] showMachinesWindowAndActivate:YES];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:
    (NSToolbar *)toolbar {
  return @[
    @"com.apple.NSToolbar.toggleSidebar", NSToolbarFlexibleSpaceItemIdentifier
  ];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:
    (NSToolbar *)toolbar {
  return @[ @"com.apple.NSToolbar.toggleSidebar" ];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar
        itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier
    willBeInsertedIntoToolbar:(BOOL)flag {
  if ([itemIdentifier isEqualToString:@"com.apple.NSToolbar.toggleSidebar"]) {
    NSToolbarItem *item =
        [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
    item.label = @"Toggle Sidebar";
    item.paletteLabel = @"Toggle Sidebar";
    item.toolTip = @"Toggle Sidebar";
    item.image = [NSImage imageWithSystemSymbolName:@"sidebar.left"
                           accessibilityDescription:nil];
    item.target = nil; // First Responder
    item.action = @selector(toggleSidebar:);
    return item;
  }
  return nil;
}

- (void)toggleSidebar:(id)sender {
  [NSApp sendAction:@selector(toggleSidebar:) to:nil from:sender];
}



- (void)previewWaypipeCommand {
  id runner = [WWNWaypipeRunner sharedRunner];
  WWNLog("SSH", @"previewWaypipeCommand: runner=%@, class=%@", runner,
         [runner class]);
  NSString *cmdString = [runner
      generateWaypipePreviewString:[WWNPreferencesManager sharedManager]];

#if TARGET_OS_OSX
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Waypipe Command Preview";
  alert.informativeText = cmdString;
  [alert addButtonWithTitle:@"OK"];       // First button: FirstButtonReturn
                                          // (Default/Right)
  [alert addButtonWithTitle:@"Copy Log"]; // Second button: SecondButtonReturn
                                          // (Left)
  NSModalResponse response = [alert runModal];

  if (response == NSAlertSecondButtonReturn) {
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard setString:cmdString forType:NSPasteboardTypeString];
  }
#else
  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:@"Waypipe Command Preview"
                                          message:cmdString
                                   preferredStyle:UIAlertControllerStyleAlert];

  [alert addAction:[UIAlertAction
                       actionWithTitle:@"Copy"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 if ([UIApplication sharedApplication]
                                         .applicationState ==
                                     UIApplicationStateActive) {
                                   [UIPasteboard generalPasteboard].string =
                                       cmdString;
                                 }
                               }]];

  [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
#endif
}

@end

// MARK: - Helper Implementations


@implementation WWNPreferencesSidebar
- (void)loadView {
  NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 400)];
  self.view = v;
  NSScrollView *sv = [[NSScrollView alloc] initWithFrame:v.bounds];
  sv.drawsBackground = NO;
  sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  self.outlineView = [[NSOutlineView alloc] initWithFrame:sv.bounds];
  self.outlineView.dataSource = self;
  self.outlineView.delegate = self;
  self.outlineView.headerView = nil;
  self.outlineView.rowHeight = 24.0; // Standard sidebar height
  NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"M"];
  col.width = 180;    // Ensure column is wide enough for sidebar text
  col.minWidth = 100; // Minimum width to prevent text wrapping
  col.resizingMask = NSTableColumnAutoresizingMask; // Auto-resize with sidebar
  [self.outlineView addTableColumn:col];
  self.outlineView.outlineTableColumn = col;
  self.outlineView.autoresizesOutlineColumn = YES; // Auto-size outline column
  sv.documentView = self.outlineView;
  sv.hasHorizontalScroller = NO; // No horizontal scroll in sidebar
  [v addSubview:sv];
}
- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(id)item {
  return item ? 0 : self.parent.sections.count;
}
- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item {
  return NO;
}
- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)idx ofItem:(id)item {
  return self.parent.sections[idx];
}
- (NSView *)outlineView:(NSOutlineView *)ov
     viewForTableColumn:(NSTableColumn *)tc
                   item:(id)item {
  WWNPreferencesSection *s = item;
  NSTableCellView *cell = [ov makeViewWithIdentifier:@"Cell" owner:self];
  if (!cell) {
    cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 100, 28)];
    cell.identifier = @"Cell";

    NSImageView *iv = [[NSImageView alloc] initWithFrame:NSZeroRect];
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    [cell addSubview:iv];
    cell.imageView = iv;

    NSTextField *tf = [[NSTextField alloc] initWithFrame:NSZeroRect];
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    tf.bordered = NO;
    tf.drawsBackground = NO;
    tf.editable = NO;
    tf.maximumNumberOfLines = 1; // Single line only - no wrapping
    tf.lineBreakMode =
        NSLineBreakByTruncatingTail; // Truncate with ellipsis if needed
    tf.cell.truncatesLastVisibleLine = YES;
    [tf setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                 forOrientation:
                                     NSLayoutConstraintOrientationHorizontal]; // Allow truncation if needed
    [cell addSubview:tf];
    cell.textField = tf;

    [NSLayoutConstraint activateConstraints:@[
      [iv.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:5],
      [iv.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
      [iv.widthAnchor constraintEqualToConstant:20],
      [iv.heightAnchor constraintEqualToConstant:20],

      [tf.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:5],
      [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor
                                        constant:-5],
      [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]
    ]];
  }
  cell.imageView.image =
      [NSImage imageWithSystemSymbolName:s.icon accessibilityDescription:nil];
  cell.imageView.contentTintColor = s.iconColor;
  cell.textField.stringValue = s.title;
  return cell;
}
- (void)outlineViewSelectionDidChange:(NSNotification *)n {
  NSInteger row = self.outlineView.selectedRow;
  if (row >= 0)
    [self.parent showSection:row];
}
@end

// MARK: - WWNPreferenceCell
// A robust, statically laid-out cell to prevent visual corruption and reduce
// LOC.
@interface WWNPreferenceCell : NSTableCellView <NSTextFieldDelegate>
@property(nonatomic, strong) NSTextField *titleLabel;
@property(nonatomic, strong) NSTextField *descLabel;
@property(nonatomic, strong) NSSwitch *switchControl;
@property(nonatomic, strong) NSTextField *textControl;
@property(nonatomic, strong) NSButton *buttonControl;
@property(nonatomic, strong) NSPopUpButton *popupControl;
@property(nonatomic, strong) NSImageView *iconView; // For link icons
@property(nonatomic, strong)
    NSImageView *headerImageView; // For large logos/avatars
@property(nonatomic, strong)
    NSLayoutConstraint *leadingConstraint; // New: for layout
@property(nonatomic, strong) NSLayoutConstraint *trailingConstraint;
@property(nonatomic, strong) WWNSettingItem *item;
@property(nonatomic, assign) id delegate; // MRC: use assign for delegates
- (void)configureWithItem:(WWNSettingItem *)item
                   target:(id)target
                   action:(SEL)action;
@end

@implementation WWNPreferenceCell
- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.identifier = @"PCell";

    _titleLabel = [NSTextField labelWithString:@""];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [NSFont systemFontOfSize:13];
    _titleLabel.textColor = [NSColor labelColor];
    _titleLabel.maximumNumberOfLines = 1;
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _titleLabel.cell.truncatesLastVisibleLine = YES;
    [_titleLabel
        setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                 forOrientation:
                                     NSLayoutConstraintOrientationVertical];
    [_titleLabel
        setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh
                                 forOrientation:
                                     NSLayoutConstraintOrientationHorizontal];
    [self addSubview:_titleLabel];

    _descLabel = [NSTextField labelWithString:@""];
    _descLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _descLabel.font = [NSFont systemFontOfSize:11];
    _descLabel.textColor = [NSColor secondaryLabelColor];
    _descLabel.maximumNumberOfLines = 1;
    _descLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _descLabel.cell.truncatesLastVisibleLine = YES;
    [_descLabel
        setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                 forOrientation:
                                     NSLayoutConstraintOrientationVertical];
    [_descLabel
        setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh
                                 forOrientation:
                                     NSLayoutConstraintOrientationHorizontal];
    [self addSubview:_descLabel];

    // Initialize all potential controls hidden
    _switchControl = [[NSSwitch alloc] init];
    _switchControl.translatesAutoresizingMaskIntoConstraints = NO;
    _switchControl.hidden = YES;
    [self addSubview:_switchControl];

    // Text Field (standard AppKit)
    _textControl = [[NSTextField alloc] init];
    _textControl.placeholderString = @"";
    _textControl.delegate = self; // Cell handles own delegate events
    _textControl.translatesAutoresizingMaskIntoConstraints = NO;
    _textControl.hidden = YES;
    [self addSubview:_textControl];

    // Button (standard AppKit)
    _buttonControl = [[NSButton alloc] init];
    _buttonControl.title = @"Run";
    _buttonControl.bezelStyle = NSBezelStyleRounded;
    _buttonControl.translatesAutoresizingMaskIntoConstraints = NO;
    _buttonControl.hidden = YES;
    [self addSubview:_buttonControl];

    _popupControl =
        [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _popupControl.translatesAutoresizingMaskIntoConstraints = NO;
    _popupControl.hidden = YES;
    [self addSubview:_popupControl];

    _iconView = [[NSImageView alloc] init];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.hidden = YES;
    _iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    [self addSubview:_iconView];

    _headerImageView = [[NSImageView alloc] init];
    _headerImageView.translatesAutoresizingMaskIntoConstraints = NO;
    _headerImageView.hidden = YES;
    _headerImageView.wantsLayer = YES;
    _headerImageView.layer.masksToBounds = YES;
    _headerImageView.layer.cornerRadius = 0.0;
    _headerImageView.layer.contentsGravity = kCAGravityResizeAspect;
    [self addSubview:_headerImageView];

    // Static Auto Layout - Two column design:
    // Left column (labels): leading to ~55% of width
    // Right column (controls): ~45% of width, right-aligned
    CGFloat controlAreaWidth = 160; // Fixed width for control area
    CGFloat spacing = 16;           // Space between labels and controls

    [NSLayoutConstraint activateConstraints:@[
      // Title label - left column
      (_leadingConstraint =
           [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                                     constant:20]),
      [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
      (_trailingConstraint = [_titleLabel.trailingAnchor
           constraintLessThanOrEqualToAnchor:self.trailingAnchor
                                    constant:-(controlAreaWidth + spacing +
                                               20)]),

      // Description label - below title, same width constraints
      [_descLabel.leadingAnchor
          constraintEqualToAnchor:_titleLabel.leadingAnchor],
      [_descLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor
                                           constant:2],
      [_descLabel.trailingAnchor
          constraintEqualToAnchor:_titleLabel.trailingAnchor],

      // Switch control - right column
      [_switchControl.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                    constant:-20],
      [_switchControl.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],

      // Text control - right column with fixed width
      [_textControl.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                  constant:-20],
      [_textControl.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [_textControl.widthAnchor constraintEqualToConstant:controlAreaWidth],

      // Button control - right column
      [_buttonControl.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                    constant:-20],
      [_buttonControl.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [_buttonControl.widthAnchor constraintGreaterThanOrEqualToConstant:80],

      // Popup control - right column with fixed width
      [_popupControl.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                   constant:-20],
      [_popupControl.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [_popupControl.widthAnchor constraintEqualToConstant:controlAreaWidth],

      // Icon view (for links, etc.)
      [_iconView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                              constant:20],
      [_iconView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [_iconView.widthAnchor constraintEqualToConstant:24],
      [_iconView.heightAnchor constraintEqualToConstant:24],

      // Header image view
      [_headerImageView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                                     constant:20],
      [_headerImageView.centerYAnchor
          constraintEqualToAnchor:self.centerYAnchor],
      [_headerImageView.widthAnchor constraintEqualToConstant:48],
      [_headerImageView.heightAnchor constraintEqualToConstant:48],
    ]];
  }
  return self;
}

- (void)configureWithItem:(WWNSettingItem *)item
                   target:(id)target
                   action:(SEL)action {
  self.item = item;
  self.delegate = target; // Store controller as delegate
  self.titleLabel.stringValue = item.title ?: @"";
  self.descLabel.stringValue = item.desc ?: @"";

  // Reset Visibility
  self.switchControl.hidden = YES;
  self.textControl.hidden = YES;
  self.buttonControl.hidden = YES;
  self.popupControl.hidden = YES;
  self.headerImageView.hidden = YES;
  self.headerImageView.image = nil;
  self.iconView.image = nil; // Reset to avoid reuse flickering

  NSControl *active = nil;

  // Base leading constraint
  self.leadingConstraint.constant = 20;

  // Icon logic
  if (item.iconURL) {
    self.iconView.hidden = NO;
    [[WWNImageLoader sharedLoader] loadImageFromURL:item.iconURL
                                         completion:^(WImage _Nullable image) {
                                           if (image) {
                                             self.iconView.image = image;
                                           }
                                         }];
    self.leadingConstraint.constant = 48; // Space for 24x24 icon + margin
  } else {
    self.iconView.hidden = YES;
  }

  if (item.type == WSettingSwitch) {
    self.switchControl.hidden = NO;
    self.switchControl.state =
        [[NSUserDefaults standardUserDefaults] boolForKey:item.key]
            ? NSControlStateValueOn
            : NSControlStateValueOff;
    self.switchControl.target = target;
    self.switchControl.action = action;
    active = self.switchControl;
  } else if (item.type == WSettingText || item.type == WSettingNumber) {
    self.textControl.hidden = NO;
    NSString *val =
        [[NSUserDefaults standardUserDefaults] stringForKey:item.key];
    self.textControl.stringValue =
        val ? val : ([item.defaultValue description] ?: @"");
    self.textControl.target = target;
    self.textControl.action = action;

    // Configure as editable text field
    self.textControl.editable = YES;
    self.textControl.selectable = YES;
    self.textControl.bezeled = YES;
    self.textControl.bezelStyle = NSTextFieldRoundedBezel;
    self.textControl.bordered = NO;
    self.textControl.drawsBackground =
        YES; // Needs background for rounded bezel
    self.textControl.backgroundColor = [NSColor controlBackgroundColor];

    // Set placeholder text for empty fields
    if ([item.key isEqualToString:@"WaypipeRemoteCommand"]) {
      self.textControl.placeholderString = @"e.g. weston-terminal";
    } else if ([item.key containsString:@"Host"]) {
      self.textControl.placeholderString = @"Remote host address";
    } else if ([item.key containsString:@"User"]) {
      self.textControl.placeholderString = @"SSH username";
    } else if ([item.key containsString:@"Path"]) {
      self.textControl.placeholderString = @"Enter path...";
    } else {
      self.textControl.placeholderString = nil;
    }

    // Use middle truncation for path-like fields (like Socket Directory)
    if ([item.key isEqualToString:@"WaylandSocketDir"] ||
        [item.key containsString:@"Dir"] || [item.key containsString:@"Path"]) {
      self.textControl.lineBreakMode = NSLineBreakByTruncatingMiddle;
      self.textControl.cell.truncatesLastVisibleLine = YES;
    } else {
      self.textControl.lineBreakMode = NSLineBreakByTruncatingTail;
    }

    active = self.textControl;
  } else if (item.type == WSettingPassword) {
    // For password fields, show a button that opens a password entry dialog
    self.buttonControl.hidden = NO;
    // For password fields, get stored value to show status
    WWNPreferencesManager *prefs = [WWNPreferencesManager sharedManager];
    NSString *password = nil;
    if ([item.key isEqualToString:@"WaypipeSSHPassword"] ||
        [item.key isEqualToString:@"SSHPassword"]) {
      password = prefs.waypipeSSHPassword ?: prefs.sshPassword;
    } else if ([item.key isEqualToString:@"WaypipeSSHKeyPassphrase"] ||
               [item.key isEqualToString:@"SSHKeyPassphrase"]) {
      password = prefs.waypipeSSHKeyPassphrase ?: prefs.sshKeyPassphrase;
    }
    // Show button text based on whether password exists
    if (password && password.length > 0) {
      self.buttonControl.title = @"Change";
    } else {
      self.buttonControl.title = @"Set";
    }
    self.buttonControl.target = target;
    self.buttonControl.action = action;
    active = self.buttonControl;
  } else if (item.type == WSettingButton) {
    self.buttonControl.hidden = NO;
    self.buttonControl.target = target;
    self.buttonControl.action = action;
    active = self.buttonControl;
  } else if (item.type == WSettingPopup) {
    self.popupControl.hidden = NO;
    [self.popupControl removeAllItems];
    [self.popupControl addItemsWithTitles:item.options];

    // Handle SSHAuthMethod specially - stored as integer index
    if ([item.key isEqualToString:@"SSHAuthMethod"] ||
        [item.key isEqualToString:@"WaypipeSSHAuthMethod"]) {
      NSInteger methodIndex =
          [[NSUserDefaults standardUserDefaults] integerForKey:item.key];
      if (methodIndex >= 0 && methodIndex < (NSInteger)item.options.count) {
        [self.popupControl selectItemAtIndex:methodIndex];
      } else {
        [self.popupControl selectItemAtIndex:0]; // Default to Password
      }
    } else {
      NSString *val =
          [[NSUserDefaults standardUserDefaults] stringForKey:item.key];
      NSString *stored = val ? val : [item.defaultValue description];
      if (item.optionValues && item.optionValues.count == item.options.count) {
        for (NSInteger i = 0; i < (NSInteger)item.optionValues.count; i++) {
          if ([item.optionValues[i] isEqualToString:stored]) {
            [self.popupControl selectItemAtIndex:i];
            goto popup_sel_done;
          }
        }
      }
      [self.popupControl selectItemWithTitle:stored];
    }
  popup_sel_done:
    self.popupControl.target = target;
    self.popupControl.action = action;
    active = self.popupControl;
  } else if (item.type == WSettingInfo) {
    // Info type: show read-only text with copy button
    self.textControl.hidden = NO;
    NSString *val =
        [[NSUserDefaults standardUserDefaults] stringForKey:item.key];
    self.textControl.stringValue =
        val ? val : ([item.defaultValue description] ?: @"");
    self.textControl.editable = NO;
    self.textControl.selectable = YES;
    self.textControl.bezeled = NO;
    self.textControl.bordered = NO;
    self.textControl.backgroundColor = [NSColor clearColor];
    self.textControl.drawsBackground = NO;

    // Use middle truncation for path-like fields (Finder-style truncation)
    if ([item.key isEqualToString:@"WaylandSocketDir"] ||
        [item.key containsString:@"Dir"] || [item.key containsString:@"Path"]) {
      self.textControl.lineBreakMode = NSLineBreakByTruncatingMiddle;
    } else {
      self.textControl.lineBreakMode = NSLineBreakByTruncatingTail;
    }
    active = self.textControl;
  } else if (item.type == WSettingLink) {
    // Show a small icon and description for the link
    self.titleLabel.textColor = [NSColor linkColor];
    self.buttonControl.hidden = NO;
    self.buttonControl.title = item.desc ?: @"Open";
    self.buttonControl.target = target;
    self.buttonControl.action = action;
    active = self.buttonControl;
  } else if (item.type == WSettingHeader) {
    // Header type: icon on the left, title + subtitle to the right
    self.titleLabel.font = [NSFont boldSystemFontOfSize:16];
    self.titleLabel.alignment = NSTextAlignmentLeft;
    self.descLabel.stringValue = item.desc ?: @"";
    self.descLabel.textColor = [NSColor secondaryLabelColor];

    if (item.imageURL || item.imageName) {
      self.headerImageView.hidden = NO;

      // Prefer the dark variant for the Settings > About header image.
      NSImage *icon = [NSImage imageNamed:@"Wawona-iOS-Dark-1024x1024@1x.png"];
      if (!icon) {
        NSString *darkPath = [[NSBundle mainBundle]
            pathForResource:@"Wawona-iOS-Dark-1024x1024@1x"
                     ofType:@"png"];
        if (darkPath) {
          icon = [[NSImage alloc] initWithContentsOfFile:darkPath];
        }
      }
      if (!icon) {
        icon = [NSImage imageNamed:@"Wawona"];
      }
      if (!icon) {
        NSString *pngPath =
            [[NSBundle mainBundle] pathForResource:@"Wawona" ofType:@"png"];
        if (pngPath) {
          icon = [[NSImage alloc] initWithContentsOfFile:pngPath];
        }
      }
      if (!icon) {
        NSString *lightPath = [[NSBundle mainBundle]
            pathForResource:@"Wawona-iOS-Light-1024x1024@1x"
                     ofType:@"png"];
        if (lightPath) {
          icon = [[NSImage alloc] initWithContentsOfFile:lightPath];
        }
      }

      if (icon) {
        self.headerImageView.image = icon;
      } else {
        // Last resort: remote URL
        NSString *img = item.imageURL ?: item.imageName;
        [[WWNImageLoader sharedLoader]
            loadImageFromURL:img
                  completion:^(WImage _Nullable image) {
                    if (image) {
                      self.headerImageView.image = image;
                    }
                  }];
      }

      // Inset text labels to the right of the 48px image + padding
      self.leadingConstraint.constant = 80;
      active = nil; // Headers never have a right-side control
    }

    // Final layout refinement:
    // If we have an active control (switch, text, button, etc.), we need to
    // leave space for it on the right. Otherwise, use full width.
    if (active) {
      self.trailingConstraint.constant =
          -(160 + 16 + 20); // Control + Spacing + Margin
    } else {
      self.trailingConstraint.constant = -20; // Full width
    }
  }
}

- (void)controlTextDidChange:(NSNotification *)obj {
  NSTextField *tf = [obj object];
  if (tf == self.textControl) {
    // Forward to act: with tag
    SEL actSel = NSSelectorFromString(@"act:");
    if ([self.delegate respondsToSelector:actSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      [self.delegate performSelector:actSel withObject:tf];
#pragma clang diagnostic pop
    }
  }
}
@end

@interface WWNSeparatorRowView : NSTableRowView
@end
@implementation WWNSeparatorRowView
- (void)drawSeparatorInRect:(NSRect)dirtyRect {
  // Draw custom iOS-style separator
  NSRect sRect =
      NSMakeRect(20, 0, self.bounds.size.width - 20, 1.0); // Inset left
  [[NSColor separatorColor] setFill];
  NSRectFill(sRect);
}
@end

@implementation WWNPreferencesContent
- (void)loadView {
  NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 400)];
  self.view = v;
  NSScrollView *sv = [[NSScrollView alloc] initWithFrame:v.bounds];
  sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  sv.drawsBackground = NO; // Fix Unified Background

  self.tableView = [[NSTableView alloc] initWithFrame:sv.bounds];
  self.tableView.dataSource = self;
  self.tableView.delegate = self;
  self.tableView.headerView = nil;
  self.tableView.backgroundColor =
      [NSColor clearColor];                           // Fix Unified Background
  self.tableView.gridStyleMask = NSTableViewGridNone; // Custom separators
  self.tableView.intercellSpacing =
      NSMakeSize(0, 0); // Tight packing for custom rows
  self.tableView.columnAutoresizingStyle =
      NSTableViewUniformColumnAutoresizingStyle;

  NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:@"C"];
  c.width = sv.bounds.size.width;                 // Match scroll view width
  c.minWidth = 300;                               // Minimum column width
  c.resizingMask = NSTableColumnAutoresizingMask; // Auto-resize with window
  [self.tableView addTableColumn:c];
  sv.documentView = self.tableView;
  sv.hasHorizontalScroller = NO; // No horizontal scroll - content should fit
  [v addSubview:sv];
}

// Use custom row view for separators
- (NSTableRowView *)tableView:(NSTableView *)tableView
                rowViewForRow:(NSInteger)row {
  WWNSeparatorRowView *rv =
      [tableView makeViewWithIdentifier:@"Row" owner:self];
  if (!rv) {
    rv = [[WWNSeparatorRowView alloc] initWithFrame:NSZeroRect];
    rv.identifier = @"Row";
  }
  return rv;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
  return self.section.items.count;
}

- (NSView *)tableView:(NSTableView *)tv
    viewForTableColumn:(NSTableColumn *)tc
                   row:(NSInteger)row {
  WWNPreferenceCell *cell = [tv makeViewWithIdentifier:@"PCell" owner:self];
  if (!cell) {
    cell = [[WWNPreferenceCell alloc] initWithFrame:NSMakeRect(0, 0, 400, 50)];
  }
  WWNSettingItem *item = self.section.items[row];
  [cell configureWithItem:item target:self action:@selector(act:)];

  // Ensure tags are set correctly for 'act:' lookup if needed (though we rely
  // on sender usually)
  if (!cell.switchControl.hidden)
    cell.switchControl.tag = row;
  if (!cell.textControl.hidden)
    cell.textControl.tag = row;
  if (!cell.buttonControl.hidden)
    cell.buttonControl.tag = row;
  if (!cell.popupControl.hidden)
    cell.popupControl.tag = row;

  return cell;
}

- (void)act:(id)sender {
  NSInteger row = (NSInteger)[sender tag];
  if (row < 0 || row >= (NSInteger)self.section.items.count) {
    return;
  }

  WWNSettingItem *item = self.section.items[row];

  // Handle password fields - show a dialog for password entry
  if (item.type == WSettingPassword) {
    [self showPasswordDialogForItem:item row:row];
    return;
  }

  if (item.type == WSettingButton) {
    if (item.actionBlock) {
      item.actionBlock();
    }
    return;
  }

  if (item.type == WSettingInfo) {
    // For Info type, copy to clipboard on click
    NSString *val =
        [[NSUserDefaults standardUserDefaults] stringForKey:item.key];
    NSString *valueString = val ? val : [item.defaultValue description];
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard setString:valueString forType:NSPasteboardTypeString];
    return;
  }

  if (item.type == WSettingLink) {
    // For Link type, open URL in browser
    if (item.urlString) {
      NSURL *url = [NSURL URLWithString:item.urlString];
      if (url) {
        [[NSWorkspace sharedWorkspace] openURL:url];
      }
    }
    return;
  }

  if (item.type == WSettingHeader) {
    // Header is not clickable
    return;
  }

  id val = nil;
  if ([sender isKindOfClass:[NSSwitch class]]) {
    val = @([(NSSwitch *)sender state] == NSControlStateValueOn);
  } else if ([sender isKindOfClass:[NSTextField class]]) {
    val = [(NSTextField *)sender stringValue];
    // For text fields, save immediately when value changes
    if (val && item.key) {
      [[NSUserDefaults standardUserDefaults] setObject:val forKey:item.key];
    }
    return; // Return early for text fields - they save on each change
  } else if ([sender isKindOfClass:[NSPopUpButton class]]) {
    // Handle SSHAuthMethod specially - store as integer index
    if ([item.key isEqualToString:@"SSHAuthMethod"] ||
        [item.key isEqualToString:@"WaypipeSSHAuthMethod"]) {
      NSInteger selectedIndex = [(NSPopUpButton *)sender indexOfSelectedItem];
      [[NSUserDefaults standardUserDefaults] setInteger:selectedIndex
                                                 forKey:item.key];

      // Auth method changed - rebuild sections to show appropriate nested
      // options
      WWNPreferences *prefs = [WWNPreferences sharedPreferences];
      prefs.sections = [prefs buildSections];
      [self.tableView reloadData];

      [[NSNotificationCenter defaultCenter]
          postNotificationName:@"WWNPreferencesChanged"
                        object:nil];
      return;
    }
    NSInteger idx = [(NSPopUpButton *)sender indexOfSelectedItem];
    if (item.optionValues && idx >= 0 &&
        idx < (NSInteger)item.optionValues.count) {
      val = item.optionValues[idx];
    } else {
      val = [(NSPopUpButton *)sender titleOfSelectedItem];
    }
  }

  if (val && item.key) {
    [[NSUserDefaults standardUserDefaults] setObject:val forKey:item.key];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"WWNPreferencesChanged"
                      object:nil];
  }
}

- (void)showPasswordDialogForItem:(WWNSettingItem *)item row:(NSInteger)row {
  // Single modal for password entry - always show entry field
  // Saving a new password automatically overwrites any existing one
  WWNPreferencesManager *prefs = [WWNPreferencesManager sharedManager];

  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = item.title;
  alert.informativeText = item.desc ?: @"Enter password:";
  [alert addButtonWithTitle:@"Save"];
  [alert addButtonWithTitle:@"Cancel"];

  // Create container view with password field and toggle button
  NSView *containerView =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];

  // Create secure text field (hidden by default)
  NSSecureTextField *secureField =
      [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 250, 24)];
  secureField.placeholderString = @"Enter a Password...";
  secureField.stringValue = @"";
  [containerView addSubview:secureField];

  // Create plain text field (for showing password)
  NSTextField *plainField =
      [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 250, 24)];
  plainField.placeholderString = @"Enter a Password...";
  plainField.stringValue = @"";
  plainField.hidden = YES;
  [containerView addSubview:plainField];

  // Create eyeball toggle button
  NSButton *toggleButton =
      [[NSButton alloc] initWithFrame:NSMakeRect(255, 2, 20, 20)];
  toggleButton.bezelStyle = NSBezelStyleInline;
  toggleButton.bordered = NO;
  toggleButton.image = [NSImage imageWithSystemSymbolName:@"eye"
                                 accessibilityDescription:@"Show password"];

  // Store references for toggle action
  objc_setAssociatedObject(toggleButton, "secureField", secureField,
                           OBJC_ASSOCIATION_RETAIN);
  objc_setAssociatedObject(toggleButton, "plainField", plainField,
                           OBJC_ASSOCIATION_RETAIN);
  objc_setAssociatedObject(toggleButton, "isSecure", @YES,
                           OBJC_ASSOCIATION_RETAIN);

  toggleButton.target = self;
  toggleButton.action = @selector(toggleMacOSPasswordVisibility:);

  [containerView addSubview:toggleButton];

  alert.accessoryView = containerView;

  // Make the secure field first responder when alert appears
  [alert.window makeFirstResponder:secureField];

  NSModalResponse response = [alert runModal];

  if (response == NSAlertFirstButtonReturn) {
    // Save button clicked - get password from whichever field is visible
    NSNumber *isSecureNum = objc_getAssociatedObject(toggleButton, "isSecure");
    NSString *enteredPassword = isSecureNum.boolValue ? secureField.stringValue
                                                      : plainField.stringValue;

    // Save password (overwrites existing if any)
    if ([item.key isEqualToString:@"WaypipeSSHPassword"]) {
      prefs.waypipeSSHPassword = enteredPassword;
    } else if ([item.key isEqualToString:@"WaypipeSSHKeyPassphrase"]) {
      prefs.waypipeSSHKeyPassphrase = enteredPassword;
    } else if ([item.key isEqualToString:@"SSHPassword"]) {
      prefs.sshPassword = enteredPassword;
    } else if ([item.key isEqualToString:@"SSHKeyPassphrase"]) {
      prefs.sshKeyPassphrase = enteredPassword;
    }

    // Update the button text to reflect new state
    [self.tableView reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:row]
                              columnIndexes:[NSIndexSet indexSetWithIndex:0]];
  }
  // Cancel = do nothing
}

- (void)toggleMacOSPasswordVisibility:(NSButton *)sender {
  NSSecureTextField *secureField =
      objc_getAssociatedObject(sender, "secureField");
  NSTextField *plainField = objc_getAssociatedObject(sender, "plainField");
  NSNumber *isSecureNum = objc_getAssociatedObject(sender, "isSecure");
  BOOL isSecure = isSecureNum ? isSecureNum.boolValue : YES;

  if (isSecure) {
    // Switch to plain text (show password)
    plainField.stringValue = secureField.stringValue;
    secureField.hidden = YES;
    plainField.hidden = NO;
    [plainField.window makeFirstResponder:plainField];
    sender.image = [NSImage imageWithSystemSymbolName:@"eye.slash"
                             accessibilityDescription:@"Hide password"];
    objc_setAssociatedObject(sender, "isSecure", @NO, OBJC_ASSOCIATION_RETAIN);
  } else {
    // Switch to secure (hide password)
    secureField.stringValue = plainField.stringValue;
    plainField.hidden = YES;
    secureField.hidden = NO;
    [secureField.window makeFirstResponder:secureField];
    sender.image = [NSImage imageWithSystemSymbolName:@"eye"
                             accessibilityDescription:@"Show password"];
    objc_setAssociatedObject(sender, "isSecure", @YES, OBJC_ASSOCIATION_RETAIN);
  }
}

- (CGFloat)tableView:(NSTableView *)tv heightOfRow:(NSInteger)row {
  if (row < (NSInteger)self.section.items.count) {
    WWNSettingItem *item = self.section.items[row];
    if (item.type == WSettingHeader) {
      return 68.0; // Taller row for header with icon
    }
  }
  return 50.0;
}

@end
