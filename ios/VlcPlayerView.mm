#import "VlcPlayerView.h"

#import <MobileVLCKit/MobileVLCKit.h>

#import <React/RCTConversions.h>
#import <react/renderer/components/VlcPlayerViewSpec/ComponentDescriptors.h>
#import <react/renderer/components/VlcPlayerViewSpec/EventEmitters.h>
#import <react/renderer/components/VlcPlayerViewSpec/Props.h>
#import <react/renderer/components/VlcPlayerViewSpec/RCTComponentViewHelpers.h>

using namespace facebook::react;

/// libvlc never reports "connection failed" for an unreachable URL — it sits
/// in Opening forever. Cap the wait and surface an error ourselves.
static const NSTimeInterval kOpeningTimeoutSeconds = 8.0;

/// MobileVLCKit 3.x's live555 stack can take 10–50s to produce the first
/// frame from LAN RTSP sources on modern iOS (slow source-address discovery
/// under the Local Network permission). Give RTSP a much longer leash so the
/// generic timeout doesn't misreport "slow" as "unreachable".
static const NSTimeInterval kRtspOpeningTimeoutSeconds = 60.0;

/// saveVideoSnapshotAt: has no failure callback; a request that produced no
/// mediaPlayerSnapshot: notification within this window is reported as failed.
static const NSTimeInterval kSnapshotTimeoutSeconds = 3.0;

static NSArray<NSString *> *VlcStringArray(const std::vector<std::string> &vector)
{
  NSMutableArray<NSString *> *array = [NSMutableArray arrayWithCapacity:vector.size()];
  for (const auto &item : vector) {
    [array addObject:RCTNSStringFromString(item)];
  }
  return array;
}

/// Accepts anything libvlc can open: URLs with a scheme pass through,
/// bare paths become file:// URLs.
static NSURL *VlcSourceURL(NSString *source)
{
  if (source.length == 0) {
    return nil;
  }
  NSURL *url = [NSURL URLWithString:source];
  if (url != nil && url.scheme.length > 0) {
    return url;
  }
  if ([source hasPrefix:@"/"]) {
    return [NSURL fileURLWithPath:source];
  }
  // Scheme-less or containing characters URLWithString rejects — best effort.
  NSString *escaped =
      [source stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
  return escaped ? [NSURL URLWithString:escaped] : nil;
}

/// libvlc 3's stop is synchronous — it joins the input thread, which can take
/// tens of seconds when live555 is wedged mid-open (see the RTSP multicast
/// entitlement saga). Doomed sessions are drained here, never on main.
static dispatch_queue_t VlcTeardownQueue(void)
{
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("com.vlcplayer.session-teardown", DISPATCH_QUEUE_SERIAL);
  });
  return queue;
}

@interface VlcPlayerView () <RCTVlcPlayerViewViewProtocol, VLCMediaPlayerDelegate, VLCMediaListPlayerDelegate>
@end

@implementation VlcPlayerView {
  // --- Player (one session per media; swapped-out sessions drain off-main) ---
  VLCMediaListPlayer *_listPlayer;
  VLCMediaPlayer *_player; // == _listPlayer.mediaPlayer
  VLCMedia *_currentMedia; // kept so a drain can parseStop the async parse
  UIView *_videoView; // libvlc drawable; VLC-iOS's _actualVideoOutputView equivalent

  // --- Desired state (what props say) ---
  NSString *_desiredUrl;
  NSString *_desiredReferer;
  NSString *_desiredUserAgent;
  NSArray<NSString *> *_desiredInitOptions;
  NSArray<NSString *> *_desiredMediaOptions;
  BOOL _desiredHardwareDecoding;
  BOOL _desiredPaused;
  BOOL _desiredMuted;
  float _desiredVolume;
  float _desiredRate;
  BOOL _desiredRepeat;
  NSString *_desiredResizeMode;

  // --- Reconciliation flags (set by updateProps, consumed by -reconcile) ---
  BOOL _needsPlayerRebuild;
  BOOL _needsMediaReload;
  BOOL _needsRuntimeApply;

  // --- Loaded/session state for the current media ---
  BOOL _hasMedia; // a media list is loaded into the list player
  BOOL _mediaStarted; // playback of the current media was kicked off
  BOOL _loadEmitted;
  BOOL _playingEmitted;
  BOOL _isBuffering;
  NSTimer *_openingTimer;

  // --- Applied state (what was actually pushed to the player) ---
  NSNumber *_appliedPaused; // nil = not applied yet for this media
  NSString *_appliedResizeKey; // resize mode + sizes it was computed for

  // --- Snapshot requests, FIFO-matched to mediaPlayerSnapshot: callbacks ---
  NSMutableArray<NSDictionary *> *_pendingSnapshots; // {callId: NSNumber, path: NSString}

  // --- App lifecycle ---
  BOOL _resumeOnForeground;
}

