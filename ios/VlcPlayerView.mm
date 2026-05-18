#import "VlcPlayerView.h"

#import <React/RCTLog.h>
#import <VLCKit/VLCKit.h>
#import <objc/runtime.h>

// VLCKit's modulemap excludes <vlc/libvlc*.h>, so forward-declare what we use.
#if defined(__cplusplus)
extern "C" {
#endif

typedef struct libvlc_media_player_t  libvlc_media_player_t;
typedef struct libvlc_event_manager_t libvlc_event_manager_t;

typedef int64_t libvlc_time_t;

typedef struct libvlc_event_t {
    int   type;
    void *p_obj;
    union {
        struct { float new_cache; } media_player_buffering;
        struct { libvlc_time_t new_time; } media_player_time_changed;
        struct { libvlc_time_t new_length; } media_player_length_changed;
    } u;
} libvlc_event_t;

typedef void (*libvlc_callback_t)(const libvlc_event_t *, void *);

enum {
    libvlc_MediaPlayerBuffering     = 0x103,
    libvlc_MediaPlayerStopping      = 0x109,
    libvlc_MediaPlayerTimeChanged   = 0x10b,
    libvlc_MediaPlayerLengthChanged = 0x111,
};

extern libvlc_event_manager_t *libvlc_media_player_event_manager(libvlc_media_player_t *p_mi);
extern int  libvlc_event_attach(libvlc_event_manager_t *p_event_manager, int i_event_type,
                                libvlc_callback_t f_callback, void *user_data);
extern void libvlc_event_detach(libvlc_event_manager_t *p_event_manager, int i_event_type,
                                libvlc_callback_t f_callback, void *user_data);

#if defined(__cplusplus)
}
#endif

static inline int VLCClampInt32(int64_t value)
{
  if (value < 0) return 0;
  if (value > INT32_MAX) return INT32_MAX;
  return (int)value;
}

static inline float VLCClampFloat(float value, float lo, float hi)
{
  if (value < lo) return lo;
  if (value > hi) return hi;
  return value;
}

#import <react/renderer/components/VlcPlayerViewSpec/ComponentDescriptors.h>
#import <react/renderer/components/VlcPlayerViewSpec/EventEmitters.h>
#import <react/renderer/components/VlcPlayerViewSpec/Props.h>
#import <react/renderer/components/VlcPlayerViewSpec/RCTComponentViewHelpers.h>

#import "RCTFabricComponentsPlugins.h"

using namespace facebook::react;

#pragma mark - Tunables

// libvlc never surfaces "connection failed" for unreachable URLs — it sits in
// Opening forever. This caps the wait and turns it into an onError.
static const NSTimeInterval kVLCOpeningTimeout = 8.0;

static const NSTimeInterval kVLCBackgroundResumeThreshold = 5.0;
static const NSTimeInterval kVLCResumeFallbackDelay = 2.0;

typedef NS_ENUM(NSInteger, VlcPlayerResizeMode) {
  VlcPlayerResizeModeContain,
  VlcPlayerResizeModeCover,
  VlcPlayerResizeModeStretch,
  VlcPlayerResizeModeOriginal,
};

#pragma mark - Helpers

static NSString *VLCStringFromStdString(const std::string &value)
{
  return [NSString stringWithUTF8String:value.c_str()] ?: @"";
}

static NSArray<NSString *> *VLCStringsFromVector(const std::vector<std::string> &values)
{
  NSMutableArray<NSString *> *strings = [NSMutableArray arrayWithCapacity:values.size()];
  for (const auto &value : values) {
    [strings addObject:VLCStringFromStdString(value)];
  }
  return [strings copy];
}

static NSString *VLCTrimmedString(NSString *value)
{
  NSString *trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  return trimmed.length == 0 ? nil : trimmed;
}

static NSURL *VLCURLFromString(NSString *value)
{
  NSString *trimmed = VLCTrimmedString(value);
  return trimmed.length == 0 ? nil : [NSURL URLWithString:trimmed];
}

static VlcPlayerResizeMode VLCResizeModeFromString(NSString *value)
{
  NSString *mode = [value lowercaseString];
  if ([mode isEqualToString:@"cover"]) {
    return VlcPlayerResizeModeCover;
  }
  if ([mode isEqualToString:@"stretch"]) {
    return VlcPlayerResizeModeStretch;
  }
  if ([mode isEqualToString:@"original"] || [mode isEqualToString:@"center"]) {
    return VlcPlayerResizeModeOriginal;
  }
  return VlcPlayerResizeModeContain;
}

static NSString *VLCExceptionReason(NSException *exception)
{
  return exception.reason ?: @"Unknown VLCKit exception";
}

// Masks user:password@ in URLs so credentials don't end up in logs.
static NSString *VLCRedactedURLString(NSURL *url)
{
  if (url == nil) {
    return @"";
  }
  if (url.user == nil && url.password == nil) {
    return url.absoluteString;
  }
  NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
  if (components == nil) {
    return url.absoluteString;
  }
  if (components.user != nil) {
    components.user = @"***";
  }
  if (components.password != nil) {
    components.password = @"***";
  }
  return components.string ?: url.absoluteString;
}

