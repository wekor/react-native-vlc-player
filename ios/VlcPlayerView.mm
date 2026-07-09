#import "VlcPlayerView.h"

#import <AVFoundation/AVFoundation.h>
#import <React/RCTAssert.h>
#import <React/RCTLog.h>
#import <VLCKit/VLCKit.h>

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

// nil-aware string equality. Two nils are equal; nil and non-nil are not.
static BOOL VLCEqualStrings(NSString *a, NSString *b)
{
  if (a == b) return YES;
  if (a == nil || b == nil) return NO;
  return [a isEqualToString:b];
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

// ROOT CAUSE of "audio but no video after backgrounding": the a20 vout
// renders through an AVSampleBufferDisplayLayer, which iOS moves to Failed
// when the app backgrounds — and upstream never flushes it (verified in
// vlc@fe6e76a9 VLCSampleBufferDisplay.m: enqueueSampleBuffer with zero status
// handling), so every frame after foregrounding is silently dropped. The
// layer lives inside OUR view tree (VLCSampleBufferDisplayView's layerClass),
// so we flush it ourselves on foreground; flush resets Failed → rendering
// resumes. Public AVFoundation API on our own hierarchy.
static void VLCFlushFailedSampleBufferLayers(UIView *root)
{
  if ([root.layer isKindOfClass:[AVSampleBufferDisplayLayer class]]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AVSampleBufferDisplayLayer *layer = (AVSampleBufferDisplayLayer *)root.layer;
    if (layer.status == AVQueuedSampleBufferRenderingStatusFailed) {
      [layer flush];
    }
#pragma clang diagnostic pop
  }
  for (UIView *subview in root.subviews) {
    VLCFlushFailedSampleBufferLayers(subview);
  }
}

// Ports VLC-iOS treats as "external audio playback device" — wired
// headphones and any Bluetooth/USB audio sink.
static BOOL VLCRouteHasExternalAudioOutput(AVAudioSessionRouteDescription *route)
{
  for (AVAudioSessionPortDescription *port in route.outputs) {
    NSString *type = port.portType;
    if ([type isEqualToString:AVAudioSessionPortHeadphones] ||
        [type isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
        [type isEqualToString:AVAudioSessionPortBluetoothHFP] ||
        [type isEqualToString:AVAudioSessionPortBluetoothLE] ||
        [type isEqualToString:AVAudioSessionPortUSBAudio]) {
      return YES;
    }
  }
  return NO;
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

@interface VlcPlayerView () <RCTVlcPlayerViewViewProtocol, VLCMediaPlayerDelegate>
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
  float _desiredRate;
  BOOL _desiredRepeat;
  NSArray<NSString *> *_desiredInitOptions;
  NSArray<NSString *> *_desiredMediaOptions;
  VlcPlayerResizeMode _desiredResizeMode;
  BOOL _desiredHardwareEnabled;
  NSString *_desiredReferer;     // nil / empty → don't inject :http-referrer=
  NSString *_desiredUserAgent;   // nil / empty → don't inject :http-user-agent=

  // Loaded (in VLC)
  NSURL *_loadedURL;
  NSArray<NSString *> *_loadedMediaOptions;
  BOOL _loadedHardwareEnabled;
  BOOL _loadedRepeat;
  NSString *_loadedReferer;
  NSString *_loadedUserAgent;

  // Applied (pushed to player)
  BOOL _appliedPaused;
  BOOL _appliedMuted;
  float _appliedVolume;
  float _appliedRate;
  NSString *_appliedAspectOverride;

  BOOL _destroyed;
  // Set when an error stopped playback; cleared only by a new source or
  // reload(). Keeps `_desired*` a pure props mirror — the error path must
  // not fake a paused prop, or any unrelated prop update would silently
  // retry the failing stream.
  BOOL _haltedByError;
  BOOL _hasEmittedLoad;
  BOOL _hasEmittedEnd;
  BOOL _isBufferingState;
  // While an audio interruption is in flight, recovery belongs to the
  // interruption handler alone — didBecomeActive must not arm its
  // reload-fallback, whose media reload showed up as "connecting AirPods
  // restarts the video".
  BOOL _audioInterruptionActive;
  NSDate *_backgroundDate;
  NSUInteger _generation;
  NSUInteger _playIssuedGeneration;
  dispatch_block_t _openingTimeoutBlock;
  dispatch_block_t _resumeFallbackBlock;

  // Cached at emitLoadIfReady so the libvlc time-changed handler can compute
  // percent without touching `_mediaPlayer.media` (which races with media swaps).
  int64_t _loadedDurationMs;

  // Position-restore net: audio route changes (e.g. connecting AirPods) can
  // kill the input, after which any play()/reload restarts the media at zero.
  // We track the last playback position and restore it on the next Playing.
  int64_t _lastTimeMs;
  int64_t _pendingRestoreTimeMs;
  BOOL _mediaEverPlayed;
  NSURL *_lastLoadedURL;
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
    _desiredHardwareEnabled = YES;
    _loadedHardwareEnabled = YES;
    _desiredReferer = nil;
    _desiredUserAgent = nil;
    _loadedReferer = nil;
    _loadedUserAgent = nil;
    _desiredRate = 1.0f;
    _appliedPaused = YES;
    _appliedMuted = NO;
    _appliedVolume = 1.0f;
    _appliedRate = 1.0f;

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

  NSURL *previousURL = _desiredURL;
  _desiredURL = VLCURLFromString(VLCStringFromStdString(newProps.url));
  // A new source is the declarative recovery from the error-halted state.
  if (_haltedByError &&
      !(_desiredURL == previousURL || [_desiredURL isEqual:previousURL])) {
    _haltedByError = NO;
  }
  _desiredPaused = newProps.paused;
  _desiredMuted = newProps.muted;
  {
    float vol = newProps.volume;
    if (vol < 0.0f) vol = 0.0f;
    if (vol > 1.0f) vol = 1.0f;
    _desiredVolume = vol;
  }
  _desiredRate = newProps.rate > 0.0f ? newProps.rate : 1.0f;
  _desiredRepeat = newProps.repeat;
  _desiredInitOptions = VLCStringsFromVector(newProps.initOptions);
  _desiredMediaOptions = VLCStringsFromVector(newProps.mediaOptions);
  _desiredResizeMode = VLCResizeModeFromString(VLCStringFromStdString(newProps.resizeMode));
  _desiredHardwareEnabled = newProps.hardwareDecoding;
  _desiredReferer = VLCTrimmedString(VLCStringFromStdString(newProps.referer));
  _desiredUserAgent = VLCTrimmedString(VLCStringFromStdString(newProps.userAgent));

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
    [self emitSnapshotResult:callId path:nil error:@"Player not ready"];
    return;
  }
  NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
      [NSString stringWithFormat:@"vlc-snap-%d-%@.png", callId, NSUUID.UUID.UUIDString]];

  @try {
    // libvlc_video_take_snapshot is sync; w=0 h=0 → source dimensions.
    [_mediaPlayer saveVideoSnapshotAt:path withWidth:0 andHeight:0];
  } @catch (NSException *exception) {
    [self emitSnapshotResult:callId path:nil error:VLCExceptionReason(exception)];
    return;
  }

  // The file stays in tmp for the consumer (JS gets a file:// URI); the OS
  // reclaims tmp storage, and callers copy it out if they need persistence.
  NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
  if (attributes.fileSize == 0) {
    [self emitSnapshotResult:callId path:nil error:@"Snapshot file unavailable"];
    return;
  }
  [self emitSnapshotResult:callId
                      path:[NSURL fileURLWithPath:path].absoluteString
                     error:nil];
}