+ (ComponentDescriptorProvider)componentDescriptorProvider
{
  return concreteComponentDescriptorProvider<VlcPlayerViewComponentDescriptor>();
}

- (instancetype)initWithFrame:(CGRect)frame
{
  if (self = [super initWithFrame:frame]) {
    static const auto defaultProps = std::make_shared<const VlcPlayerViewProps>();
    _props = defaultProps;

    [self resetDesiredStateToDefaults];
    _pendingSnapshots = [NSMutableArray array];

    // Plain UIView drawable, VLC-iOS style: black canvas, no touch handling
    // (libvlc's vout view must never swallow React gestures), autoresized so
    // libvlc's injected subviews track our size. Starts at screen size like
    // VLC-iOS's off-screen bootstrap view — the drawable must never be
    // zero-sized when the player is created, and Fabric may create us with an
    // empty frame before layout.
    _videoView = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    _videoView.backgroundColor = UIColor.blackColor;
    _videoView.userInteractionEnabled = NO;
    _videoView.autoresizesSubviews = YES;
    self.contentView = _videoView;

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self
               selector:@selector(applicationDidEnterBackground:)
                   name:UIApplicationDidEnterBackgroundNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(applicationWillEnterForeground:)
                   name:UIApplicationWillEnterForegroundNotification
                 object:nil];
  }
  return self;
}

- (void)dealloc
{
  [NSNotificationCenter.defaultCenter removeObserver:self];
  [self teardownPlayer];
}

- (void)resetDesiredStateToDefaults
{
  // Mirrors the codegen prop defaults in VlcPlayerViewNativeComponent.ts.
  _desiredUrl = @"";
  _desiredReferer = @"";
  _desiredUserAgent = @"";
  _desiredInitOptions = @[];
  _desiredMediaOptions = @[];
  _desiredHardwareDecoding = YES;
  _desiredPaused = NO;
  _desiredMuted = NO;
  _desiredVolume = 1.0f;
  _desiredRate = 1.0f;
  _desiredRepeat = NO;
  _desiredResizeMode = @"contain";
}

#pragma mark - Props

- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps
{
  const auto &prev = *std::static_pointer_cast<VlcPlayerViewProps const>(_props);
  const auto &next = *std::static_pointer_cast<VlcPlayerViewProps const>(props);

  if (next.initOptions != prev.initOptions) {
    _desiredInitOptions = VlcStringArray(next.initOptions);
    _needsPlayerRebuild = YES;
  }

  if (next.url != prev.url || next.referer != prev.referer || next.userAgent != prev.userAgent ||
      next.mediaOptions != prev.mediaOptions || next.hardwareDecoding != prev.hardwareDecoding) {
    _desiredUrl = RCTNSStringFromString(next.url);
    _desiredReferer = RCTNSStringFromString(next.referer);
    _desiredUserAgent = RCTNSStringFromString(next.userAgent);
    _desiredMediaOptions = VlcStringArray(next.mediaOptions);
    _desiredHardwareDecoding = next.hardwareDecoding;
    _needsMediaReload = YES;
  }

  if (next.paused != prev.paused || next.muted != prev.muted || next.volume != prev.volume ||
      next.rate != prev.rate || next.repeat != prev.repeat || next.resizeMode != prev.resizeMode) {
    _desiredPaused = next.paused;
    _desiredMuted = next.muted;
    _desiredVolume = next.volume;
    _desiredRate = next.rate;
    _desiredRepeat = next.repeat;
    _desiredResizeMode = RCTNSStringFromString(next.resizeMode);
    _needsRuntimeApply = YES;
  }

  [super updateProps:props oldProps:oldProps];
  [self reconcile];
}

