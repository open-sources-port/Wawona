#import "WWNAboutPanel.h"
#import "../Helpers/WWNImageLoader.h"
#ifndef WAWONA_VERSION
#define WAWONA_VERSION "0.0.0-unknown"
#endif


@implementation WWNAboutPanel

+ (instancetype)sharedAboutPanel {
  static WWNAboutPanel *sharedInstance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedInstance = [[self alloc] init];
  });
  return sharedInstance;
}

- (instancetype)init {
  NSWindow *window = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(0, 0, 400, 480)
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                          NSWindowStyleMaskFullSizeContentView
                  backing:NSBackingStoreBuffered
                    defer:NO];
  [window setTitle:@"About Muplar Wayland"];
  [window center];
  [window setLevel:NSFloatingWindowLevel];
  [window setCollectionBehavior:NSWindowCollectionBehaviorMoveToActiveSpace];

  // Let AppKit handle window appearance with native Liquid Glass
  self = [super initWithWindow:window];
  if (self) {
    [[self.window standardWindowButton:NSWindowMiniaturizeButton]
        setHidden:YES];
    [[self.window standardWindowButton:NSWindowZoomButton] setHidden:YES];
    [self setupAboutView];
  }
  return self;
}

// Setup Tahoe glass background effect
// Removed: managed by configureWindowAppearance now