static inline void VLCRunOnMain(dispatch_block_t block)
{
  if (NSThread.isMainThread) {
    block();
  } else {
    dispatch_async(dispatch_get_main_queue(), block);
  }
}

// Reach into VLCMediaPlayer's private `_playerInstance` ivar — VLCKit's
// wrapper drops libvlc's cache values, so we hook libvlc directly.
static libvlc_media_player_t *VLCRawMediaPlayer(VLCMediaPlayer *player)
{
  if (player == nil) return NULL;
  Ivar ivar = class_getInstanceVariable([VLCMediaPlayer class], "_playerInstance");
  if (ivar == NULL) return NULL;
  ptrdiff_t offset = ivar_getOffset(ivar);
  void *base = (__bridge void *)player;
  return *(libvlc_media_player_t **)((char *)base + offset);
}

@class VlcPlayerView;
@interface VlcPlayerView (VLCEventHandler)
- (void)handleLibVLCBufferingPercent:(float)percent;
- (void)handleLibVLCTimeChanged:(int64_t)timeMs;
- (void)handleLibVLCLengthChanged:(int64_t)lengthMs;
- (void)handleLibVLCStopping;
@end

// libvlc event thread. Extract data sync (event struct is stack-allocated),
// then hop to main.
static void VLCEventCallback(const libvlc_event_t *event, void *userData)
{
  if (event == NULL) return;
  VlcPlayerView *view = (__bridge VlcPlayerView *)userData;
  __weak VlcPlayerView *weakView = view;

  switch (event->type) {
    case libvlc_MediaPlayerBuffering: {
      float cache = event->u.media_player_buffering.new_cache;
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakView handleLibVLCBufferingPercent:cache];
      });
      break;
    }
    case libvlc_MediaPlayerTimeChanged: {
      int64_t timeMs = (int64_t)event->u.media_player_time_changed.new_time;
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakView handleLibVLCTimeChanged:timeMs];
      });
      break;
    }
    case libvlc_MediaPlayerLengthChanged: {
      int64_t lengthMs = (int64_t)event->u.media_player_length_changed.new_length;
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakView handleLibVLCLengthChanged:lengthMs];
      });
      break;
    }
    case libvlc_MediaPlayerStopping: {
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakView handleLibVLCStopping];
      });
      break;
    }
    default:
      break;
  }
}

// NSObject<VLCDrawable> forwarder, mirroring VLC for iOS's PlaybackService
// pattern. VLCKit 4 alpha's new rendering pipeline only engages on this
// path; passing a UIView directly falls back to one that ignores resize
// settings.
@interface VlcDrawable : NSObject <VLCDrawable>
@property (nonatomic, weak) UIView *target;
@end
@implementation VlcDrawable
- (CGRect)bounds { return self.target.bounds; }
- (void)addSubview:(UIView *)view
{
  UIView *target = self.target;
  [target addSubview:view];
  view.frame = target.bounds;
  view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  // libvlc's iOS vout module attaches a single-tap-to-pause UITapGestureRecognizer
  // to its own rendering view. We don't want it for embedded players, and we
  // can't disable it via VLCKit API — silence it by disabling touch handling
  // on this view only. Outer views stay interactive.
  view.userInteractionEnabled = NO;
}
@end

@interface VlcPlayerView () <RCTVlcPlayerViewViewProtocol>
@end

@implementation VlcPlayerView {
  UIView *_videoView;        // outer container — user-facing
  UIView *_videoOutputView;  // inner libvlc render target — added to _videoView
  VlcDrawable *_drawable;    // NSObject<VLCDrawable> forwarder; what libvlc sees as drawable

  VLCMediaPlayer *_mediaPlayer;
  NSArray<NSString *> *_playerInitOptions;

  // Desired (props)
  NSURL *_desiredURL;
  BOOL _desiredPaused;
  BOOL _desiredMuted;
  float _desiredVolume;
  BOOL _desiredRepeat;
  NSArray<NSString *> *_desiredInitOptions;
  NSArray<NSString *> *_desiredMediaOptions;
  VlcPlayerResizeMode _desiredResizeMode;

  // Loaded (in VLC)
  NSURL *_loadedURL;
  NSArray<NSString *> *_loadedMediaOptions;

  // Applied (pushed to player)
  BOOL _appliedPaused;
  BOOL _appliedMuted;
  float _appliedVolume;
  NSString *_appliedAspectOverride;

  BOOL _destroyed;
  BOOL _hasEmittedLoad;
  BOOL _hasEmittedEnd;
  BOOL _isBufferingState;
  BOOL _userInitiatedStop;  // set before our [stop]; consumed by Stopping handler
  NSDate *_backgroundDate;
  NSUInteger _generation;
  NSUInteger _playIssuedGeneration;
  dispatch_block_t _openingTimeoutBlock;
  dispatch_block_t _resumeFallbackBlock;

  // Cached at emitLoadIfReady so the libvlc time-changed handler can compute
  // percent without touching `_mediaPlayer.media` (which races with media swaps).
  int64_t _loadedDurationMs;
}