/// Single reconciliation point: prop setters only record desired state; the
/// player is touched here, once per props batch.
- (void)reconcile
{
  if (_needsPlayerRebuild) {
    _needsPlayerRebuild = NO;
    [self teardownPlayer];
    _needsMediaReload = _desiredUrl.length > 0;
  }
  if (_needsMediaReload) {
    _needsMediaReload = NO;
    [self loadMedia];
    _needsRuntimeApply = YES;
  }
  if (_needsRuntimeApply) {
    _needsRuntimeApply = NO;
    [self applyRuntimeState];
  }
}

#pragma mark - Player lifecycle

- (void)ensurePlayer
{
  if (_listPlayer != nil) {
    return;
  }
  // The drawable must be handed over at construction time: VLC-iOS notes that
  // video decoding permanently fails when no view is available on init.
  if (_desiredInitOptions.count > 0) {
    _listPlayer = [[VLCMediaListPlayer alloc] initWithOptions:_desiredInitOptions andDrawable:_videoView];
  } else {
    _listPlayer = [[VLCMediaListPlayer alloc] initWithDrawable:_videoView];
  }
  _listPlayer.delegate = self;
  _player = _listPlayer.mediaPlayer;
  _player.delegate = self;
}

- (void)teardownPlayer
{
  [self cancelOpeningTimer];
  [self failAllPendingSnapshots:@"player was torn down"];
  [self drainCurrentSession];
  _hasMedia = NO;
  _mediaStarted = NO;
  _loadEmitted = NO;
  _playingEmitted = NO;
  _isBuffering = NO;
  _appliedPaused = nil;
  _appliedResizeKey = nil;
}

/// Detaches the live session and stops it on the teardown queue. stop joins
/// libvlc's input thread and can block for many seconds on a wedged network
/// stream — running it on the main thread freezes the whole UI (most visible
/// when swapping sources while a stream is still opening).
- (void)drainCurrentSession
{
  VLCMedia *doomedMedia = _currentMedia;
  VLCMediaListPlayer *doomedPlayer = _listPlayer;
  _currentMedia = nil;
  _player = nil;
  _listPlayer = nil;
  if (doomedPlayer == nil) {
    return;
  }
  doomedPlayer.delegate = nil;
  doomedPlayer.mediaPlayer.delegate = nil;
  doomedPlayer.mediaPlayer.drawable = nil; // zombie must never touch our view
  NSLog(@"[VlcPlayer] detached session, draining in background");
  dispatch_async(VlcTeardownQueue(), ^{
    // The block keeps the doomed objects alive until they finished stopping.
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    [doomedMedia parseStop];
    // VLCMediaListPlayer's stop returns immediately WITHOUT killing the
    // input ("drained in 0.00s" while live555 kept retrying) — the media
    // player's stop is the one that actually aborts and joins the input
    // thread, which is exactly why this runs on the teardown queue.
    [doomedPlayer.mediaPlayer stop];
    [doomedPlayer stop];
    NSLog(@"[VlcPlayer] session drained in %.2fs", CFAbsoluteTimeGetCurrent() - start);
  });
}