- (void)setupAboutView {
  NSView *contentView = self.window.contentView;

  NSStackView *stack = [[NSStackView alloc] init];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.spacing = 20;
  stack.edgeInsets = NSEdgeInsetsMake(40, 40, 40, 40);
  stack.alignment = NSLayoutAttributeCenterX;
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  [contentView addSubview:stack];

  [NSLayoutConstraint activateConstraints:@[
    [stack.topAnchor constraintEqualToAnchor:contentView.topAnchor constant:50],
    [stack.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor
                                        constant:40],
    [stack.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor
                                         constant:-40],
    [stack.bottomAnchor
        constraintLessThanOrEqualToAnchor:contentView.bottomAnchor
                                 constant:-30]
  ]];

  // App Logo
  NSImageView *logoView = [[NSImageView alloc] init];
  logoView.imageScaling = NSImageScaleProportionallyUpOrDown;
  logoView.translatesAutoresizingMaskIntoConstraints = NO;

  // Prefer the dark variant for About branding.
  NSImage *logo = [NSImage imageNamed:@"Wawona-iOS-Dark-1024x1024@1x.png"];
  if (!logo) {
    NSString *darkPath = [[NSBundle mainBundle]
        pathForResource:@"Wawona-iOS-Dark-1024x1024@1x"
                 ofType:@"png"];
    if (darkPath) {
      logo = [[NSImage alloc] initWithContentsOfFile:darkPath];
    }
  }
  if (!logo) {
    logo = [NSImage imageNamed:@"Wawona"];
  }
  if (!logo) {
    NSString *pngPath =
        [[NSBundle mainBundle] pathForResource:@"Wawona" ofType:@"png"];
    if (pngPath) {
      logo = [[NSImage alloc] initWithContentsOfFile:pngPath];
    }
  }
  if (!logo) {
    logo = [NSImage imageNamed:@"Wawona-iOS-Light-1024x1024@1x.png"];
  }
  if (logo) {
    logoView.image = logo;
  }

  [stack addArrangedSubview:logoView];
  [NSLayoutConstraint activateConstraints:@[
    [logoView.widthAnchor constraintEqualToConstant:128],
    [logoView.heightAnchor constraintEqualToConstant:128]
  ]];

  // App Name
  NSTextField *title = [[NSTextField alloc] init];
  title.stringValue = @"muplar-wayland";
  title.font = [NSFont systemFontOfSize:42 weight:NSFontWeightBold];
  title.alignment = NSTextAlignmentCenter;
  title.bezeled = NO;
  title.drawsBackground = NO;
  title.editable = NO;
  title.selectable = NO;
  [stack addArrangedSubview:title];

  // Subtitle (Platform)
  NSTextField *subtitle = [[NSTextField alloc] init];
  subtitle.stringValue = @"Native macOS Wayland Compositor";
  subtitle.font = [NSFont systemFontOfSize:16 weight:NSFontWeightMedium];
  subtitle.textColor = [NSColor secondaryLabelColor];
  subtitle.alignment = NSTextAlignmentCenter;
  subtitle.bezeled = NO;
  subtitle.drawsBackground = NO;
  subtitle.editable = NO;
  subtitle.selectable = NO;
  [stack addArrangedSubview:subtitle];

  // Version Section (Vertically Centered Stack)
  NSStackView *versionStack = [[NSStackView alloc] init];
  versionStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  versionStack.spacing = 8;
  versionStack.alignment = NSLayoutAttributeCenterY;
  [stack addArrangedSubview:versionStack];

  NSString *version = [NSString stringWithUTF8String:WAWONA_VERSION];
  if (![version hasPrefix:@"v"]) {
    version = [NSString stringWithFormat:@"v%@", version];
  }

  NSTextField *versionLabel = [[NSTextField alloc] init];
  versionLabel.stringValue = [NSString stringWithFormat:@"Version %@", version];
  versionLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightRegular];
  versionLabel.textColor = [NSColor tertiaryLabelColor];
  versionLabel.alignment = NSTextAlignmentCenter;
  versionLabel.bezeled = NO;
  versionLabel.drawsBackground = NO;
  versionLabel.editable = NO;
  versionLabel.selectable = NO;
  [versionStack addArrangedSubview:versionLabel];

  [stack setCustomSpacing:30 afterView:versionStack];

  // Separator
  [stack addArrangedSubview:[self createSeparator]];

  // Credits Header
  NSTextField *creditsHeader = [[NSTextField alloc] init];
  creditsHeader.stringValue = @"Author";
  creditsHeader.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
  creditsHeader.textColor = [NSColor secondaryLabelColor];
  creditsHeader.alignment = NSTextAlignmentCenter;
  creditsHeader.bezeled = NO;
  creditsHeader.drawsBackground = NO;
  creditsHeader.editable = NO;
  creditsHeader.selectable = NO;
  [stack addArrangedSubview:creditsHeader];

  // Author Info Container (Vertically centered)
  NSStackView *authorStack = [[NSStackView alloc] init];
  authorStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  authorStack.spacing = 20;
  authorStack.alignment = NSLayoutAttributeCenterY;
  [stack addArrangedSubview:authorStack];

  // Avatar
  NSImageView *avatarView = [[NSImageView alloc] init];
  avatarView.imageScaling = NSImageScaleProportionallyUpOrDown;
  avatarView.translatesAutoresizingMaskIntoConstraints = NO;
  avatarView.image = [NSImage imageNamed:NSImageNameUser];

  // Setup layer for a perfect circle
  avatarView.wantsLayer = YES;
  avatarView.layer.masksToBounds = YES;
  avatarView.layer.cornerRadius = 32.0;
  avatarView.layer.contentsGravity = kCAGravityResizeAspect;
  avatarView.layer.borderWidth = 0.0; // Ensure no default border interference

  [authorStack addArrangedSubview:avatarView];

  [NSLayoutConstraint activateConstraints:@[
    [avatarView.widthAnchor constraintEqualToConstant:64],
    [avatarView.heightAnchor constraintEqualToConstant:64]
  ]];
  [self loadGitHubAvatar:avatarView];

  // Author details
  NSStackView *detailsStack = [[NSStackView alloc] init];
  detailsStack.orientation = NSUserInterfaceLayoutOrientationVertical;
  detailsStack.spacing = 4;
  detailsStack.alignment = NSLayoutAttributeLeading;
  [authorStack addArrangedSubview:detailsStack];

  NSTextField *nameLabel = [[NSTextField alloc] init];
  nameLabel.stringValue = @"Alex Spaulding";
  nameLabel.font = [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold];
  nameLabel.bezeled = NO;
  nameLabel.drawsBackground = NO;
  nameLabel.editable = NO;
  nameLabel.selectable = YES;
  [detailsStack addArrangedSubview:nameLabel];

  NSTextField *handleLabel = [[NSTextField alloc] init];
  handleLabel.stringValue = @"github@aspauldingcode";
  handleLabel.font = [NSFont systemFontOfSize:12];
  handleLabel.textColor = [NSColor linkColor];
  handleLabel.bezeled = NO;
  handleLabel.drawsBackground = NO;
  handleLabel.editable = NO;
  handleLabel.selectable = YES;
  [detailsStack addArrangedSubview:handleLabel];

  [stack setCustomSpacing:40 afterView:authorStack];

  // =========================================================================
  // DONATION EMPHASIS
  // =========================================================================
  [stack addArrangedSubview:[self createSeparator]];

  NSTextField *supportLabel = [[NSTextField alloc] init];
  supportLabel.stringValue = @"Love Muplar Wayland? Support development!";
  supportLabel.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
  supportLabel.textColor = [NSColor labelColor];
  supportLabel.alignment = NSTextAlignmentCenter;
  supportLabel.bezeled = NO;
  supportLabel.drawsBackground = NO;
  supportLabel.editable = NO;
  supportLabel.selectable = NO;
  [stack addArrangedSubview:supportLabel];

  NSStackView *donateStack = [[NSStackView alloc] init];
  donateStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  donateStack.spacing = 15;
  donateStack.distribution = NSStackViewDistributionFillEqually;
  [stack addArrangedSubview:donateStack];

  NSButton *kofiButton = [[NSButton alloc] init];
  kofiButton.title = @"Ko-fi";
  kofiButton.imagePosition = NSImageLeft;
  kofiButton.bezelStyle = NSBezelStyleRounded;
  kofiButton.target = self;
  kofiButton.action = @selector(openDonateLink:);
  kofiButton.controlSize = NSControlSizeLarge;
  [donateStack addArrangedSubview:kofiButton];

  NSButton *sponsorButton = [[NSButton alloc] init];
  sponsorButton.title = @"GitHub Sponsors";
  sponsorButton.imagePosition = NSImageLeft;
  sponsorButton.bezelStyle = NSBezelStyleRounded;
  sponsorButton.target = self;
  sponsorButton.action = @selector(openSponsorLink:);
  sponsorButton.controlSize = NSControlSizeLarge;
  [donateStack addArrangedSubview:sponsorButton];

  [NSLayoutConstraint activateConstraints:@[
    [donateStack.widthAnchor constraintEqualToConstant:320],
    [kofiButton.heightAnchor constraintEqualToConstant:40],
    [sponsorButton.heightAnchor constraintEqualToConstant:40]
  ]];

  [stack setCustomSpacing:30 afterView:donateStack];

  // Footer / Buttons
  NSStackView *footerStack = [[NSStackView alloc] init];
  footerStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  footerStack.spacing = 15;
  footerStack.distribution = NSStackViewDistributionFillEqually;
  [stack addArrangedSubview:footerStack];

  NSButton *repoButton =
      [self premiumButtonWithTitle:@"GitHub" action:@selector(openGitHubLink:)];
  [footerStack addArrangedSubview:repoButton];

  NSButton *xButton =
      [self premiumButtonWithTitle:@"X" action:@selector(openXLink:)];
  [footerStack addArrangedSubview:xButton];

  NSButton *linkedinButton =
      [self premiumButtonWithTitle:@"LinkedIn"
                            action:@selector(openLinkedInLink:)];
  [footerStack addArrangedSubview:linkedinButton];

  NSButton *webButton =
      [self premiumButtonWithTitle:@"Portfolio"
                            action:@selector(openPortfolioLink:)];
  [footerStack addArrangedSubview:webButton];

  // Configure icons
  [self loadImageURL:@"https://ko-fi.com/android-icon-192x192.png"
            intoView:kofiButton];
  [self loadImageURL:@"https://encrypted-tbn0.gstatic.com/images?q=tbn:"
                     @"ANd9GcRp_gdQoe-SxKGw3IvS-1G_JPsMY70HkqxAPg&s"
            intoView:sponsorButton];
  [self loadImageURL:@"https://github.githubassets.com/images/modules/logos_"
                     @"page/GitHub-Mark.png"
            intoView:repoButton];
  [self loadImageURL:@"https://x.com/favicon.ico" intoView:xButton];
  [self loadImageURL:@"https://upload.wikimedia.org/wikipedia/commons/c/ca/"
                     @"LinkedIn_logo_initials.png"
            intoView:linkedinButton];
  [self loadImageURL:@"https://aspauldingcode.com/favicon.ico"
            intoView:webButton];

  // Copyright
  NSTextField *copyright = [[NSTextField alloc] init];
  copyright.stringValue = @"© 2026 Alex Spaulding. All rights reserved.";
  copyright.font = [NSFont systemFontOfSize:11];
  copyright.textColor = [NSColor tertiaryLabelColor];
  copyright.alignment = NSTextAlignmentCenter;
  copyright.bezeled = NO;
  copyright.drawsBackground = NO;
  copyright.editable = NO;
  copyright.selectable = NO;
  [stack addArrangedSubview:copyright];
}