+ (ComponentDescriptorProvider)componentDescriptorProvider
{
  return concreteComponentDescriptorProvider<VlcPlayerViewComponentDescriptor>();
}

#pragma mark - Lifecycle

- (instancetype)initWithFrame:(CGRect)frame
{
  if (self = [super initWithFrame:frame]) {
    static const auto defaultProps = std::make_shared<const VlcPlayerViewProps>();
    _props = defaultProps;

    _desiredPaused = NO;
    _desiredMuted = NO;
    _desiredVolume = 1.0f;
    _desiredRepeat = NO;
    _desiredInitOptions = @[];
    _desiredMediaOptions = @[];
    _desiredResizeMode = VlcPlayerResizeModeContain;
    _appliedPaused = YES;
    _appliedMuted = NO;
    _appliedVolume = 1.0f;

    [self setupView];
    [self registerLifecycleObservers];
  }

  return self;
}

- (void)dealloc
{
  [self cleanupPlayer];
}

- (void)layoutSubviews
{
  [super layoutSubviews];
  _videoView.frame = self.bounds;
  // Cover depends on container size; re-apply on rotation / size changes.
  [self applyDisplayOptions];
}

- (void)prepareForRecycle
{
  [super prepareForRecycle];
  [self resetDesiredState];
  [self releasePlayer];
}

- (void)cleanupPlayer
{
  if (_destroyed) {
    return;
  }

  _destroyed = YES;
  _desiredURL = nil;
  _backgroundDate = nil;

  [self removeLifecycleObservers];
  [self releasePlayer];
}

#pragma mark - Props & commands

- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps
{
  (void)oldProps;
  const auto &newProps = *std::static_pointer_cast<VlcPlayerViewProps const>(props);

  _desiredURL = VLCURLFromString(VLCStringFromStdString(newProps.url));
  _desiredPaused = newProps.paused;
  _desiredMuted = newProps.muted;
  {
    float vol = newProps.volume;
    if (vol < 0.0f) vol = 0.0f;
    if (vol > 1.0f) vol = 1.0f;
    _desiredVolume = vol;
  }
  _desiredRepeat = newProps.repeat;
  _desiredInitOptions = VLCStringsFromVector(newProps.initOptions);
  _desiredMediaOptions = VLCStringsFromVector(newProps.mediaOptions);
  _desiredResizeMode = VLCResizeModeFromString(VLCStringFromStdString(newProps.resizeMode));

  [self syncPlayer];
  [super updateProps:props oldProps:oldProps];
}

- (void)handleCommand:(const NSString *)commandName args:(const NSArray *)args
{
  RCTVlcPlayerViewHandleCommand(self, commandName, args);
}

- (void)play
{
  if (_destroyed) return;
  _desiredPaused = NO;
  [self syncPlayer];
}

- (void)pause
{
  if (_destroyed) return;
  _desiredPaused = YES;
  [self syncPlayer];
}

- (void)seek:(float)seconds
{
  if (_destroyed || _mediaPlayer == nil) return;
  double s = seconds < 0.0f ? 0.0 : (double)seconds;
  _mediaPlayer.time = [VLCTime timeWithInt:(int)(s * 1000.0)];
}

- (void)snapshot:(NSInteger)callIdNumber
{
  int32_t callId = (int32_t)callIdNumber;
  if (_destroyed || _mediaPlayer == nil) {
    [self emitSnapshotResult:callId base64:nil error:@"Player not ready"];
    return;
  }
  NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
      [NSString stringWithFormat:@"vlc-snap-%d-%@.png", callId, NSUUID.UUID.UUIDString]];

  @try {
    // libvlc_video_take_snapshot is sync; w=0 h=0 → source dimensions.
    [_mediaPlayer saveVideoSnapshotAt:path withWidth:0 andHeight:0];
  } @catch (NSException *exception) {
    [self emitSnapshotResult:callId base64:nil error:VLCExceptionReason(exception)];
    return;
  }

  NSData *data = [NSData dataWithContentsOfFile:path];
  [NSFileManager.defaultManager removeItemAtPath:path error:nil];
  if (data.length == 0) {
    [self emitSnapshotResult:callId base64:nil error:@"Snapshot file unavailable"];
    return;
  }
  [self emitSnapshotResult:callId
                    base64:[data base64EncodedStringWithOptions:0]
                     error:nil];
}

- (void)reload
{
  if (_destroyed || _desiredURL == nil) return;
  _desiredPaused = NO;
  [self releasePlayer];
  [self syncPlayer];
}

#pragma mark - View setup

- (void)setupView
{
  self.backgroundColor = UIColor.blackColor;
  self.clipsToBounds = YES;

  _videoView = [[UIView alloc] initWithFrame:self.bounds];
  _videoView.backgroundColor = UIColor.blackColor;
  _videoView.clipsToBounds = YES;
  _videoView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.contentView = _videoView;

  // Stable libvlc render target. Initial frame matches the screen (per VLC
  // for iOS) — libvlc captures pipeline geometry at first use, and creating
  // it at our (still-zero) bounds left libvlc in a broken state.
  _videoOutputView = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
  _videoOutputView.backgroundColor = UIColor.blackColor;
  [_videoView addSubview:_videoOutputView];
  _videoOutputView.frame = _videoView.bounds;

  _drawable = [[VlcDrawable alloc] init];
  _drawable.target = _videoOutputView;
}

