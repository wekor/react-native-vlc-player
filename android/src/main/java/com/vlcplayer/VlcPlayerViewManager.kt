package com.vlcplayer

import com.facebook.react.bridge.ReadableArray
import com.facebook.react.module.annotations.ReactModule
import com.facebook.react.uimanager.SimpleViewManager
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.ViewManagerDelegate
import com.facebook.react.viewmanagers.VlcPlayerViewManagerDelegate
import com.facebook.react.viewmanagers.VlcPlayerViewManagerInterface

@ReactModule(name = VlcPlayerViewManager.NAME)
class VlcPlayerViewManager :
  SimpleViewManager<VlcPlayerView>(),
  VlcPlayerViewManagerInterface<VlcPlayerView> {

  private val mDelegate: ViewManagerDelegate<VlcPlayerView> =
    VlcPlayerViewManagerDelegate(this)

  override fun getDelegate(): ViewManagerDelegate<VlcPlayerView> = mDelegate

  override fun getName(): String = NAME

  override fun createViewInstance(context: ThemedReactContext): VlcPlayerView =
    VlcPlayerView(context)

  override fun onAfterUpdateTransaction(view: VlcPlayerView) {
    super.onAfterUpdateTransaction(view)
    view.applyPendingChanges()
  }

  override fun onDropViewInstance(view: VlcPlayerView) {
    view.release()
    super.onDropViewInstance(view)
  }

  // ---- Prop setters ----

  override fun setUrl(view: VlcPlayerView, value: String?) {
    view.setStreamUrl(value)
  }

  override fun setPaused(view: VlcPlayerView, value: Boolean) {
    view.setPausedState(value)
  }

  override fun setMuted(view: VlcPlayerView, value: Boolean) {
    view.setMutedState(value)
  }

  override fun setVolume(view: VlcPlayerView, value: Float) {
    view.setVolumeLevel(value)
  }

  override fun setRepeat(view: VlcPlayerView, value: Boolean) {
    view.setRepeatMode(value)
  }

  override fun setResizeMode(view: VlcPlayerView, value: String?) {
    view.setResizeMode(value)
  }

  override fun setInitOptions(view: VlcPlayerView, value: ReadableArray?) {
    view.setInitOptions(value.toStringList())
  }

  override fun setMediaOptions(view: VlcPlayerView, value: ReadableArray?) {
    view.setMediaOptions(value.toStringList())
  }

  // ---- Commands ----

  override fun play(view: VlcPlayerView) {
    view.cmdPlay()
  }

  override fun pause(view: VlcPlayerView) {
    view.cmdPause()
  }

  override fun seek(view: VlcPlayerView, seconds: Float) {
    view.cmdSeek(seconds.toDouble())
  }

  override fun snapshot(view: VlcPlayerView, callId: Int) {
    view.cmdSnapshot(callId)
  }

  override fun reload(view: VlcPlayerView) {
    view.cmdReload()
  }

  // ---- Helpers ----

  private fun ReadableArray?.toStringList(): List<String>? {
    if (this == null) return null
    val list = ArrayList<String>(size())
    for (i in 0 until size()) {
      list.add(getString(i) ?: continue)
    }
    return list
  }

  companion object {
    const val NAME = "VlcPlayerView"
  }
}