- (NSButton *)premiumButtonWithTitle:(NSString *)title action:(SEL)action {
  NSButton *btn = [[NSButton alloc] init];
  btn.title = title;
  btn.target = self;
  btn.action = action;
  btn.bezelStyle = NSBezelStyleRounded;
  btn.imagePosition = NSImageLeft; // Position image to the left of text
  return btn;
}

- (void)loadImageURL:(NSString *)url intoView:(id)view {
  [[WWNImageLoader sharedLoader]
      loadImageFromURL:url
            completion:^(WImage _Nullable image) {
              if (!image) {
                return;
              }
              if ([view isKindOfClass:[NSButton class]]) {
                NSButton *btn = (NSButton *)view;
                [image setSize:NSMakeSize(16, 16)];
                btn.image = image;
              } else if ([view isKindOfClass:[NSImageView class]]) {
                NSImageView *iv = (NSImageView *)view;
                iv.image = image;
              }
            }];
}

- (NSBox *)createSeparator {
  NSBox *separator = [[NSBox alloc] init];
  separator.boxType = NSBoxSeparator;
  separator.translatesAutoresizingMaskIntoConstraints = NO;
  [separator.widthAnchor constraintEqualToConstant:400].active = YES;
  [separator.heightAnchor constraintEqualToConstant:1].active = YES;
  return separator;
}