- (void)resetDesiredState
{
  _desiredURL = nil;
  _desiredPaused = NO;
  _desiredMuted = NO;
  _desiredVolume = 1.0f;
  _desiredRepeat = NO;
  _desiredInitOptions = @[];
  _desiredMediaOptions = @[];
  _desiredResizeMode = VlcPlayerResizeModeContain;
  _appliedAspectOverride = nil;
  _appliedPaused = YES;
  _appliedMuted = NO;
  _appliedVolume = 1.0f;
  _backgroundDate = nil;
  _hasEmittedLoad = NO;
  _hasEmittedEnd = NO;
  _isBufferingState = NO;
  _videoView.contentMode = UIViewContentModeScaleAspectFit;
}

#pragma mark - Player sync

// Single reconciliation entry point. Main-thread only.
- (void)syncPlayer
{
  if (_destroyed) {
    return;
  }

  if (!NSThread.isMainThread) {
    VLCRunOnMain(^{ [self syncPlayer]; });
    return;
  }

  [self applyDisplayOptions];
  [self applyAudioOptions];

  if (_desiredURL == nil) {
    [self releasePlayer];
    return;
  }

  if (_mediaPlayer != nil && ![_playerInitOptions isEqualToArray:_desiredInitOptions]) {
    [self releasePlayer];
  }

  if (_mediaPlayer == nil && ![self createPlayer]) {
    return;
  }

  BOOL needsMedia =
      _loadedURL == nil ||
      ![_loadedURL isEqual:_desiredURL] ||
      ![_loadedMediaOptions isEqualToArray:_desiredMediaOptions];

  if (needsMedia && ![self loadDesiredMedia]) {
    return;
  }

  if (_desiredPaused) {
    [self pausePlayer];
  } else {
    [self playPlayer];
  }
}

- (BOOL)createPlayer
{
  @try {
    RCTLogInfo(@"VlcPlayerView: creating VLC player with initOptions [%@]",
               [_desiredInitOptions componentsJoinedByString:@", "]);

    VLCMediaPlayer *player = _desiredInitOptions.count == 0
        ? [[VLCMediaPlayer alloc] init]
        : [[VLCMediaPlayer alloc] initWithOptions:_desiredInitOptions];

    if (player == nil) {
      [self emitError:@"Failed to create VLC player: VLCKit returned nil" shouldStopPlayback:YES];
      return NO;
    }

    // Set drawable ONCE — never reassign during the player's lifetime.
    player.drawable = _drawable;

    // Per-player observer (not class-wide) — keeps stale notifications from a
    // previously-released player out. We avoid TimeChangedNotification: it
    // reads `player.media` and races with media swaps.
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(handleStateChanged:)
                                               name:VLCMediaPlayerStateChangedNotification
                                             object:player];

    libvlc_media_player_t *rawPlayer = VLCRawMediaPlayer(player);
    if (rawPlayer != NULL) {
      libvlc_event_manager_t *em = libvlc_media_player_event_manager(rawPlayer);
      void *userData = (__bridge void *)self;
      libvlc_event_attach(em, libvlc_MediaPlayerBuffering,     VLCEventCallback, userData);
      libvlc_event_attach(em, libvlc_MediaPlayerTimeChanged,   VLCEventCallback, userData);
      libvlc_event_attach(em, libvlc_MediaPlayerLengthChanged, VLCEventCallback, userData);
      libvlc_event_attach(em, libvlc_MediaPlayerStopping,      VLCEventCallback, userData);
    } else {
      RCTLogWarn(@"VlcPlayerView: VLCMediaPlayer._playerInstance unavailable — buffering/progress/end-of-stream signals degraded");
    }

    _mediaPlayer = player;
    _playerInitOptions = [_desiredInitOptions copy];
    _appliedPaused = YES;
    _appliedAspectOverride = nil;
    return YES;
  } @catch (NSException *exception) {
    [self emitError:[NSString stringWithFormat:@"Failed to create VLC player: %@", VLCExceptionReason(exception)]
 shouldStopPlayback:YES];
    return NO;
  }
}