- (void)reload
{
  if (_destroyed || _desiredURL == nil) return;
  _haltedByError = NO;
  _desiredPaused = NO;
  _lastTimeMs = 0; // explicit reconnect starts clean
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
  // it at our (still-zero) bounds left libvlc in a broken state. It keeps
  // the screen-sized frame until the first applyDisplayOptions pass with
  // real bounds; _videoView clips the overflow in the meantime.
  _videoOutputView = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
  _videoOutputView.backgroundColor = UIColor.blackColor;
  [_videoView addSubview:_videoOutputView];

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
  _loadedRepeat = NO;
  _desiredInitOptions = @[];
  _desiredMediaOptions = @[];
  _desiredResizeMode = VlcPlayerResizeModeContain;
  _desiredHardwareEnabled = YES;
  _loadedHardwareEnabled = YES;
  _desiredReferer = nil;
  _desiredUserAgent = nil;
  _loadedReferer = nil;
  _loadedUserAgent = nil;
  _desiredRate = 1.0f;
  _appliedAspectOverride = nil;
  _appliedPaused = YES;
  _appliedMuted = NO;
  _appliedVolume = 1.0f;
  _appliedRate = 1.0f;
  _backgroundDate = nil;
  _haltedByError = NO;
  _hasEmittedLoad = NO;
  _hasEmittedEnd = NO;
  _isBufferingState = NO;
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
  [self applyPlaybackRate];

  if (_desiredURL == nil) {
    [self releasePlayer];
    return;
  }

  // Error-halted: the player is already released; don't rebuild until a new
  // source or reload() clears the flag.
  if (_haltedByError) {
    return;
  }

  // One player per media: a20 crashes when media is hot-swapped on a live
  // player (vlc_mutex_trylock on a destroyed lock — upstream's own examples
  // never exercise that path), so ANY media-defining change retires the whole
  // player and starts a fresh one. releasePlayer drains the old one safely.
  if (_mediaPlayer != nil) {
    BOOL needsMedia =
        _loadedURL == nil ||
        ![_loadedURL isEqual:_desiredURL] ||
        ![_loadedMediaOptions isEqualToArray:_desiredMediaOptions] ||
        _loadedHardwareEnabled != _desiredHardwareEnabled ||
        _loadedRepeat != _desiredRepeat ||
        !VLCEqualStrings(_loadedReferer, _desiredReferer) ||
        !VLCEqualStrings(_loadedUserAgent, _desiredUserAgent) ||
        ![_playerInitOptions isEqualToArray:_desiredInitOptions];
    if (needsMedia) {
      [self releasePlayer];
    }
  }

  if (_mediaPlayer == nil) {
    if (![self createPlayer]) {
      return;
    }
    if (![self loadDesiredMedia]) {
      return;
    }
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

    // a20 removed -initWithOptions: from the public surface (it only exists
    // in a private category; the official DropIn example uses plain -init).
    // Instance-level options go through a dedicated VLCLibrary instead.
    VLCMediaPlayer *player;
    if (_desiredInitOptions.count == 0) {
      player = [[VLCMediaPlayer alloc] init];
    } else {
      VLCLibrary *library = [[VLCLibrary alloc] initWithOptions:_desiredInitOptions];
      player = library == nil ? nil : [[VLCMediaPlayer alloc] initWithLibrary:library];
    }

    if (player == nil) {
      [self emitError:@"Failed to create VLC player: VLCKit returned nil" shouldStopPlayback:YES];
      return NO;
    }

    // Set drawable ONCE — never reassign during the player's lifetime.
    player.drawable = _drawable;

    // a20 exposes everything we need through the official delegate (buffering
    // percent included) — the a19-era private-ivar hook and raw libvlc event
    // bridge are gone. Delegate callbacks arrive on the main thread.
    player.delegate = self;

    _mediaPlayer = player;
    _playerInitOptions = [_desiredInitOptions copy];
    _appliedPaused = YES;
    _appliedRate = 1.0f;
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
    // The player is always freshly created for this media (see syncPlayer) —
    // a20 crashes when media is hot-swapped on a live player, so we never do.
    VLCMedia *media = [VLCMedia mediaWithURL:url];
    if (media == nil) {
      [self emitError:@"Failed to create VLC media" shouldStopPlayback:YES];
      return NO;
    }

    for (NSString *option in _desiredMediaOptions) {
      [media addOption:option];
    }
    // Seamless looping happens inside libvlc's input layer — no per-loop
    // events, no re-open of network sources. libvlc can't cancel it on a
    // running input, so toggling the prop reloads the media (repeat is in
    // the needsMedia diff, same semantics as hardwareDecoding).
    // handleLibVLCStopping's repeat branch is the safety net for streams
    // where input-repeat doesn't engage.
    if (_desiredRepeat) {
      [media addOption:@":input-repeat=65535"];
    }
    // Force software decoding by demoting hardware decoder modules: list
    // avcodec first so libvlc picks FFmpeg software decoder, then fall back
    // to "all" for codecs avcodec doesn't cover. Matches VLC-iOS (which ships
    // against the same VLCKit alpha) — chosen over libvlc 4's `:no-hw-dec`
    // core flag because the official app's path has more line-of-evidence.
    // Applied AFTER user mediaOptions so this prop is authoritative.
    if (!_desiredHardwareEnabled) {
      [media addOption:@":codec=avcodec,all"];
    }
    // HTTP Referer / User-Agent. libvlc only supports these two HTTP headers
    // at the access-module level (see modules/access/http/access.c — it reads
    // only `http-referrer` and `http-user-agent`). Other headers cannot be
    // injected. Applied after user mediaOptions so the source-object form
    // wins over a manual `mediaOptions` override.
    if (_desiredReferer.length > 0) {
      [media addOption:[NSString stringWithFormat:@":http-referrer=%@", _desiredReferer]];
    }
    if (_desiredUserAgent.length > 0) {
      [media addOption:[NSString stringWithFormat:@":http-user-agent=%@", _desiredUserAgent]];
    }
    RCTLogInfo(@"VlcPlayerView: loading media %@ with mediaOptions [%@]",
               VLCRedactedURLString(url),
               [_desiredMediaOptions componentsJoinedByString:@", "]);

    // Same-URL reload (resume fallback, background return, route recovery):
    // arm a position restore so the viewer continues where they were. A real
    // source change starts clean at zero.
    if ([url isEqual:_lastLoadedURL] && _lastTimeMs > 1500) {
      _pendingRestoreTimeMs = _lastTimeMs;
    } else {
      _pendingRestoreTimeMs = 0;
      _lastTimeMs = 0;
    }
    _mediaEverPlayed = NO;
    _lastLoadedURL = url;

    player.media = media;
    _loadedURL = url;
    _loadedMediaOptions = [_desiredMediaOptions copy];
    _loadedHardwareEnabled = _desiredHardwareEnabled;
    _loadedRepeat = _desiredRepeat;
    _loadedReferer = [_desiredReferer copy];
    _loadedUserAgent = [_desiredUserAgent copy];
    _appliedPaused = YES;
    // Force a rate re-push for the new media — don't trust libvlc to carry
    // a non-default rate across media changes.
    _appliedRate = 1.0f;
    [self applyDisplayOptions];
    [self applyAudioOptions];
    [self applyPlaybackRate];
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

  // play() on a Stopped player restarts the media at zero (route changes like
  // connecting AirPods can stop a live input) — arm a position restore first.
  VLCMediaPlayerState state = player.state;
  if (_mediaEverPlayed && state == VLCMediaPlayerStateStopped && _lastTimeMs > 1500) {
    _pendingRestoreTimeMs = _lastTimeMs;
  }

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
  // Every caller is on main (props, commands, notifications hopped via
  // VLCRunOnMain, dealloc after prepareForRecycle). A dispatch_sync hop here
  // would risk deadlock and, on the dealloc path, capturing self in a block
  // is object-resurrection UB — so assert instead of hopping.
  RCTAssertMainQueue();

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

  player.delegate = nil;

  @try {
    // a20's pause is async on a background queue — the a19 pause-before-stop
    // dance is gone. Don't `player.media = nil` here: stop is async and
    // clearing media while events drain asserts on a NULL retain.
    player.drawable = nil;
    [player stop];
  } @catch (NSException *exception) {
    RCTLogWarn(@"VlcPlayerView: failed to release VLC player cleanly: %@", VLCExceptionReason(exception));
  }

  // The a20 hot-swap crash (vlc_mutex_trylock on a destroyed lock) hit when
  // the player was released while its async stop was still draining. Keep the
  // doomed player alive until the teardown has safely finished.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   (void)player;
                 });
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