- (void)loadMedia
{
  [self cancelOpeningTimer];
  _mediaStarted = NO;
  _loadEmitted = NO;
  _playingEmitted = NO;
  _appliedPaused = nil;
  _appliedResizeKey = nil;
  [self setBuffering:NO];

  // Every media swap retires the whole session to the background drain and
  // starts a fresh one — reusing the player would require a synchronous stop
  // on the main thread, which hangs the UI when the old stream is wedged.
  [self drainCurrentSession];
  _hasMedia = NO;

  if (_desiredUrl.length == 0) {
    return;
  }

  [self ensurePlayer];

  NSURL *url = VlcSourceURL(_desiredUrl);
  if (url == nil) {
    [self emitError:[NSString stringWithFormat:@"invalid source URL: %@", _desiredUrl]];
    return;
  }

  VLCMedia *media = [VLCMedia mediaWithURL:url];
  // Baseline options every media gets in the official VLC-iOS app
  // (mediaOptionsDictionary defaults). Applied first so user-supplied
  // mediaOptions below can override them. VLC-iOS also forces
  // subsdec-encoding=Windows-1252; we deliberately keep libvlc's charset
  // auto-detection instead.
  [media addOption:@":network-caching=999"];
  [media addOption:@":avcodec-skiploopfilter=1"];
  for (NSString *option in _desiredMediaOptions) {
    [media addOption:option];
  }
  if (_desiredReferer.length > 0) {
    [media addOption:[NSString stringWithFormat:@":http-referrer=%@", _desiredReferer]];
  }
  if (_desiredUserAgent.length > 0) {
    [media addOption:[NSString stringWithFormat:@":http-user-agent=%@", _desiredUserAgent]];
  }
  if (!_desiredHardwareDecoding) {
    // Same option VLC-iOS's "Hardware decoding: Off" setting uses ("codec"
    // key): put avcodec ahead of everything so VideoToolbox never engages.
    [media addOption:@":codec=avcodec,all"];
  }

  // Deliberately NOT calling parseWithOptions (VLC-iOS does): the preparser
  // is a single shared work queue, so a wedged RTSP parse blocks every later
  // media's parse, and it opens a second connection some cameras reject.
  // Nothing we emit needs it — duration/videoSize come from playback itself.

  VLCMediaList *list = [[VLCMediaList alloc] init];
  [list addMedia:media];
  _listPlayer.mediaList = list;
  _currentMedia = media;
  _hasMedia = YES;
}

/// Pushes runtime-mutable desired state (pause/volume/rate/repeat/resize)
/// onto the live player. Safe to call repeatedly.
- (void)applyRuntimeState
{
  if (_player == nil) {
    return;
  }

  _listPlayer.repeatMode = _desiredRepeat ? VLCRepeatCurrentItem : VLCDoNotRepeat;
  [self applyRate];
  [self applyAudioState];
  [self applyResizeMode];

  if (!_hasMedia) {
    return;
  }
  // Gate on the applied value: an unrelated prop change (say, volume) after
  // playback Ended must not restart the media just because isPlaying == NO.
  BOOL pausedChanged = _appliedPaused == nil || _appliedPaused.boolValue != _desiredPaused;
  if (!pausedChanged) {
    return;
  }
  _appliedPaused = @(_desiredPaused);
  if (_desiredPaused) {
    if (_player.isPlaying) {
      [_listPlayer pause];
    }
  } else {
    [self startOrResumePlayback];
  }
}

// applyRate/applyAudioState are re-entered on every Playing transition
// (micro-buffer recoveries included), so both diff against the live player —
// redundantly poking rate/volume on a live stream causes playback hiccups
// and VLC-iOS only sets rate when it differs from the default.

- (void)applyRate
{
  float rate = _desiredRate > 0 ? _desiredRate : 1.0f;
  if (fabsf(_player.rate - rate) > 0.001f) {
    _player.rate = rate;
  }
}

- (void)applyAudioState
{
  VLCAudio *audio = _player.audio;
  if (audio.muted != _desiredMuted) {
    audio.muted = _desiredMuted;
  }
  float volume = MIN(MAX(_desiredVolume, 0.0f), 1.0f);
  int target = (int)lroundf(volume * 100.0f);
  if (audio.volume != target) {
    audio.volume = target;
  }
}

- (void)startOrResumePlayback
{
  if (!_mediaStarted) {
    _mediaStarted = YES;
    [_listPlayer playItemAtNumber:@(0)];
    [self startOpeningTimer];
  } else if (!_player.isPlaying) {
    [_listPlayer play];
  }
}