- (BOOL)loadDesiredMedia
{
  VLCMediaPlayer *player = _mediaPlayer;
  NSURL *url = _desiredURL;
  if (player == nil || url == nil) {
    return NO;
  }

  [self invalidatePendingPlayback];
  _loadedURL = nil;
  _loadedMediaOptions = nil;
  _hasEmittedLoad = NO;
  _hasEmittedEnd = NO;
  _isBufferingState = NO;
  _loadedDurationMs = 0;

  @try {
    if (player.media != nil) {
      // Only flag the stop if it will actually fire Stopping; otherwise the
      // flag never gets consumed and suppresses a later natural end.
      VLCMediaPlayerState s = player.state;
      if (s == VLCMediaPlayerStateOpening ||
          s == VLCMediaPlayerStateBuffering ||
          s == VLCMediaPlayerStatePlaying ||
          s == VLCMediaPlayerStatePaused) {
        _userInitiatedStop = YES;
      }
      // pause-before-stop avoids the libvlc_media_retain race during RTSP teardown.
      [player pause];
      [player stop];
    }

    VLCMedia *media = [VLCMedia mediaWithURL:url];
    if (media == nil) {
      [self emitError:@"Failed to create VLC media" shouldStopPlayback:YES];
      return NO;
    }

    for (NSString *option in _desiredMediaOptions) {
      [media addOption:option];
    }
    if (_desiredRepeat) {
      [media addOption:@":input-repeat=65535"];
    }
    RCTLogInfo(@"VlcPlayerView: loading media %@ with mediaOptions [%@]",
               VLCRedactedURLString(url),
               [_desiredMediaOptions componentsJoinedByString:@", "]);

    player.media = media;
    _loadedURL = url;
    _loadedMediaOptions = [_desiredMediaOptions copy];
    _appliedPaused = YES;
    [self applyDisplayOptions];
    [self applyAudioOptions];
    return YES;
  } @catch (NSException *exception) {
    [self emitError:[NSString stringWithFormat:@"Failed to load VLC media: %@", VLCExceptionReason(exception)]
 shouldStopPlayback:YES];
    return NO;
  }
}

- (void)pausePlayer
{
  if (_appliedPaused) {
    return;
  }
  [self invalidatePendingPlayback];
  [_mediaPlayer pause];
  _appliedPaused = YES;
}

- (void)playPlayer
{
  VLCMediaPlayer *player = _mediaPlayer;
  NSURL *url = _loadedURL;
  if (_destroyed || _desiredPaused || player == nil || url == nil) {
    return;
  }

  NSUInteger generation = _generation;
  if (_playIssuedGeneration == generation) {
    return;
  }

  _playIssuedGeneration = generation;
  _appliedPaused = NO;

  @try {
    [player play];
    [self scheduleOpeningTimeoutForGeneration:generation player:player url:url];
  } @catch (NSException *exception) {
    [self emitError:[NSString stringWithFormat:@"Failed to start VLC playback: %@", VLCExceptionReason(exception)]
 shouldStopPlayback:YES];
  }
}

- (void)releasePlayer
{
  if (!NSThread.isMainThread) {
    dispatch_sync(dispatch_get_main_queue(), ^{ [self releasePlayer]; });
    return;
  }

  [self invalidatePendingPlayback];

  VLCMediaPlayer *player = _mediaPlayer;
  _mediaPlayer = nil;
  _playerInitOptions = nil;
  _loadedURL = nil;
  _loadedMediaOptions = nil;
  _hasEmittedLoad = NO;
  _hasEmittedEnd = NO;
  _isBufferingState = NO;
  _loadedDurationMs = 0;
  _appliedPaused = YES;

  if (player == nil) {
    return;
  }

  [NSNotificationCenter.defaultCenter removeObserver:self
                                                name:VLCMediaPlayerStateChangedNotification
                                              object:player];

  // libvlc_event_detach is sync — blocks until in-flight handlers complete.
  libvlc_media_player_t *rawPlayer = VLCRawMediaPlayer(player);
  if (rawPlayer != NULL) {
    libvlc_event_manager_t *em = libvlc_media_player_event_manager(rawPlayer);
    void *userData = (__bridge void *)self;
    libvlc_event_detach(em, libvlc_MediaPlayerBuffering,     VLCEventCallback, userData);
    libvlc_event_detach(em, libvlc_MediaPlayerTimeChanged,   VLCEventCallback, userData);
    libvlc_event_detach(em, libvlc_MediaPlayerLengthChanged, VLCEventCallback, userData);
    libvlc_event_detach(em, libvlc_MediaPlayerStopping,      VLCEventCallback, userData);
  }

  @try {
    // pause→drawable→stop avoids a libvlc_media_retain race during RTSP teardown.
    // Don't `player.media = nil` here: VLCKit 4 stop is async and clearing
    // media while events are still draining asserts on a NULL retain.
    [player pause];
    player.drawable = nil;
    [player stop];
  } @catch (NSException *exception) {
    RCTLogWarn(@"VlcPlayerView: failed to release VLC player cleanly: %@", VLCExceptionReason(exception));
  }
}

- (void)invalidatePendingPlayback
{
  _generation += 1;
  _playIssuedGeneration = 0;
  [self cancelOpeningTimeout];
  [self cancelResumeFallback];
}

#pragma mark - Display & audio