- (void)showAboutPanel:(id)sender {
  [self showWindow:sender];
  [self.window makeKeyAndOrderFront:sender];
  [NSApp activateIgnoringOtherApps:YES];
}

- (void)openDonateLink:(NSButton *)sender {
  [[NSWorkspace sharedWorkspace]
      openURL:[NSURL URLWithString:@"https://ko-fi.com/aspauldingcode"]];
}

- (void)openGitHubLink:(NSButton *)sender {
  [[NSWorkspace sharedWorkspace]
      openURL:[NSURL
                  URLWithString:@"https://github.com/aspauldingcode/Wawona"]];
}

- (void)openPortfolioLink:(NSButton *)sender {
  [[NSWorkspace sharedWorkspace]
      openURL:[NSURL URLWithString:@"https://aspauldingcode.com"]];
}

- (void)openXLink:(NSButton *)sender {
  [[NSWorkspace sharedWorkspace]
      openURL:[NSURL URLWithString:@"https://x.com/aspauldingcode"]];
}

- (void)openLinkedInLink:(NSButton *)sender {
  [[NSWorkspace sharedWorkspace]
      openURL:
          [NSURL URLWithString:@"https://www.linkedin.com/in/aspauldingcode/"]];
}

- (void)openSponsorLink:(NSButton *)sender {
  [[NSWorkspace sharedWorkspace]
      openURL:[NSURL
                  URLWithString:@"https://github.com/sponsors/aspauldingcode"]];
}
- (void)loadGitHubAvatar:(NSImageView *)imageView {
  NSString *avatarURLString = @"https://github.com/aspauldingcode.png?size=128";
  [self loadImageURL:avatarURLString intoView:imageView];
}

@end