#pragma mark - Resize mode

- (void)layoutSubviews
{
  [super layoutSubviews];
  // cover/stretch derive from the view size; keep them in sync with layout.
  [self applyResizeMode];
}

- (void)applyResizeMode
{
  if (_player == nil) {
    return;
  }

  // Idempotence guard: layoutSubviews and several state transitions call
  // this; poking the vout during steady-state playback is wasted work.
  CGSize viewSize = self.bounds.size;
  CGSize knownVideoSize = _player.videoSize;
  NSString *resizeKey = [NSString stringWithFormat:@"%@|%.0fx%.0f|%.0fx%.0f", _desiredResizeMode, viewSize.width,
                                                   viewSize.height, knownVideoSize.width, knownVideoSize.height];
  if ([resizeKey isEqualToString:_appliedResizeKey]) {
    return;
  }
  _appliedResizeKey = resizeKey;

  // Reset to libvlc defaults ("contain": fit inside, letterbox), then layer
  // the requested mode on top — the same reset VLC-iOS performs when cycling
  // aspect ratios.
  _player.scaleFactor = 0;
  _player.videoAspectRatio = NULL;
  _player.videoCropGeometry = NULL;
  if ([_desiredResizeMode isEqualToString:@"cover"]) {
    // VLC-iOS "fill to screen": scale so the video covers the view, letting
    // the edges crop. Needs the decoded video size, which is only known once
    // an ES is added — callers re-apply from those state transitions.
    CGSize videoSize = _player.videoSize;
    if (videoSize.width < 1 || videoSize.height < 1 || viewSize.width < 1 || viewSize.height < 1) {
      return;
    }
    CGFloat videoAspect = videoSize.width / videoSize.height;
    CGFloat viewAspect = viewSize.width / viewSize.height;
    CGFloat scale = viewAspect >= videoAspect ? viewSize.width / videoSize.width
                                              : viewSize.height / videoSize.height;
    CGFloat screenScale = self.traitCollection.displayScale ?: UIScreen.mainScreen.scale;
    _player.scaleFactor = (float)(scale * screenScale);
  } else if ([_desiredResizeMode isEqualToString:@"stretch"]) {
    if (viewSize.width < 1 || viewSize.height < 1) {
      return;
    }
    NSString *aspect =
        [NSString stringWithFormat:@"%d:%d", (int)lround(viewSize.width), (int)lround(viewSize.height)];
    // libvlc copies the string, the temporary UTF8 buffer is fine.
    _player.videoAspectRatio = (char *)aspect.UTF8String;
  } else if ([_desiredResizeMode isEqualToString:@"original"]) {
    _player.scaleFactor = 1.0f;
  }
}

#pragma mark - Opening timeout

- (void)startOpeningTimer
{
  [self cancelOpeningTimer];
  NSTimeInterval timeout = [self openingTimeout];
  __weak __typeof(self) weakSelf = self;
  _openingTimer = [NSTimer scheduledTimerWithTimeInterval:timeout
                                                  repeats:NO
                                                    block:^(NSTimer *timer) {
                                                      [weakSelf openingDidTimeOut];
                                                    }];
}

- (NSTimeInterval)openingTimeout
{
  NSString *lower = _desiredUrl.lowercaseString;
  return [lower hasPrefix:@"rtsp://"] ? kRtspOpeningTimeoutSeconds : kOpeningTimeoutSeconds;
}

- (void)cancelOpeningTimer
{
  [_openingTimer invalidate];
  _openingTimer = nil;
}

- (void)openingDidTimeOut
{
  _openingTimer = nil;
  if (_player.isPlaying || _loadEmitted) {
    return;
  }
  [self drainCurrentSession];
  _hasMedia = NO;
  _mediaStarted = NO;
  [self setBuffering:NO];
  [self emitError:[NSString stringWithFormat:@"connection timed out after %.0fs: %@", [self openingTimeout],
                                             _desiredUrl]];
}

#pragma mark - VLCMediaPlayerDelegate
// MobileVLCKit delivers delegate callbacks on the main thread.