// libvlc's `scaleFactor` is not honored by the iOS vout module here ("Note
// that not all video outputs support scaling" — libvlc docs), so we drive
// resize by sizing `_videoOutputView` directly. libvlc aspect-fits into
// whatever bounds the drawable reports; `_videoView.clipsToBounds` crops
// cover overflow. Stretch uses `videoAspectRatio` (which IS honored).
- (void)applyDisplayOptions
{
  if (_mediaPlayer == nil) return;
  CGSize containerSize = self.bounds.size;
  if (containerSize.width <= 0 || containerSize.height <= 0) return;

  CGSize videoSize = _mediaPlayer.videoSize;
  CGRect frame = self.bounds;
  NSString *aspectOverride = nil;

  if (videoSize.width > 0 && videoSize.height > 0) {
    const CGFloat ar  = videoSize.width / videoSize.height;
    const CGFloat dar = containerSize.width / containerSize.height;

    switch (_desiredResizeMode) {
      case VlcPlayerResizeModeContain: {
        const CGSize fit = (dar < ar)
            ? CGSizeMake(containerSize.width, containerSize.width / ar)
            : CGSizeMake(containerSize.height * ar, containerSize.height);
        frame = CGRectMake((containerSize.width  - fit.width)  / 2,
                           (containerSize.height - fit.height) / 2,
                           fit.width, fit.height);
        break;
      }
      case VlcPlayerResizeModeCover: {
        const CGSize fill = (dar < ar)
            ? CGSizeMake(containerSize.height * ar, containerSize.height)
            : CGSizeMake(containerSize.width, containerSize.width / ar);
        frame = CGRectMake((containerSize.width  - fill.width)  / 2,
                           (containerSize.height - fill.height) / 2,
                           fill.width, fill.height);
        break;
      }
      case VlcPlayerResizeModeStretch:
        // Output view stays at container size; libvlc renders at this aspect.
        aspectOverride = [NSString stringWithFormat:@"%d:%d",
                          (int)containerSize.width, (int)containerSize.height];
        break;
      case VlcPlayerResizeModeOriginal: {
        // Native pixel size, centered. `videoSize` is in pixels.
        const CGFloat invScale = 1.0 / UIScreen.mainScreen.scale;
        const CGSize native = CGSizeMake(videoSize.width * invScale,
                                         videoSize.height * invScale);
        frame = CGRectMake((containerSize.width  - native.width)  / 2,
                           (containerSize.height - native.height) / 2,
                           native.width, native.height);
        break;
      }
    }
  }

  // Cache to skip no-op libvlc round-trips / UIKit layout.
  const BOOL aspectChanged = !(_appliedAspectOverride == aspectOverride ||
                               [_appliedAspectOverride isEqualToString:aspectOverride]);
  if (aspectChanged) {
    _mediaPlayer.videoAspectRatio = aspectOverride;
    _appliedAspectOverride = [aspectOverride copy];
  }
  if (!CGRectEqualToRect(_videoOutputView.frame, frame)) {
    _videoOutputView.autoresizingMask = UIViewAutoresizingNone;
    _videoOutputView.frame = frame;
  }
}

- (void)applyAudioOptions
{
  VLCAudio *audio = _mediaPlayer.audio;
  if (audio == nil) return;

  if (_appliedMuted != _desiredMuted) {
    audio.muted = _desiredMuted;
    _appliedMuted = _desiredMuted;
  }
  if (_appliedVolume != _desiredVolume) {
    // VLCKit audio volume is 0..200 (100 = unboosted). Map 0..1 → 0..100
    // so 1.0 means "as loud as the source".
    audio.volume = (int)(_desiredVolume * 100.0f);
    _appliedVolume = _desiredVolume;
  }
}

#pragma mark - Timeouts

- (void)scheduleOpeningTimeoutForGeneration:(NSUInteger)generation
                                      player:(VLCMediaPlayer *)player
                                         url:(NSURL *)url
{
  [self cancelOpeningTimeout];

  __weak __typeof(self) weakSelf = self;
  dispatch_block_t block = dispatch_block_create((dispatch_block_flags_t)0, ^{
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil ||
        strongSelf->_destroyed ||
        strongSelf->_desiredPaused ||
        strongSelf->_generation != generation ||
        strongSelf->_mediaPlayer != player ||
        ![strongSelf->_loadedURL isEqual:url]) {
      return;
    }
    if (player.state == VLCMediaPlayerStatePlaying || player.hasVideoOut) {
      return;
    }
    [strongSelf emitError:@"VLC playback failed to start within timeout" shouldStopPlayback:YES];
  });

  _openingTimeoutBlock = block;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kVLCOpeningTimeout * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), block);
}

- (void)scheduleResumeFallbackForGeneration:(NSUInteger)generation
{
  [self cancelResumeFallback];

  __weak __typeof(self) weakSelf = self;
  dispatch_block_t block = dispatch_block_create((dispatch_block_flags_t)0, ^{
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil ||
        strongSelf->_destroyed ||
        strongSelf->_desiredPaused ||
        strongSelf->_mediaPlayer == nil ||
        strongSelf->_generation != generation) {
      return;
    }
    if (strongSelf->_mediaPlayer.state == VLCMediaPlayerStatePlaying) {
      return;
    }
    strongSelf->_loadedURL = nil;
    [strongSelf syncPlayer];
  });

  _resumeFallbackBlock = block;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kVLCResumeFallbackDelay * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), block);
}

