package com.vlcplayer

import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.AttributeSet
import android.util.Base64
import android.util.Log
import android.view.PixelCopy
import android.view.SurfaceView
import android.widget.FrameLayout
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.ReactContext
import com.facebook.react.bridge.WritableMap
import com.facebook.react.uimanager.UIManagerHelper
import com.facebook.react.uimanager.events.Event
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer
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

  // Internal state
  private var playerSession: PlayerSession? = null
  private var attachedToWindow: Boolean = false
  private var resumeWhenActive: Boolean = false
  private var released: Boolean = false
  private var pendingApply: Boolean = false

  // PNG encoding offloaded so cmdSnapshot doesn't block the UI thread.
  private val snapshotExecutor = Executors.newSingleThreadExecutor { r ->
    Thread(r, "VlcPlayerView-Snapshot").apply { isDaemon = true }
  }
  // Reused by PixelCopy.request to avoid a Handler alloc per snapshot.
  private val mainHandler = Handler(Looper.getMainLooper())

  init {
    ProcessLifecycleOwner.get().lifecycle.addObserver(this)
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
    if (released) return
    desiredRepeat = repeat
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
      emitSnapshotResult(callId, base64 = null, error = "View released")
      return
    }
    val surfaceView = findInnerSurfaceView()
    if (surfaceView == null || surfaceView.width == 0 || surfaceView.height == 0) {
      emitSnapshotResult(callId, base64 = null, error = "Video surface not ready")
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
        emitSnapshotResult(callId, base64 = null, error = "PixelCopy failed: $result")
      }
    }, mainHandler)
  }

  private fun encodeSnapshotAsync(callId: Int, frame: Bitmap) {
    snapshotExecutor.execute {
      val result = runCatching {
        val bos = ByteArrayOutputStream(frame.width * frame.height / 2)
        frame.compress(Bitmap.CompressFormat.PNG, 100, bos)
        Base64.encodeToString(bos.toByteArray(), Base64.NO_WRAP)
      }
      frame.recycle()
      post {
        result.fold(
          onSuccess = { emitSnapshotResult(callId, base64 = it, error = null) },
          onFailure = { emitSnapshotResult(callId, base64 = null, error = it.message ?: "Snapshot encoding failed") },
        )
      }
    }
  }

  fun release() {
    if (released) return
    released = true
    shouldPlayWhenReady = false
    attachedToWindow = false
    resumeWhenActive = false
    pendingApply = false
    removeCallbacks(measureAndLayoutRunnable)
    ProcessLifecycleOwner.get().lifecycle.removeObserver(this)
    playerSession?.release()
    playerSession = null
    currentUri = null
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
    if (!released) {
      playerSession?.pause()
      playerSession?.detach()
      attachedToWindow = false
    }
    super.onDetachedFromWindow()
  }

  override fun onStop(owner: LifecycleOwner) {
    if (released) return
    resumeWhenActive = playerSession?.isPlaying() == true
    playerSession?.pause()
    playerSession?.detach()
  }

  override fun onStart(owner: LifecycleOwner) {
    if (released) return
    if (attachedToWindow) {
      playerSession?.attach(videoLayout)
    }
    val shouldResume = resumeWhenActive || shouldPlayWhenReady
    resumeWhenActive = false
    if (shouldResume && attachedToWindow && currentUri != null) {
      playerSession?.playWhenReady()
    }
  }

  // ============================================================
  // Internal helpers
  // ============================================================

  private fun parseStreamUri(url: String?): Uri? {
    val normalized = url?.trim().orEmpty()
    if (normalized.isEmpty()) return null
    val uri = runCatching { Uri.parse(normalized) }.getOrNull() ?: return null
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

  private fun emitSnapshotResult(callId: Int, base64: String?, error: String?) {
    val map = Arguments.createMap().apply {
      putInt("callId", callId)
      putString("base64", base64 ?: "")
      putString("error", error ?: "")
    }
    emitEvent("topSnapshotResult", map)
  }

  private fun emitEvent(eventName: String, payload: WritableMap) {
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
    private val libVlc = LibVLC(context.applicationContext, ArrayList(initOptions))
    private val mediaPlayer = MediaPlayer(libVlc)

    private var attached = false
    private var playWhenAttached = false
    private var loadedUri: Uri? = null

    // libvlc-android delivers MediaPlayer events on the main thread
    // (VLCObject posts them to a main-looper Handler), so session state is
    // main-thread-only and emits are called directly from the handlers.
    private var isBufferingState: Boolean = false
    private var hasEmittedLoad: Boolean = false
    // Cached from LengthChanged so per-tick handlers skip the JNI
    // mediaPlayer.length query on every TimeChanged.
    private var cachedLengthMs: Long = 0

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
      }
    }

    init {
      mediaPlayer.setEventListener(eventListener)
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
      if (isBufferingState) {
        isBufferingState = false
        emitBuffer(isBuffering = false, percent = 100f)
      }
      maybeEmitLoad()
      emitPlaying(loadedUri)
    }

    private fun handlePaused() {}

    private fun handleStopped() {
      isBufferingState = false
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
        ensureSession().prepare(uri, desiredMediaOptions, autoPlay = true)
      }
    }

    private fun handleError() {
      isBufferingState = false
      emitError("VLC playback error" + (loadedUri?.let { " for ${redactUri(it)}" } ?: ""))
    }

    private fun handleTimeChanged(time: Long) {
      if (cachedLengthMs <= 0L) return  // live stream — no meaningful progress
      val safeTime = time.coerceAtLeast(0L)
      val percent = (safeTime.toFloat() / cachedLengthMs * 100f).coerceIn(0f, 100f)
      emitProgress(safeTime, cachedLengthMs, percent)
    }

    private fun handleLengthChanged(lengthMs: Long) {
      cachedLengthMs = lengthMs.coerceAtLeast(0L)
      maybeEmitLoad()
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

    // ---- Public API ----

    fun matches(init: List<String>): Boolean = initOptions == init

    fun prepare(uri: Uri, mediaOptions: List<String>, autoPlay: Boolean) {
      Log.i(TAG, "Loading media ${redactUri(uri)} with mediaOptions [${mediaOptions.joinToString(", ")}]")
      loadedUri = uri
      playWhenAttached = autoPlay
      hasEmittedLoad = false
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
      // Safety net only: handleEndReached() actually drives repeat because
      // libvlc 3.x's seamless input-repeat is unreliable.
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
      stop()
      detach()
      mediaPlayer.setEventListener(null)
      mediaPlayer.release()
      libVlc.release()
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

  private companion object {
    private const val TAG = "VlcPlayerView"
  }
}