- (void)mediaPlayerStateChanged:(NSNotification *)notification
{
  switch (_player.state) {
    case VLCMediaPlayerStateOpening:
      break;
    case VLCMediaPlayerStateBuffering:
      // The opening timer keeps running: libvlc enters Buffering immediately
      // even when no byte ever arrives. Playing/timeChanged prove liveness.
      [self setBuffering:YES];
      break;
    case VLCMediaPlayerStateESAdded:
      [self emitLoadIfReady];
      [self applyResizeMode]; // videoSize just became known
      break;
    case VLCMediaPlayerStatePlaying:
      [self cancelOpeningTimer];
      [self setBuffering:NO];
      [self emitLoadIfReady];
      [self emitPlayingIfNeeded];
      // Rate/volume set before the first frame don't always stick; re-push
      // (diffed inside, so steady-state Playing transitions are no-ops).
      [self applyRate];
      [self applyAudioState];
      [self applyResizeMode];
      break;
    case VLCMediaPlayerStatePaused:
      [self setBuffering:NO];
      break;
    case VLCMediaPlayerStateEnded:
      [self cancelOpeningTimer];
      [self setBuffering:NO];
      [self emitEnd];
      break;
    case VLCMediaPlayerStateError:
      [self cancelOpeningTimer];
      [self setBuffering:NO];
      [self emitError:@"playback failed"];
      break;
    case VLCMediaPlayerStateStopped:
      [self setBuffering:NO];
      break;
  }
}

- (void)mediaPlayerTimeChanged:(NSNotification *)notification
{
  [self cancelOpeningTimer];
  [self setBuffering:NO];
  [self emitLoadIfReady];

  int currentTime = _player.time.intValue;
  int duration = _player.media.length.intValue;
  float percent = duration > 0 ? (100.0f * currentTime / duration) : 0.0f;
  if (auto emitter = [self emitter]) {
    emitter->onProgress({.currentTime = currentTime, .duration = duration, .percent = percent});
  }
}

- (void)mediaPlayerSnapshot:(NSNotification *)notification
{
  if (_pendingSnapshots.count == 0) {
    return;
  }
  NSDictionary *request = _pendingSnapshots.firstObject;
  [_pendingSnapshots removeObjectAtIndex:0];
  if (auto emitter = [self emitter]) {
    NSString *fileURL = [NSURL fileURLWithPath:request[@"path"]].absoluteString;
    emitter->onSnapshotResult({.callId = [request[@"callId"] intValue],
                               .path = RCTStringFromNSString(fileURL),
                               .error = ""});
  }
}

#pragma mark - Events

- (std::shared_ptr<const VlcPlayerViewEventEmitter>)emitter
{
  return std::static_pointer_cast<const VlcPlayerViewEventEmitter>(_eventEmitter);
}

- (void)setBuffering:(BOOL)buffering
{
  if (_isBuffering == buffering) {
    return;
  }
  _isBuffering = buffering;
  if (auto emitter = [self emitter]) {
    // MobileVLCKit 3.x exposes no buffering percentage; report edges only.
    emitter->onBuffer({.isBuffering = static_cast<bool>(buffering), .percent = buffering ? 0.0f : 100.0f});
  }
}

- (void)emitLoadIfReady
{
  if (_loadEmitted || _player.media == nil) {
    return;
  }
  CGSize videoSize = _player.videoSize;
  if (videoSize.width < 1 && !_player.isPlaying) {
    return; // wait for a video ES (or for audio-only to actually play)
  }
  _loadEmitted = YES;
  if (auto emitter = [self emitter]) {
    emitter->onLoad({.duration = _player.media.length.intValue,
                     .videoWidth = (int)videoSize.width,
                     .videoHeight = (int)videoSize.height});
  }
}

- (void)emitPlayingIfNeeded
{
  if (_playingEmitted) {
    return;
  }
  _playingEmitted = YES;
  if (auto emitter = [self emitter]) {
    emitter->onPlaying({.url = RCTStringFromNSString(_desiredUrl)});
  }
}