- (void)cancelOpeningTimeout
{
  if (_openingTimeoutBlock != nil) {
    dispatch_block_cancel(_openingTimeoutBlock);
    _openingTimeoutBlock = nil;
  }
}

- (void)cancelResumeFallback
{
  if (_resumeFallbackBlock != nil) {
    dispatch_block_cancel(_resumeFallbackBlock);
    _resumeFallbackBlock = nil;
  }
}

#pragma mark - App lifecycle

- (void)registerLifecycleObservers
{
  NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
  [center addObserver:self
             selector:@selector(handleAppDidEnterBackground:)
                 name:UIApplicationDidEnterBackgroundNotification
               object:nil];
  [center addObserver:self
             selector:@selector(handleAppDidBecomeActive:)
                 name:UIApplicationDidBecomeActiveNotification
               object:nil];
}

- (void)removeLifecycleObservers
{
  NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
  [center removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
  [center removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)handleAppDidEnterBackground:(__unused NSNotification *)notification
{
  if (_destroyed) {
    return;
  }

  [self invalidatePendingPlayback];
  _appliedPaused = YES;
  _backgroundDate = [NSDate date];

  // Don't touch drawable — keep libvlc's render pipeline configured.
  // pause() is enough to stop decoding/output while backgrounded.
  [_mediaPlayer pause];
}

- (void)handleAppDidBecomeActive:(__unused NSNotification *)notification
{
  if (_destroyed || _desiredPaused || _desiredURL == nil) {
    _backgroundDate = nil;
    return;
  }

  NSTimeInterval timeAway = _backgroundDate == nil ? 0 : [[NSDate date] timeIntervalSinceDate:_backgroundDate];
  _backgroundDate = nil;

  if (_mediaPlayer == nil || timeAway > kVLCBackgroundResumeThreshold) {
    _loadedURL = nil;
    [self syncPlayer];
    return;
  }

  [self playPlayer];
  [self scheduleResumeFallbackForGeneration:_generation];
}

#pragma mark - Events

- (std::shared_ptr<const VlcPlayerViewEventEmitter>)eventEmitter
{
  return std::static_pointer_cast<const VlcPlayerViewEventEmitter>(_eventEmitter);
}

- (void)emitLoadIfReady
{
  if (_hasEmittedLoad) return;
  VLCMediaPlayer *player = _mediaPlayer;
  if (player == nil) return;

  int64_t durationMs = (int64_t)player.media.length.intValue;
  CGSize videoSize = player.videoSize;
  int videoW = (int)videoSize.width;
  int videoH = (int)videoSize.height;
  // Wait for at least duration or dimensions; otherwise the payload is empty.
  if (durationMs <= 0 && (videoW == 0 || videoH == 0)) return;

  _hasEmittedLoad = YES;
  _loadedDurationMs = durationMs > 0 ? durationMs : 0;
  // Real video size is known now; cover's scale depends on it.
  [self applyDisplayOptions];
  auto emitter = [self eventEmitter];
  if (emitter == nullptr) return;
  emitter->onLoad({
    .duration = VLCClampInt32(durationMs),
    .videoWidth = videoW,
    .videoHeight = videoH,
  });
}

- (void)emitPlayingForURL:(NSURL *)url
{
  auto emitter = [self eventEmitter];
  if (emitter == nullptr) return;
  emitter->onPlaying({
    .url = url == nil ? "" : std::string(url.absoluteString.UTF8String),
  });
}

- (void)emitBufferIsBuffering:(BOOL)isBuffering percent:(float)percent
{
  auto emitter = [self eventEmitter];
  if (emitter == nullptr) return;
  emitter->onBuffer({
    .isBuffering = (bool)isBuffering,
    .percent = VLCClampFloat(percent, 0.0f, 100.0f),
  });
}

- (void)emitProgressCurrentTime:(int64_t)currentTime duration:(int64_t)duration percent:(float)percent
{
  auto emitter = [self eventEmitter];
  if (emitter == nullptr) return;
  emitter->onProgress({
    .currentTime = VLCClampInt32(currentTime),
    .duration = VLCClampInt32(duration),
    .percent = VLCClampFloat(percent, 0.0f, 100.0f),
  });
}

- (void)emitEndForURL:(NSURL *)url
{
  auto emitter = [self eventEmitter];
  if (emitter == nullptr) return;
  emitter->onEnd({
    .url = url == nil ? "" : std::string(url.absoluteString.UTF8String),
  });
}

- (void)emitError:(NSString *)message shouldStopPlayback:(BOOL)shouldStopPlayback
{
  if (shouldStopPlayback) {
    _desiredPaused = YES;
    [self releasePlayer];
  }

  RCTLogError(@"VlcPlayerView: %@", message);

  __weak __typeof(self) weakSelf = self;
  NSString *capturedMessage = [message copy];
  VLCRunOnMain(^{
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil || strongSelf->_destroyed) return;

    auto emitter = [strongSelf eventEmitter];
    if (emitter == nullptr) return;

    emitter->onError({
      .message = std::string(capturedMessage.UTF8String),
    });
  });
}

- (void)emitSnapshotResult:(int32_t)callId base64:(NSString *)base64 error:(NSString *)error
{
  auto emitter = [self eventEmitter];
  if (emitter == nullptr) return;
  emitter->onSnapshotResult({
    .callId = (int)callId,
    .base64 = base64 == nil ? "" : std::string(base64.UTF8String),
    .error = error == nil ? "" : std::string(error.UTF8String),
  });
}

#pragma mark - VLCKit notifications

- (void)handleStateChanged:(NSNotification *)notification
{
  VLCMediaPlayer *eventPlayer = notification.object;
  if (![eventPlayer isKindOfClass:[VLCMediaPlayer class]]) return;
  VLCMediaPlayerState newState = eventPlayer.state;

  __weak __typeof(self) weakSelf = self;
  VLCRunOnMain(^{
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil || strongSelf->_destroyed) return;
    if (strongSelf->_mediaPlayer != eventPlayer) return;  // stale

    switch (newState) {
      case VLCMediaPlayerStateBuffering:
        // Buffering signal comes from VLCEventCallback (real cache percent).
        break;

      case VLCMediaPlayerStatePlaying: {
        if (strongSelf->_desiredPaused || strongSelf->_backgroundDate != nil) {
          break;
        }
        strongSelf->_appliedPaused = NO;
        [strongSelf cancelOpeningTimeout];
        [strongSelf cancelResumeFallback];

        // Safety net for streams that skip the Buffering(100) ping.
        if (strongSelf->_isBufferingState) {
          strongSelf->_isBufferingState = NO;
          [strongSelf emitBufferIsBuffering:NO percent:100.0f];
        }
        [strongSelf emitLoadIfReady];
        [strongSelf emitPlayingForURL:strongSelf->_loadedURL];
        break;
      }

      case VLCMediaPlayerStatePaused:
      case VLCMediaPlayerStateStopped:
        if (strongSelf->_isBufferingState) {
          strongSelf->_isBufferingState = NO;
          [strongSelf emitBufferIsBuffering:NO percent:0.0f];
        }
        break;

      case VLCMediaPlayerStateError:
        [strongSelf emitError:@"VLC playback error occurred" shouldStopPlayback:YES];
        break;

      default:
        break;
    }
  });
}

