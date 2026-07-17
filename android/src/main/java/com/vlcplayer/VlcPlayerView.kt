package com.vlcplayer

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.AttributeSet
import android.util.Log
import android.view.PixelCopy
import android.view.SurfaceView
import android.widget.FrameLayout
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.ReactContext
import com.facebook.react.bridge.WritableArray
import com.facebook.react.bridge.WritableMap
import com.facebook.react.uimanager.UIManagerHelper
import com.facebook.react.uimanager.events.Event
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import java.util.concurrent.Executors
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer
import org.videolan.libvlc.interfaces.IMedia
import org.videolan.libvlc.util.VLCVideoLayout

class VlcPlayerView @JvmOverloads constructor(
  context: Context,
  attrs: AttributeSet? = null,
  defStyleAttr: Int = 0,
) : FrameLayout(context, attrs, defStyleAttr), DefaultLifecycleObserver {

  // VLCVideoLayout as a child, not `this` — VLCVideoLayout.onAttachedToWindow
  // force-resets LayoutParams to MATCH_PARENT, which fights Fabric if we
  // inherit it directly.
  private val videoLayout = VLCVideoLayout(context).also {
    addView(it, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
  }

  // Desired state (driven by props)
  private var currentUri: Uri? = null
  private var desiredInitOptions: List<String> = emptyList()
  private var desiredMediaOptions: List<String> = emptyList()
  private var desiredResizeMode: ResizeMode = ResizeMode.CONTAIN
  private var shouldPlayWhenReady: Boolean = true
  private var desiredMuted: Boolean = false
  private var desiredVolume: Float = 1f
  private var desiredRate: Float = 1f
  private var desiredRepeat: Boolean = false
  private var desiredHardwareEnabled: Boolean = true
  private var desiredReferer: String? = null
  private var desiredUserAgent: String? = null
  // Track selection: 'auto' (leave libvlc alone), 'none' (disable), or a
  // stringified TrackDescription id. Desired-tier: survives media reloads.
  private var desiredAudioTrackId: String = "auto"
  private var desiredTextTrackId: String = "auto"
  private var desiredSubtitleUri: String? = null
  private var progressUpdateIntervalMs: Long = 500

  // Internal state
  private var playerSession: PlayerSession? = null
  // -1 unknown, 0 paused, 1 playing — dedupe for onPlaybackStateChanged.
  private var lastReportedIsPlaying: Int = -1
  private var attachedToWindow: Boolean = false
  // Position handover across the background stop/rebuild cycle (the session
  // dies with the background, official-app style savedTime lives up here).
  private var savedResumeUri: Uri? = null
  private var savedResumeMs: Long = 0
  private var released: Boolean = false
  private var pendingApply: Boolean = false

  // PNG encoding offloaded so cmdSnapshot doesn't block the UI thread.
  private val snapshotExecutor = Executors.newSingleThreadExecutor { r ->
    Thread(r, "VlcPlayerView-Snapshot").apply { isDaemon = true }
  }
  // Reused by PixelCopy.request to avoid a Handler alloc per snapshot.
  private val mainHandler = Handler(Looper.getMainLooper())


  // ---- Audio session behaviors (platform convention, parity with iOS) ----

  // Wired headphones unplugged / Bluetooth audio dropped. Android's canonical
  // signal is ACTION_AUDIO_BECOMING_NOISY — pause instead of switching to the
  // loudspeaker. Deliberately no auto-resume; the user decides.
  private val becomingNoisyReceiver = object : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
      if (released || intent?.action != AudioManager.ACTION_AUDIO_BECOMING_NOISY) return
      playerSession?.takeIf { it.isPlaying() }?.pause()
    }
  }

  private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
  private var hasAudioFocus = false
  private var resumeOnFocusGain = false

  // Delivered on the main thread (registered with the main-looper handler).
  private val audioFocusListener = AudioManager.OnAudioFocusChangeListener { change ->
    if (released) return@OnAudioFocusChangeListener
    when (change) {
      AudioManager.AUDIOFOCUS_LOSS -> {
        // Another app took playback over for good (e.g. a music app).
        resumeOnFocusGain = false
        playerSession?.pause()
        abandonAudioFocus()
      }
      AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
        // Phone call or similar; remember whether we were the one playing.
        resumeOnFocusGain = playerSession?.isPlaying() == true
        playerSession?.pause()
      }
      // LOSS_TRANSIENT_CAN_DUCK is not handled: on API 26+ the system ducks
      // automatically because we don't opt out via setWillPauseWhenDucked.
      AudioManager.AUDIOFOCUS_GAIN -> {
        if (resumeOnFocusGain && shouldPlayWhenReady && attachedToWindow && currentUri != null) {
          playerSession?.playWhenReady()
        }
        resumeOnFocusGain = false
      }
    }
  }

  private val audioFocusRequest: AudioFocusRequest? =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
        .setAudioAttributes(
          AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
            .build(),
        )
        .setOnAudioFocusChangeListener(audioFocusListener, mainHandler)
        .build()
    } else {
      null
    }

  init {
    ProcessLifecycleOwner.get().lifecycle.addObserver(this)
    val noisyFilter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      context.registerReceiver(becomingNoisyReceiver, noisyFilter, Context.RECEIVER_NOT_EXPORTED)
    } else {
      context.registerReceiver(becomingNoisyReceiver, noisyFilter)
    }
  }

  // Fabric's ReactViewGroup swallows requestLayout; libvlc's programmatically-
  // added SurfaceView would never receive a size and play() would stall in
  // areSurfacesWaiting. Pump a manual measure/layout on every requestLayout.
  private val measureAndLayoutRunnable = Runnable {
    measure(
      MeasureSpec.makeMeasureSpec(width, MeasureSpec.EXACTLY),
      MeasureSpec.makeMeasureSpec(height, MeasureSpec.EXACTLY),
    )
    layout(left, top, right, bottom)
  }

  override fun requestLayout() {
    super.requestLayout()
    removeCallbacks(measureAndLayoutRunnable)
    post(measureAndLayoutRunnable)
  }

  // ============================================================
  // Prop setters (called from VlcPlayerViewManager)
  // ============================================================

  fun setStreamUrl(url: String?) {
    if (released) return
    val resolved = parseStreamUri(url)
    if (resolved == currentUri) return
    currentUri = resolved
    pendingApply = true
  }

  fun setInitOptions(options: List<String>?) {
    if (released) return
    val resolved = options ?: emptyList()
    if (resolved == desiredInitOptions) return
    desiredInitOptions = resolved
    if (currentUri != null) pendingApply = true
  }

  fun setMediaOptions(options: List<String>?) {
    if (released) return
    val resolved = options ?: emptyList()
    if (resolved == desiredMediaOptions) return
    desiredMediaOptions = resolved
    if (currentUri != null) pendingApply = true
  }

  fun setPausedState(paused: Boolean) {
    if (released) return
    val newShould = !paused
    if (newShould == shouldPlayWhenReady) return
    shouldPlayWhenReady = newShould
    if (paused) {
      playerSession?.pause()
    } else if (attachedToWindow && currentUri != null) {
      playerSession?.playWhenReady()
    }
  }

  fun setMutedState(muted: Boolean) {
    if (released || muted == desiredMuted) return
    desiredMuted = muted
    applyVolumeAndMute()
  }

  fun setVolumeLevel(volume: Float) {
    if (released) return
    val coerced = volume.coerceIn(0f, 1f)
    if (coerced == desiredVolume) return
    desiredVolume = coerced
    applyVolumeAndMute()
  }

  fun setRateLevel(rate: Float) {
    if (released) return
    val resolved = if (rate > 0f) rate else 1f
    if (resolved == desiredRate) return
    desiredRate = resolved
    playerSession?.applyRate(resolved)
  }

  fun setRepeatMode(repeat: Boolean) {
    if (released || repeat == desiredRepeat) return
    desiredRepeat = repeat
    // Repeat is baked into the media as :input-repeat (seamless, zero-gap
    // looping) — libvlc can't cancel it on a running input, so toggling
    // reloads the media. Same semantics as hardwareDecoding.
    if (currentUri != null) pendingApply = true
  }

  fun setHardwareDecoding(enabled: Boolean) {
    if (released || enabled == desiredHardwareEnabled) return
    desiredHardwareEnabled = enabled
    if (currentUri != null) pendingApply = true
  }

  fun setReferer(value: String?) {
    if (released) return
    val resolved = value?.trim()?.takeIf { it.isNotEmpty() }
    if (resolved == desiredReferer) return
    desiredReferer = resolved
    if (currentUri != null) pendingApply = true
  }

  fun setUserAgent(value: String?) {
    if (released) return
    val resolved = value?.trim()?.takeIf { it.isNotEmpty() }
    if (resolved == desiredUserAgent) return
    desiredUserAgent = resolved
    if (currentUri != null) pendingApply = true
  }

  fun setAudioTrackId(value: String?) {
    if (released) return
    val resolved = value?.trim()?.takeIf { it.isNotEmpty() } ?: "auto"
    if (resolved == desiredAudioTrackId) return
    desiredAudioTrackId = resolved
    playerSession?.applyTrackSelection()
  }

  fun setTextTrackId(value: String?) {
    if (released) return
    val resolved = value?.trim()?.takeIf { it.isNotEmpty() } ?: "auto"
    if (resolved == desiredTextTrackId) return
    desiredTextTrackId = resolved
    playerSession?.applyTrackSelection()
  }

  fun setSubtitleUri(value: String?) {
    if (released) return
    val resolved = value?.trim()?.takeIf { it.isNotEmpty() }
    if (resolved == desiredSubtitleUri) return
    desiredSubtitleUri = resolved
    // Slaves bind to an input at open time — a change means reloading media.
    if (currentUri != null) pendingApply = true
  }

  fun setProgressUpdateInterval(value: Int) {
    if (released) return
    progressUpdateIntervalMs = if (value > 0) value.toLong() else 500L
  }

  fun setResizeMode(mode: String?) {
    if (released) return
    val resolved = ResizeMode.fromValue(mode)
    if (resolved == desiredResizeMode) return
    desiredResizeMode = resolved
    playerSession?.applyResizeMode(resolved)
  }

  // ============================================================
  // Commands (called from VlcPlayerViewManager.receiveCommand)
  // ============================================================

  fun cmdPlay() {
    if (released) return
    shouldPlayWhenReady = true
    if (attachedToWindow && currentUri != null) {
      playerSession?.playWhenReady()
    }
  }

  fun cmdPause() {
    if (released) return
    shouldPlayWhenReady = false
    playerSession?.pause()
  }

  fun cmdSeek(seconds: Double) {
    if (released) return
    val ms = (seconds * 1000.0).toLong().coerceAtLeast(0L)
    playerSession?.seekTo(ms)
  }

  fun cmdReload() {
    if (released || currentUri == null) return
    shouldPlayWhenReady = true
    playerSession?.release()
    playerSession = null
    pendingApply = true
    applyPendingChanges()
  }

  fun cmdSnapshot(callId: Int) {
    if (released) {
      emitSnapshotResult(callId, path = null, error = "View released")
      return
    }
    val surfaceView = findInnerSurfaceView()
    if (surfaceView == null || surfaceView.width == 0 || surfaceView.height == 0) {
      emitSnapshotResult(callId, path = null, error = "Video surface not ready")
      return
    }
    // SurfaceView pixels live on a Surface owned by SurfaceFlinger; PixelCopy
    // is the only public API to read them back.
    val frame = Bitmap.createBitmap(surfaceView.width, surfaceView.height, Bitmap.Config.ARGB_8888)
    PixelCopy.request(surfaceView, frame, { result ->
      if (result == PixelCopy.SUCCESS) {
        encodeSnapshotAsync(callId, frame)
      } else {
        frame.recycle()
        emitSnapshotResult(callId, path = null, error = "PixelCopy failed: $result")
      }
    }, mainHandler)
  }

  private fun encodeSnapshotAsync(callId: Int, frame: Bitmap) {
    snapshotExecutor.execute {
      // The file stays in cacheDir for the consumer (JS gets a file:// URI);
      // the OS reclaims cache storage, and callers copy it out if they need
      // persistence.
      val result = runCatching {
        val file = File(context.cacheDir, "vlc-snap-$callId-${UUID.randomUUID()}.png")
        val ok = FileOutputStream(file).use { frame.compress(Bitmap.CompressFormat.PNG, 100, it) }
        if (!ok) {
          file.delete()
          error("PNG encoding failed")
        }
        Uri.fromFile(file).toString()
      }
      frame.recycle()
      post {
        result.fold(
          onSuccess = { emitSnapshotResult(callId, path = it, error = null) },
          onFailure = { emitSnapshotResult(callId, path = null, error = it.message ?: "Snapshot encoding failed") },
        )
      }
    }
  }

  fun release() {
    if (released) return
    released = true
    shouldPlayWhenReady = false
    pendingApply = false
    removeCallbacks(measureAndLayoutRunnable)
    ProcessLifecycleOwner.get().lifecycle.removeObserver(this)
    runCatching { context.unregisterReceiver(becomingNoisyReceiver) }
    abandonAudioFocus()
    currentUri = null
    if (attachedToWindow) {
      // Still on screen: the popped screen keeps drawing until its exit
      // animation ends, and libvlc teardown paints the live surface black
      // (vlc ClearSurface). Freeze the frame; finish in onDetachedFromWindow.
      playerSession?.pause()
      return
    }
    finishRelease()
  }

  private fun finishRelease() {
    playerSession?.release()
    playerSession = null
    snapshotExecutor.shutdown()
  }

  /** Called from `onAfterUpdateTransaction` after a batch of prop changes. */
  fun applyPendingChanges() {
    if (released || !pendingApply) return
    pendingApply = false
    val uri = currentUri
    if (uri == null) {
      playerSession?.stop()
      playerSession?.release()
      playerSession = null
      return
    }
    ensureSession().prepare(uri, desiredMediaOptions, autoPlay = shouldPlayWhenReady)
  }

  // ============================================================
  // View lifecycle
  // ============================================================

  override fun onAttachedToWindow() {
    super.onAttachedToWindow()
    if (released) return
    attachedToWindow = true
    playerSession?.attach(videoLayout)
    if (shouldPlayWhenReady && currentUri != null) {
      playerSession?.playWhenReady()
    }
  }

  override fun onDetachedFromWindow() {
    attachedToWindow = false
    if (released) {
      // Deferred from release(); children detach first, the surface is dead.
      finishRelease()
    } else {
      playerSession?.pause()
      playerSession?.detach()
    }
    super.onDetachedFromWindow()
  }

  override fun onStop(owner: LifecycleOwner) {
    if (released) return
    // Official VLC-Android parity: no resurrection. Backgrounding stops
    // playback outright — the system reclaims the codec and surface anyway
    // (device-verified) and every revival heuristic we tried could be lied
    // to. Foregrounding rebuilds from the saved position instead.
    captureResumeState()
    playerSession?.release()
    playerSession = null
  }

  override fun onStart(owner: LifecycleOwner) {
    if (released) return
    if (!attachedToWindow || currentUri == null) return
    pendingApply = true
    applyPendingChanges()
  }

  // Official-app rules: never resume into the last 5 seconds; rewind 2
  // seconds to compensate perceived loading time. Live streams (no length)
  // reconnect fresh.
  private fun captureResumeState() {
    savedResumeUri = null
    savedResumeMs = 0
    val session = playerSession ?: return
    val time = session.currentTimeMs()
    val length = session.lengthMs()
    if (time <= 0L || length <= 0L || length - time < 5000) return
    savedResumeUri = currentUri
    savedResumeMs = (time - 2000).coerceAtLeast(0)
  }

  // ============================================================
  // Internal helpers
  // ============================================================

  private fun parseStreamUri(url: String?): Uri? {
    val normalized = url?.trim().orEmpty()
    if (normalized.isEmpty()) return null
    // Uri.parse never throws (parsing is lazy) — invalid input surfaces as
    // a null/empty scheme, which the check below rejects.
    val uri = Uri.parse(normalized)
    if (uri.scheme.isNullOrEmpty()) return null
    return uri
  }

  private fun ensureSession(): PlayerSession {
    val existing = playerSession
    if (existing != null && existing.matches(desiredInitOptions)) {
      return existing
    }
    existing?.release()
    Log.i(TAG, "Creating player session with initOptions [${desiredInitOptions.joinToString(", ")}]")
    val fresh = PlayerSession(context, desiredInitOptions)
    fresh.applyResizeMode(desiredResizeMode)
    fresh.applyVolume(effectiveVolumeInt())
    fresh.applyRate(desiredRate)
    if (attachedToWindow) {
      fresh.attach(videoLayout)
    }
    playerSession = fresh
    return fresh
  }

  // Called from the session's Playing handler — focus follows actual
  // playback, so a paused or failed player never holds it.
  private fun requestAudioFocusIfNeeded() {
    if (hasAudioFocus || released) return
    @Suppress("DEPRECATION")
    val result = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      audioManager.requestAudioFocus(requireNotNull(audioFocusRequest))
    } else {
      audioManager.requestAudioFocus(
        audioFocusListener,
        AudioManager.STREAM_MUSIC,
        AudioManager.AUDIOFOCUS_GAIN,
      )
    }
    hasAudioFocus = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
  }

  private fun abandonAudioFocus() {
    if (!hasAudioFocus) return
    hasAudioFocus = false
    @Suppress("DEPRECATION")
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      audioManager.abandonAudioFocusRequest(requireNotNull(audioFocusRequest))
    } else {
      audioManager.abandonAudioFocus(audioFocusListener)
    }
  }

  private fun effectiveVolumeInt(): Int =
    if (desiredMuted) 0 else (desiredVolume * 100f).toInt().coerceIn(0, 100)

  private fun applyVolumeAndMute() {
    playerSession?.applyVolume(effectiveVolumeInt())
  }

  // Masks user:password@ in URLs so credentials don't end up in logs.
  private fun redactUri(uri: Uri): String =
    uri.toString().replace(Regex("//[^/@]+@"), "//***@")

  private fun findInnerSurfaceView(): SurfaceView? =
    videoLayout.findViewById<android.view.View>(org.videolan.R.id.player_surface_frame)
      ?.findViewById<SurfaceView>(org.videolan.R.id.surface_video)

  // ============================================================
  // Fabric direct-event dispatch
  // ============================================================

  private fun emitLoad(duration: Long, videoWidth: Int, videoHeight: Int) {
    val map = Arguments.createMap().apply {
      putInt("duration", duration.coerceIn(0L, Int.MAX_VALUE.toLong()).toInt())
      putInt("videoWidth", videoWidth)
      putInt("videoHeight", videoHeight)
    }
    emitEvent("topLoad", map)
  }

  private fun emitPlaying(uri: Uri?) {
    val map = Arguments.createMap().apply { putString("url", uri?.toString() ?: "") }
    emitEvent("topPlaying", map)
  }

  private fun emitBuffer(isBuffering: Boolean, percent: Float) {
    val map = Arguments.createMap().apply {
      putBoolean("isBuffering", isBuffering)
      putDouble("percent", percent.coerceIn(0f, 100f).toDouble())
    }
    emitEvent("topBuffer", map)
  }

  private fun emitProgress(currentTime: Long, duration: Long, percent: Float) {
    val map = Arguments.createMap().apply {
      putInt("currentTime", currentTime.coerceIn(0L, Int.MAX_VALUE.toLong()).toInt())
      putInt("duration", duration.coerceIn(0L, Int.MAX_VALUE.toLong()).toInt())
      putDouble("percent", percent.coerceIn(0f, 100f).toDouble())
    }
    emitEvent("topProgress", map)
  }

  private fun emitEnd(uri: Uri?) {
    val map = Arguments.createMap().apply { putString("url", uri?.toString() ?: "") }
    emitEvent("topEnd", map)
  }

  private fun emitError(message: String) {
    Log.w(TAG, "emitError: $message")
    val map = Arguments.createMap().apply { putString("message", message) }
    emitEvent("topError", map)
  }

  private fun emitSnapshotResult(callId: Int, path: String?, error: String?) {
    val map = Arguments.createMap().apply {
      putInt("callId", callId)
      putString("path", path ?: "")
      putString("error", error ?: "")
    }
    emitEvent("topSnapshotResult", map)
  }

  private fun emitPlaybackState(isPlaying: Boolean) {
    val normalized = if (isPlaying) 1 else 0
    if (lastReportedIsPlaying == normalized) return
    lastReportedIsPlaying = normalized
    val map = Arguments.createMap()
    map.putBoolean("isPlaying", isPlaying)
    emitEvent("topPlaybackStateChanged", map)
  }

  private fun emitEvent(eventName: String, payload: WritableMap) {
    // The session briefly outlives onDropViewInstance — no events after that.
    if (released) return
    val reactContext = context as? ReactContext ?: return
    val dispatcher = UIManagerHelper.getEventDispatcherForReactTag(reactContext, id) ?: return
    val surfaceId = UIManagerHelper.getSurfaceId(this)
    dispatcher.dispatchEvent(VlcEvent(surfaceId, id, eventName, payload))
  }

  private class VlcEvent(
    surfaceId: Int,
    viewTag: Int,
    private val name: String,
    private val data: WritableMap,
  ) : Event<VlcEvent>(surfaceId, viewTag) {
    override fun getEventName(): String = name
    override fun getEventData(): WritableMap = data
  }

  // ============================================================
  // PlayerSession
  // ============================================================

  // Session identity is the LibVLC instance, keyed by initOptions (its
  // constructor args). Media-level options are applied per prepare() —
  // changing them must NOT tear down the libvlc core.
  private inner class PlayerSession(
    context: Context,
    private val initOptions: List<String>,
  ) {
    // One process-wide libvlc core per distinct initOptions set (see
    // LibVlcCorePool) — per-view cores multiply memory and startup cost in
    // multi-player grids. MediaPlayer stays per-session.
    private val libVlc = LibVlcCorePool.acquire(context, initOptions)
    private val mediaPlayer = MediaPlayer(libVlc)

    private var attached = false
    private var playWhenAttached = false
    private var loadedUri: Uri? = null

    // libvlc-android delivers MediaPlayer events on the main thread
    // (VLCObject posts them to a main-looper Handler), so session state is
    // main-thread-only and emits are called directly from the handlers.
    private var isBufferingState: Boolean = false
    private var hasEmittedLoad: Boolean = false
    private var hasEmittedPlaying: Boolean = false
    // Coalesces burst ES events into one tracks emission per loop turn.
    private var tracksEmitScheduled: Boolean = false
    // Throttle bookkeeping for onProgress (elapsedRealtime ms).
    private var lastProgressEmitAt: Long = 0
    // Cached from LengthChanged so per-tick handlers skip the JNI
    // mediaPlayer.length query on every TimeChanged.
    private var cachedLengthMs: Long = 0
    // Position-restore net: same-URI reloads (repeat/hardware toggles) must
    // continue where playback was, not restart at zero.
    private var lastTimeMs: Long = 0
    private var pendingRestoreMs: Long = 0

    private val eventListener = MediaPlayer.EventListener { event ->
      when (event.type) {
        MediaPlayer.Event.Buffering -> handleBuffering(event.buffering)
        MediaPlayer.Event.Playing -> handlePlaying()
        MediaPlayer.Event.Paused -> handlePaused()
        MediaPlayer.Event.Stopped -> handleStopped()
        MediaPlayer.Event.TimeChanged -> handleTimeChanged(event.timeChanged)
        MediaPlayer.Event.EndReached -> handleEndReached()
        MediaPlayer.Event.EncounteredError -> handleError()
        MediaPlayer.Event.LengthChanged -> handleLengthChanged(event.lengthChanged)
        MediaPlayer.Event.Vout -> {
          if (event.voutCount > 0) maybeEmitLoad()
        }
        MediaPlayer.Event.ESAdded,
        MediaPlayer.Event.ESDeleted,
        MediaPlayer.Event.ESSelected -> {
          applyTrackSelection()
          scheduleTracksEmit()
        }
      }
    }

    init {
      mediaPlayer.setEventListener(eventListener)
      // libvlc's scale math assumes a fullscreen surface: it swaps width and
      // height whenever the surface orientation mismatches the DEVICE
      // orientation (VideoHelper.updateVideoSurfaces), which wrecks every
      // scale type for an embedded landscape view inside a portrait app —
      // cover/stretch showed huge black bars. This opt-in derives orientation
      // from the actual surface bounds instead.
      mediaPlayer.setUseOrientationFromBounds(true)
    }

    // ---- libvlc event handlers ----

    private fun handleBuffering(percent: Float) {
      if (percent < 100f) {
        isBufferingState = true
        emitBuffer(isBuffering = true, percent = percent)
      } else if (isBufferingState) {
        isBufferingState = false
        emitBuffer(isBuffering = false, percent = 100f)
      }
    }

    private fun handlePlaying() {
      requestAudioFocusIfNeeded()
      attemptPositionRestore()
      if (isBufferingState) {
        isBufferingState = false
        emitBuffer(isBuffering = false, percent = 100f)
      }
      maybeEmitLoad()
      if (!hasEmittedPlaying) {
        hasEmittedPlaying = true
        emitPlaying(loadedUri)
      }
      emitPlaybackState(true)
      applyTrackSelection()
    }

    private fun handlePaused() {
      emitPlaybackState(false)
    }

    private fun handleStopped() {
      isBufferingState = false
      emitPlaybackState(false)
    }

    // libvlc never delivers a TimeChanged at exactly `length` — VOD ends with
    // time still short of the duration. Emit a synthetic 100% so consumers see
    // a clean tail before onEnd.
    private fun handleEndReached() {
      isBufferingState = false
      val uri = loadedUri
      if (cachedLengthMs > 0L) emitProgress(cachedLengthMs, cachedLengthMs, 100f)
      emitEnd(uri)
      // libvlc 3.x leaves the player terminated after EndReached — seek-to-0
      // + play() doesn't work, only a full prepare() restarts cleanly.
      if (desiredRepeat && uri != null && attachedToWindow && !released) {
        lastTimeMs = 0 // the loop restart must begin at zero, not near the end
        ensureSession().prepare(uri, desiredMediaOptions, autoPlay = true)
      }
    }

    private fun handleError() {
      isBufferingState = false
      emitError("VLC playback error" + (loadedUri?.let { " for ${redactUri(it)}" } ?: ""))
    }

    private fun handleTimeChanged(time: Long) {
      lastTimeMs = time.coerceAtLeast(0L)
      // Native-side throttle: every emission crosses the bridge, which adds
      // up fast in multi-player grids. Position restore still sees every
      // tick via lastTimeMs above.
      val now = SystemClock.elapsedRealtime()
      if (lastProgressEmitAt > 0 && now - lastProgressEmitAt < progressUpdateIntervalMs) return
      lastProgressEmitAt = now
      val safeTime = time.coerceAtLeast(0L)
      if (cachedLengthMs <= 0L) {
        // Live stream: no duration/percent, but elapsed time is still useful
        // (recording timers, "on air for" displays).
        emitProgress(safeTime, 0L, 0f)
        return
      }
      val percent = (safeTime.toFloat() / cachedLengthMs * 100f).coerceIn(0f, 100f)
      emitProgress(safeTime, cachedLengthMs, percent)
    }

    private fun handleLengthChanged(lengthMs: Long) {
      cachedLengthMs = lengthMs.coerceAtLeast(0L)
      // Playing often arrives before the duration does; retry the restore.
      attemptPositionRestore()
      maybeEmitLoad()
    }

    // VOD only (live has no position). Waits until BOTH playing and duration
    // are known — consuming the pending value early restarts at zero.
    private fun attemptPositionRestore() {
      if (pendingRestoreMs <= 0L || cachedLengthMs <= 0L) return
      if (!isPlaying()) return
      val restoreMs = pendingRestoreMs
      pendingRestoreMs = 0
      if (restoreMs < cachedLengthMs) seekTo(restoreMs)
    }

    private fun maybeEmitLoad() {
      if (hasEmittedLoad) return
      val track = runCatching { mediaPlayer.currentVideoTrack }.getOrNull()
      val w = track?.width ?: 0
      val h = track?.height ?: 0
      // Need duration (VOD) or dimensions (live) — otherwise payload is empty.
      if (cachedLengthMs <= 0L && (w == 0 || h == 0)) return
      hasEmittedLoad = true
      emitLoad(cachedLengthMs, w, h)
    }

    // ---- Tracks ----

    // Reconciles desired audio/text selection against the live track lists.
    // Idempotent and re-entered from prop changes, Playing, and ES events —
    // tracks appear asynchronously, so a desired id is applied whenever its
    // track shows up. libvlc lists include a "Disable" pseudo-track (id -1)
    // which maps to our 'none'.
    fun applyTrackSelection() {
      applySelection(desiredAudioTrackId, mediaPlayer.audioTrack) { id ->
        mediaPlayer.setAudioTrack(id)
      }
      applySelection(desiredTextTrackId, mediaPlayer.spuTrack) { id ->
        mediaPlayer.setSpuTrack(id)
      }
    }

    private inline fun applySelection(desired: String, current: Int, select: (Int) -> Unit) {
      when (desired) {
        "auto" -> return // don't fight libvlc's default selection
        "none" -> if (current != -1) runCatching { select(-1) }
        else -> {
          val id = desired.toIntOrNull() ?: return
          if (current != id) runCatching { select(id) }
        }
      }
    }

    private fun scheduleTracksEmit() {
      if (tracksEmitScheduled) return
      tracksEmitScheduled = true
      post {
        tracksEmitScheduled = false
        emitTracksNow()
      }
    }

    private fun emitTracksNow() {
      if (released) return
      val payload = Arguments.createMap()
      payload.putArray("audioTracks", describeTracks(
        runCatching { mediaPlayer.audioTracks }.getOrNull(),
        runCatching { mediaPlayer.audioTrack }.getOrDefault(-1),
      ))
      payload.putArray("textTracks", describeTracks(
        runCatching { mediaPlayer.spuTracks }.getOrNull(),
        runCatching { mediaPlayer.spuTrack }.getOrDefault(-1),
      ))
      emitEvent("topTracksChanged", payload)
    }

    private fun describeTracks(
      tracks: Array<MediaPlayer.TrackDescription>?,
      currentId: Int,
    ): WritableArray {
      val array = Arguments.createArray()
      tracks?.forEach { track ->
        if (track.id == -1) return@forEach // libvlc's "Disable" pseudo-track
        val map = Arguments.createMap()
        map.putString("id", track.id.toString())
        map.putString("name", track.name ?: "")
        // TrackDescription carries no language; the name usually embeds it.
        map.putString("language", "")
        map.putBoolean("selected", track.id == currentId)
        array.pushMap(map)
      }
      return array
    }

    // ---- Public API ----

    fun matches(init: List<String>): Boolean = initOptions == init

    fun currentTimeMs(): Long = lastTimeMs

    fun lengthMs(): Long = cachedLengthMs

    fun prepare(uri: Uri, mediaOptions: List<String>, autoPlay: Boolean) {
      Log.i(TAG, "Loading media ${redactUri(uri)} with mediaOptions [${mediaOptions.joinToString(", ")}]")
      // Same-URI reload continues at the previous position; a new source
      // starts clean at zero. A fresh session consumes the background
      // handover (savedResume*) captured when the previous session died.
      pendingRestoreMs = when {
        uri == loadedUri && lastTimeMs > 1500 -> lastTimeMs
        loadedUri == null && uri == savedResumeUri && savedResumeMs > 1500 -> savedResumeMs
        else -> 0
      }
      savedResumeUri = null
      savedResumeMs = 0
      if (pendingRestoreMs == 0L) lastTimeMs = 0
      loadedUri = uri
      playWhenAttached = autoPlay
      hasEmittedLoad = false
      hasEmittedPlaying = false
      lastReportedIsPlaying = -1
      isBufferingState = false
      cachedLengthMs = 0

      runCatching {
        if (mediaPlayer.isPlaying) mediaPlayer.stop()
      }
      mediaPlayer.media?.release()

      val media = Media(libVlc, uri)
      // User options must be added BEFORE the HW decoder configuration —
      // setDefaultMediaPlayerOptions / setHWDecoderEnabled auto-inject
      // `:network-caching=1500` / `:file-caching=1500` unless the flag is
      // already set, which would shadow user-provided values.
      mediaOptions.forEach(media::addOption)
      // Seamless looping happens inside libvlc's input layer — no per-loop
      // events, no re-open of network sources. Toggling the prop reloads
      // the media (see setRepeatMode); handleEndReached's repeat branch is
      // the safety net for streams where input-repeat doesn't engage.
      if (desiredRepeat) media.addOption(":input-repeat=65535")
      if (desiredHardwareEnabled) {
        // setDefaultMediaPlayerOptions respects user-set `:codec=` (via
        // libvlcjni's internal mCodecOptionSet flag), so user mediaOptions
        // aren't clobbered. Internally this is `setHWDecoderEnabled(true,
        // false)` plus a few caching defaults.
        media.setDefaultMediaPlayerOptions()
      } else {
        // libvlcjni 3.x maps this to `addOption(":codec=all")`, which on
        // Android lets default capability priority pick avcodec (software)
        // instead of mediacodec.
        media.setHWDecoderEnabled(false, false)
      }
      // HTTP Referer / User-Agent. libvlc only supports these two HTTP
      // headers at the access-module level — arbitrary headers (e.g.
      // Authorization) cannot be injected. Applied after user mediaOptions
      // so the source-object form wins over a manual `mediaOptions` override.
      desiredReferer?.let { media.addOption(":http-referrer=$it") }
      desiredUserAgent?.let { media.addOption(":http-user-agent=$it") }
      // External subtitle as a media-level slave — part of the media from
      // the start, like desktop VLC's "load subtitle file". Priority 4
      // (user) makes libvlc auto-select it over container defaults.
      desiredSubtitleUri?.let { uri ->
        runCatching { media.addSlave(IMedia.Slave(IMedia.Slave.Type.Subtitle, 4, uri)) }
          .onFailure { Log.w(TAG, "addSlave failed for $uri: ${it.message}") }
      }

      mediaPlayer.media = media
      media.release()
      // Re-push a non-default rate for the new media — don't trust libvlc
      // to carry it across media changes.
      if (desiredRate != 1f) applyRate(desiredRate)

      if (autoPlay && attached) {
        playWhenReady()
      }
    }

    fun playWhenReady() {
      if (!attached) {
        playWhenAttached = true
        return
      }
      playWhenAttached = true
      runCatching { mediaPlayer.play() }.onFailure { err ->
        playWhenAttached = false
        emitError(err.message ?: "Unable to start playback")
      }
    }

    fun pause() {
      playWhenAttached = false
      runCatching { mediaPlayer.pause() }
    }

    fun stop() {
      playWhenAttached = false
      hasEmittedLoad = false
      isBufferingState = false
      cachedLengthMs = 0
      runCatching { mediaPlayer.stop() }
      mediaPlayer.media?.release()
      mediaPlayer.media = null
      loadedUri = null
    }

    fun seekTo(ms: Long) {
      runCatching { mediaPlayer.time = ms }
    }

    fun attach(layout: VLCVideoLayout) {
      if (attached) return
      // attachViews(layout, dm, subtitles, useTextureView).
      // Matches the official VLC for Android call: SurfaceView + subtitles=true.
      mediaPlayer.attachViews(layout, null, true, false)
      attached = true
      if (playWhenAttached) playWhenReady()
    }

    fun detach() {
      if (!attached) return
      runCatching { mediaPlayer.detachViews() }
      attached = false
    }

    fun applyResizeMode(mode: ResizeMode) {
      runCatching { mediaPlayer.setVideoScale(mode.toScaleType()) }
    }

    fun applyVolume(volume: Int) {
      runCatching { mediaPlayer.volume = volume.coerceIn(0, 100) }
    }

    // Rate is a request — live streams / some protocols ignore it.
    fun applyRate(rate: Float) {
      runCatching { mediaPlayer.rate = rate }
    }

    fun isPlaying(): Boolean =
      runCatching { mediaPlayer.isPlaying }.getOrDefault(false)

    fun release() {
      // stop() blocks until libvlc tears the input down — on a dead network
      // session that means waiting out network timeouts, which froze the UI
      // when called on the main thread (the official app guards the same
      // path with a stop timeout). Detach the views here, then let a
      // teardown thread absorb the blocking part. The shared LibVLC core
      // (LibVlcCorePool) is never released.
      detach()
      mediaPlayer.setEventListener(null)
      abandonAudioFocus()
      teardownExecutor.execute {
        runCatching { mediaPlayer.stop() }
        runCatching {
          mediaPlayer.media?.release()
          mediaPlayer.media = null
        }
        runCatching { mediaPlayer.release() }
      }
    }
  }

  private enum class ResizeMode {
    CONTAIN,
    COVER,
    STRETCH,
    ORIGINAL;

    fun toScaleType(): MediaPlayer.ScaleType = when (this) {
      CONTAIN -> MediaPlayer.ScaleType.SURFACE_BEST_FIT
      COVER -> MediaPlayer.ScaleType.SURFACE_FIT_SCREEN
      STRETCH -> MediaPlayer.ScaleType.SURFACE_FILL
      ORIGINAL -> MediaPlayer.ScaleType.SURFACE_ORIGINAL
    }

    companion object {
      fun fromValue(value: String?): ResizeMode = when (value?.lowercase()) {
        "cover" -> COVER
        "stretch" -> STRETCH
        "original", "center" -> ORIGINAL
        else -> CONTAIN
      }
    }
  }

  // Process-wide libvlc cores, keyed by their constructor options. A core is
  // a whole libvlc instance; the official VLC-Android app runs exactly one
  // for the entire process. Cores live until process death — apps use a
  // handful of distinct option sets at most.
  private object LibVlcCorePool {
    private val cores = HashMap<List<String>, LibVLC>()

    @Synchronized
    fun acquire(context: Context, options: List<String>): LibVLC =
      cores.getOrPut(options.toList()) {
        Log.i(TAG, "Creating shared LibVLC core for initOptions [${options.joinToString(", ")}]")
        LibVLC(context.applicationContext, ArrayList(options))
      }
  }

  private companion object {
    private const val TAG = "VlcPlayerView"
    // Serializes blocking libvlc teardowns off the main thread.
    private val teardownExecutor = java.util.concurrent.Executors.newSingleThreadExecutor { r ->
      Thread(r, "VlcPlayerView-Teardown").apply { isDaemon = true }
    }
  }
}