- (void)emitEnd
{
  if (auto emitter = [self emitter]) {
    emitter->onEnd({.url = RCTStringFromNSString(_desiredUrl)});
  }
}

- (void)emitError:(NSString *)message
{
  if (auto emitter = [self emitter]) {
    emitter->onError({.message = RCTStringFromNSString(message)});
  }
}

#pragma mark - Commands

- (void)handleCommand:(const NSString *)commandName args:(const NSArray *)args
{
  RCTVlcPlayerViewHandleCommand(self, commandName, args);
}

- (void)play
{
  if (_player == nil || !_hasMedia) {
    return;
  }
  [self startOrResumePlayback];
}

- (void)pause
{
  if (_player.isPlaying) {
    [_listPlayer pause];
  }
}

- (void)seek:(float)seconds
{
  if (_player == nil || !_mediaStarted) {
    return;
  }
  _player.time = [VLCTime timeWithInt:(int)lroundf(seconds * 1000.0f)];
}

- (void)snapshot:(NSInteger)callId
{
  if (_player == nil || !_player.hasVideoOut) {
    [self emitSnapshotFailure:callId message:@"no video is being rendered"];
    return;
  }
  NSString *cachesDir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
  NSString *path = [cachesDir
      stringByAppendingPathComponent:[NSString stringWithFormat:@"vlc-snapshot-%@.png", NSUUID.UUID.UUIDString]];
  [_pendingSnapshots addObject:@{@"callId" : @(callId), @"path" : path}];
  [_player saveVideoSnapshotAt:path withWidth:0 andHeight:0]; // 0×0 = native size

  __weak __typeof(self) weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSnapshotTimeoutSeconds * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   [weakSelf failSnapshotIfStillPending:callId];
                 });
}

- (void)reload
{
  if (_desiredUrl.length == 0) {
    return;
  }
  [self loadMedia];
  [self applyRuntimeState];
}

- (void)failSnapshotIfStillPending:(NSInteger)callId
{
  for (NSUInteger i = 0; i < _pendingSnapshots.count; i++) {
    if ([_pendingSnapshots[i][@"callId"] integerValue] == callId) {
      [_pendingSnapshots removeObjectAtIndex:i];
      [self emitSnapshotFailure:callId message:@"snapshot timed out"];
      return;
    }
  }
}

- (void)failAllPendingSnapshots:(NSString *)message
{
  NSArray<NSDictionary *> *pending = [_pendingSnapshots copy];
  [_pendingSnapshots removeAllObjects];
  for (NSDictionary *request in pending) {
    [self emitSnapshotFailure:[request[@"callId"] integerValue] message:message];
  }
}

- (void)emitSnapshotFailure:(NSInteger)callId message:(NSString *)message
{
  if (auto emitter = [self emitter]) {
    emitter->onSnapshotResult({.callId = (int)callId, .path = "", .error = RCTStringFromNSString(message)});
  }
}

#pragma mark - App lifecycle

- (void)applicationDidEnterBackground:(NSNotification *)notification
{
  // Same policy as VLC-iOS without the background-audio setting: pause and
  // remember to resume. libvlc keeps rendering into a backgrounded GL layer
  // otherwise, which iOS kills.
  if (_player.isPlaying) {
    [_listPlayer pause];
    _resumeOnForeground = YES;
  }
}

- (void)applicationWillEnterForeground:(NSNotification *)notification
{
  if (_resumeOnForeground) {
    _resumeOnForeground = NO;
    [_listPlayer play];
  }
}

#pragma mark - Recycling

- (void)prepareForRecycle
{
  [super prepareForRecycle];
  [self teardownPlayer];
  [self resetDesiredStateToDefaults];
  _needsPlayerRebuild = NO;
  _needsMediaReload = NO;
  _needsRuntimeApply = NO;
  _resumeOnForeground = NO;
  // super resets _props to plain ViewProps; restore our concrete type so the
  // static_pointer_cast in updateProps stays valid after recycling.
  static const auto defaultProps = std::make_shared<const VlcPlayerViewProps>();
  _props = defaultProps;
}

@end