// percent <100: in-progress; ≥100: complete. Mirrors Android handleBuffering.
- (void)handleLibVLCBufferingPercent:(float)percent
{
  if (_destroyed) return;
  if (percent < 100.0f) {
    if (!_isBufferingState) {
      _isBufferingState = YES;
    }
    [self emitBufferIsBuffering:YES percent:percent];
  } else {
    if (_isBufferingState) {
      _isBufferingState = NO;
      [self emitBufferIsBuffering:NO percent:100.0f];
    }
  }
}

// libvlc fires Stopping for both natural end and user-initiated stop;
// _userInitiatedStop is how we tell them apart.
- (void)handleLibVLCStopping
{
  if (_destroyed) return;
  if (_userInitiatedStop) {
    _userInitiatedStop = NO;
    return;
  }
  if (_mediaPlayer == nil) return;
  if (_mediaPlayer.state == VLCMediaPlayerStateError) return;
  if (_hasEmittedEnd) return;
  _hasEmittedEnd = YES;

  NSURL *url = _loadedURL;
  // libvlc never delivers a TimeChanged at exactly `length` — VOD ends with
  // time still short of the duration. Emit a synthetic 100% so consumers see
  // a clean tail before onEnd.
  if (_loadedDurationMs > 0) {
    [self emitProgressCurrentTime:_loadedDurationMs duration:_loadedDurationMs percent:100.0f];
  }
  [self emitEndForURL:url];
  if (_desiredRepeat && url != nil) {
    _loadedURL = nil;
    [self syncPlayer];
  }
}

// libvlc event thread → main. Use cached duration to avoid the
// `_mediaPlayer.media` race documented above.
- (void)handleLibVLCTimeChanged:(int64_t)timeMs
{
  if (_destroyed) return;
  if (_mediaPlayer == nil) return;
  int64_t durationMs = _loadedDurationMs;
  if (durationMs <= 0) return;  // live stream or pre-load
  int64_t safeTime = timeMs < 0 ? 0 : timeMs;
  float percent = (float)(((double)safeTime / (double)durationMs) * 100.0);
  [self emitProgressCurrentTime:safeTime duration:durationMs percent:percent];
}

// Refresh the duration cache. Fires after onLoad if dimensions arrived
// first (videoSize → onLoad with duration=0 → length resolves later),
// and on DASH/HLS streams whose length grows during playback.
- (void)handleLibVLCLengthChanged:(int64_t)lengthMs
{
  if (_destroyed) return;
  _loadedDurationMs = lengthMs > 0 ? lengthMs : 0;
}

#pragma mark - Fabric registration

Class<RCTComponentViewProtocol> VlcPlayerViewCls(void)
{
  return VlcPlayerView.class;
}

@end