// VLCKit's `rate` is a request — live streams / some protocols ignore it
// (see VLCMediaPlayer.h). Cache to skip no-op round-trips, like volume.
- (void)applyPlaybackRate
{
  if (_mediaPlayer == nil) return;
  if (_appliedRate == _desiredRate) return;
  _mediaPlayer.rate = _desiredRate;
  _appliedRate = _desiredRate;
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
  [center addObserver:self
             selector:@selector(handleAudioSessionInterruption:)
                 name:AVAudioSessionInterruptionNotification
               object:AVAudioSession.sharedInstance];
  [center addObserver:self
             selector:@selector(handleAudioSessionRouteChange:)
                 name:AVAudioSessionRouteChangeNotification
               object:AVAudioSession.sharedInstance];
}

- (void)removeLifecycleObservers
{
  NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
  [center removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
  [center removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
  [center removeObserver:self name:AVAudioSessionInterruptionNotification object:AVAudioSession.sharedInstance];
  [center removeObserver:self name:AVAudioSessionRouteChangeNotification object:AVAudioSession.sharedInstance];
}

- (void)handleAppDidEnterBackground:(__unused NSNotification *)notification
{
  if (_destroyed) {
    return;
  }

  [self invalidatePendingPlayback];
  _appliedPaused = YES;
  // Real backgrounding supersedes any in-flight audio interruption — iOS
  // often never delivers the interruption-Ended, and a stuck flag would
  // block the didBecomeActive recovery forever.
  _audioInterruptionActive = NO;
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
  // Audio interruption in flight while the app stayed active (AirPods
  // connect, call UI): recovery is the interruption handler's job. But a
  // genuine background return outranks the flag — iOS doesn't guarantee an
  // interruption-Ended, and a wedged flag here was exactly the "black screen
  // after app switch" regression (worked in 0.2.0, broken by this flag).
  if (_audioInterruptionActive) {
    if (_backgroundDate == nil) {
      return;
    }
    _audioInterruptionActive = NO;
  }

  NSTimeInterval timeAway = _backgroundDate == nil ? 0 : [[NSDate date] timeIntervalSinceDate:_backgroundDate];
  _backgroundDate = nil;

  // Revive the vout's sample-buffer layer if backgrounding failed it — must
  // happen before resuming, or video stays black while audio plays.
  VLCFlushFailedSampleBufferLayers(_videoOutputView);

  if (_mediaPlayer == nil || timeAway > kVLCBackgroundResumeThreshold) {
    _loadedURL = nil;
    [self syncPlayer];
    return;
  }

  [self playPlayer];
  [self scheduleResumeFallbackForGeneration:_generation];
}

#pragma mark - Audio session
// AVAudioSession notifications arrive on a private queue — handlers hop to
// main before touching any state.

// Phone call / alarm / Siri. Mirrors VLC-iOS: pause when the interruption
// begins, resume only when the system explicitly says ShouldResume (call
// ended and iOS considers us entitled to continue). The generation bump on
// pause is what re-arms playPlayer for that resume; if we never paused here,
// the play-issuance gate keeps a stray ShouldResume from restarting a
// user-paused or finished player.
- (void)handleAudioSessionInterruption:(NSNotification *)notification
{
  NSDictionary *userInfo = notification.userInfo;
  NSUInteger type = [userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
  NSUInteger options = [userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];

  __weak __typeof(self) weakSelf = self;
  VLCRunOnMain(^{
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil || strongSelf->_destroyed) return;

    if (type == AVAudioSessionInterruptionTypeBegan) {
      // Already backgrounded (the interruption can be delivered AFTER
      // DidEnterBackground): the background handler owns this pause; setting
      // the flag here would wedge it — nothing clears it until foreground.
      if (strongSelf->_backgroundDate != nil) {
        return;
      }
      strongSelf->_audioInterruptionActive = YES;
      if (strongSelf->_mediaPlayer.isPlaying) {
        [strongSelf invalidatePendingPlayback];
        strongSelf->_appliedPaused = YES;
        [strongSelf->_mediaPlayer pause];
      }
      return;
    }
    strongSelf->_audioInterruptionActive = NO;
    if (type == AVAudioSessionInterruptionTypeEnded &&
        (options & AVAudioSessionInterruptionOptionShouldResume) != 0 &&
        !strongSelf->_desiredPaused &&
        strongSelf->_backgroundDate == nil) {
      if (strongSelf->_mediaPlayer.state == VLCMediaPlayerStatePaused) {
        // Player survived paused — seamless resume, no reload, no flash.
        [strongSelf playPlayer];
      } else if (strongSelf->_mediaEverPlayed) {
        // The route change killed the input; a blind play() would restart at
        // zero. Reload the same URL — loadDesiredMedia arms the position
        // restore, so playback continues where it was.
        strongSelf->_loadedURL = nil;
        [strongSelf syncPlayer];
      }
    }
  });
}

// Headphones unplugged / Bluetooth audio dropped: iOS convention (and
// VLC-iOS behavior) is to pause instead of blasting the built-in speaker.
// Deliberately no auto-resume when a device comes back — the user decides.
- (void)handleAudioSessionRouteChange:(NSNotification *)notification
{
  NSDictionary *userInfo = notification.userInfo;
  NSUInteger reason = [userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
  if (reason != AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
    return;
  }
  AVAudioSessionRouteDescription *previousRoute = userInfo[AVAudioSessionRouteChangePreviousRouteKey];
  if (previousRoute != nil && !VLCRouteHasExternalAudioOutput(previousRoute)) {
    return;
  }

  __weak __typeof(self) weakSelf = self;
  VLCRunOnMain(^{
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil || strongSelf->_destroyed) return;
    if (!strongSelf->_mediaPlayer.isPlaying) return;
    [strongSelf invalidatePendingPlayback];
    strongSelf->_appliedPaused = YES;
    [strongSelf->_mediaPlayer pause];
  });
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
    _haltedByError = YES;
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

- (void)emitSnapshotResult:(int32_t)callId path:(NSString *)path error:(NSString *)error
{
  auto emitter = [self eventEmitter];
  if (emitter == nullptr) return;
  emitter->onSnapshotResult({
    .callId = (int)callId,
    .path = path == nil ? "" : std::string(path.UTF8String),
    .error = error == nil ? "" : std::string(error.UTF8String),
  });
}

#pragma mark - VLCKit notifications

// VLCMediaPlayerDelegate — callbacks arrive on libvlc's event thread (see the
// note on mediaPlayerBufferingChanged:), hence the VLCRunOnMain hop. The
// delegate is per-player and nil'ed before release, so no stale-event checks
// beyond _destroyed are needed.
- (void)mediaPlayerStateChanged:(VLCMediaPlayerState)newState
{
  __weak __typeof(self) weakSelf = self;
  VLCRunOnMain(^{
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil || strongSelf->_destroyed) return;

    switch (newState) {
      // a20's enum is exactly: Stopped/Stopping/Opening/Playing/Paused/Error
      // (verified against VLCMediaPlayer-a20.m's state-name table). Buffering
      // is no longer a state — it arrives via mediaPlayerBufferingChanged:.
      case VLCMediaPlayerStateStopping:
        [strongSelf handleLibVLCStopping];
        break;

      case VLCMediaPlayerStatePlaying: {
        if (strongSelf->_desiredPaused || strongSelf->_backgroundDate != nil) {
          break;
        }
        strongSelf->_appliedPaused = NO;
        strongSelf->_mediaEverPlayed = YES;
        [strongSelf attemptPositionRestore];
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

// a20 reports buffering as [0,1]; internal handlers keep the 0–100 scale.
// VLCRunOnMain is REQUIRED, not defensive: VLCKit 4's default events
// configuration has no dispatch queue, so delegate callbacks run inline on
// libvlc's event thread (VLCLibrary.m +load → VLCEventsDefaultConfiguration
// → VLCEventsHandler executes the block in place).
- (void)mediaPlayerBufferingChanged:(float)buffering
{
  __weak __typeof(self) weakSelf = self;
  VLCRunOnMain(^{
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil || strongSelf->_destroyed) return;
    [strongSelf handleLibVLCBufferingPercent:buffering * 100.0f];
  });
}

- (void)mediaPlayerTimeChanged:(NSNotification *)notification
{
  __weak __typeof(self) weakSelf = self;
  VLCRunOnMain(^{
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil || strongSelf->_destroyed || strongSelf->_mediaPlayer == nil) return;
    [strongSelf handleLibVLCTimeChanged:(int64_t)strongSelf->_mediaPlayer.time.value.longLongValue];
  });
}

- (void)mediaPlayerLengthChanged:(int64_t)length
{
  __weak __typeof(self) weakSelf = self;
  VLCRunOnMain(^{
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil || strongSelf->_destroyed) return;
    [strongSelf handleLibVLCLengthChanged:length];
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

// Natural end of stream. Our own teardown stops can't reach here: the
// delegate is nil'ed before releasePlayer issues its stop.
- (void)handleLibVLCStopping
{
  if (_destroyed) return;
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
    _lastTimeMs = 0; // the loop restart must begin at zero, not near the end
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
  _lastTimeMs = timeMs < 0 ? 0 : timeMs;
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
  // Playing often arrives before the duration does; retry the restore here.
  [self attemptPositionRestore];
}

// Restore the pre-reload position (VOD only — live has no position). Keeps
// the pending value until BOTH playing and duration are known; consuming it
// early was why repeat-toggle reloads restarted from zero.
- (void)attemptPositionRestore
{
  if (_pendingRestoreTimeMs <= 0 || _loadedDurationMs <= 0) return;
  if (!_mediaPlayer.isPlaying) return;
  int64_t restoreMs = _pendingRestoreTimeMs;
  _pendingRestoreTimeMs = 0;
  if (restoreMs < _loadedDurationMs) {
    _mediaPlayer.time = [VLCTime timeWithInt:(int)restoreMs];
  }
}

#pragma mark - Fabric registration

Class<RCTComponentViewProtocol> VlcPlayerViewCls(void)
{
  return VlcPlayerView.class;
}

@end
