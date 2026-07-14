# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`@wekor/react-native-vlc-player` — a Fabric-only React Native video player wrapping VLCKit (iOS) and libvlc-all (Android). Targets RN 0.74+, iOS 15.1+, Android minSdk 24. The legacy bridge is **not** supported.

This is a Yarn workspaces monorepo: the library lives at the root; `example/` is an Expo Router app used to develop and test the native code. Node version is pinned in `.nvmrc` (v24.13.0). Use `yarn` — `npm` will break the workspace.

## Common commands

From the repo root:

- `yarn` — install
- `yarn typecheck` — `tsc` against the workspace (no emit)
- `yarn lint` — ESLint over `**/*.{js,ts,tsx}`; `yarn lint --fix` to auto-format
- `yarn test` — Jest (preset `@react-native/jest-preset`). Single test: `yarn test path/to/file.test.tsx -t 'name'`
- `yarn prepare` — `bob build`; produces `lib/module/` (ESM) + `lib/typescript/`. This is what consumers import.
- `yarn clean` — `del-cli lib`
- `yarn release` — `release-it`; reads conventional commits

Example app (must be used to verify native changes; JS changes hot-reload):

- `yarn example start` — Metro
- `yarn example ios` / `yarn example android` — `expo run:*`
- `yarn example build:ios` / `yarn example build:android` — what CI runs via Turbo
- `yarn example expo prebuild --platform ios|android` — regenerate native projects from `example/app.json`

Pre-commit (lefthook) runs `eslint` on staged JS/TS and a full `tsc`. Commit messages must follow Conventional Commits (commitlint enforces this).

## Architecture

### Codegen is the contract

`src/VlcPlayerViewNativeComponent.ts` is the **single source of truth** for the native surface. It declares the prop types, event payloads, and imperative commands; RN Codegen reads it at build time and generates:

- iOS: `VlcPlayerViewSpec` C++ headers (props, event emitters, component descriptor) pulled into `ios/VlcPlayerView.mm`
- Android: `VlcPlayerViewManagerInterface` + `VlcPlayerViewManagerDelegate` that `VlcPlayerViewManager.kt` implements

`codegenConfig` in `package.json` sets spec name `VlcPlayerViewSpec` and Android package `com.vlcplayer`. If you change props, events, or commands here, you must update **both** native implementations — codegen will fail the build until they match. The native files are at `ios/VlcPlayerView.{h,mm}` and `android/src/main/java/com/vlcplayer/VlcPlayer{View,ViewManager,Package}.kt`.

### JS layer (`src/`)

`VlcPlayerView.tsx` is a thin `forwardRef` wrapper around the codegen component. Its jobs:

1. Translate codegen event shapes (flat `videoWidth`/`videoHeight`) to the public API (nested `videoSize: {width, height}`) — the public types in `VlcPlayerView.types.ts` are what consumers see.
2. Normalize the public `source: string | { uri, referer?, userAgent? }` prop into the flat codegen fields `url` / `referer` / `userAgent`. Native sees three separate primitives, not a union — keeping codegen simple. `Referer` and `User-Agent` are the *only* HTTP headers libvlc can inject (its HTTP access module reads `http-referrer` and `http-user-agent` and nothing else); arbitrary headers like `Authorization` are not supported.
3. Expose imperative methods via `useImperativeHandle` that dispatch through `Commands.*` from codegen.
4. **Passthrough-first**: wire shape == public shape by design, so everything flows through `{...rest}` untouched — the wrapper only intercepts `source` normalization and the internal `onSnapshotResult`. Events keep RN's standard `{nativeEvent}` convention. When adding API, match the public shape to the wire shape so no new interception is ever needed.
5. Implement `snapshot()` as a Promise: each call gets a unique `callId`, the native side replies via the `onSnapshotResult` event, and JS resolves the matching entry from a `Map<callId, {resolve, reject}>`. Pending promises are rejected on unmount. **`onSnapshotResult` is internal — never surface it as a public prop.**

### Native lifecycle pattern (both platforms)

Props don't directly mutate the player. Both implementations split state into three tiers:

- **Desired** — what props say (`_desired*` in iOS, `desired*` in Android)
- **Loaded** — what's currently in VLC for the current media
- **Applied** — runtime-mutable state (volume/mute/pause) pushed to the active player

Prop setters update only desired state and set a `pendingApply` flag. Reconciliation happens in one place:

- iOS: end of `updateProps:oldProps:` after a batch.
- Android: `VlcPlayerViewManager.onAfterUpdateTransaction` → `view.applyPendingChanges()`.

When extending state, follow this split — don't call into VLCKit/libvlc from a prop setter directly.

Track selection (`audioTrack`/`textTrack`, `'auto' | 'none' | id`) is deliberately **declarative**: tracks resolve asynchronously and media reloads are frequent (repeat/hardwareDecoding toggles, recovery), so natives re-reconcile the desired id whenever tracks appear/change (iOS track delegate callbacks; Android ES events) and on every Playing transition. `subtitleUri` is media-defining (reload on change); the slave is added once per media on the first Playing transition (libvlc requires a running input). `onPlaybackStateChanged` is the play/pause ground truth (deduped natively) — native-initiated pauses never mutate the `paused` prop. `onProgress` is throttled natively by `progressUpdateInterval`; live streams (duration 0) still emit `currentTime`. Both platforms pool libvlc cores per distinct `initOptions` for the process lifetime (multi-player grids would otherwise pay one full core per view).

### iOS specifics (`ios/VlcPlayerView.mm`)

- Depends on `VLCKit 4.0.0a20` (alpha). Everything goes through the official `VLCMediaPlayerDelegate` — a20 made buffering percent public (`mediaPlayerBufferingChanged:` reports [0,1]; we scale to 0–100), so the a19-era private-ivar hook and raw libvlc event bridge are gone. **Delegate callbacks arrive on libvlc's event thread, NOT main** (source-verified: `VLCLibrary +load` installs `VLCEventsDefaultConfiguration` whose queue is nil, so `VLCEventsHandler` runs blocks inline) — every delegate method must hop via `VLCRunOnMain`.
- **One player per media**: a20 crashes when media is hot-swapped on a live player (`vlc_mutex_trylock` on a destroyed lock), so any media-defining prop change retires the whole player (delegate nil'ed, async stop, kept alive 3s while teardown drains) and builds a fresh one. Same-URL rebuilds restore the playback position (`_lastTimeMs`/`_pendingRestoreTimeMs`, VOD only).
- **Background black screen root cause**: the vout renders via `AVSampleBufferDisplayLayer`, iOS fails the layer on backgrounding, and upstream never flushes it (vlc@fe6e76a9 `VLCSampleBufferDisplay.m` — zero status handling). `VLCFlushFailedSampleBufferLayers` flushes it from our own view tree on foreground. Local source archives for verification: `~/Documents/vlckit-4.0.0a20` and `~/Documents/vlc-fe6e76a90/modules/video_output/apple`.
- `VlcDrawable` is an `NSObject<VLCDrawable>` forwarder, modeled on VLC-iOS's `PlaybackService`. VLCKit 4 alpha's new rendering pipeline only engages on this path; handing libvlc a `UIView` directly falls back to a vout that ignores `resizeMode`. The forwarder also disables touches on the libvlc-injected child view to suppress libvlc's built-in tap-to-pause gesture.
- libvlc never reports "connection failed" for unreachable URLs — it sits in Opening forever. `kVLCOpeningTimeout = 8.0` caps the wait and emits `onError`.
- Backgrounding: registers for `UIApplication` lifecycle notifications; pauses on background, resumes on foreground with a fallback delay because libvlc sometimes doesn't restart cleanly.
- Audio session behaviors mirror VLC-iOS: pause on `AVAudioSession` interruption (auto-resume only on the system's `ShouldResume` hint) and on headphone/Bluetooth route loss (never auto-resumes). These native pauses don't touch `_desiredPaused`; the interruption path bumps the generation, which is what re-arms `playPlayer` for the resume.

### Android specifics (`android/src/main/java/com/vlcplayer/VlcPlayerView.kt`)

- Depends on `org.videolan.android:libvlc-all:3.7.0`. Renders into a `VLCVideoLayout` that is a **child** of the `FrameLayout`, not the FrameLayout itself — `VLCVideoLayout.onAttachedToWindow` force-resets `LayoutParams` to `MATCH_PARENT`, which fights Fabric if inherited directly.
- `requestLayout` is overridden to post a manual `measure`/`layout` pump, because Fabric's `ReactViewGroup` swallows `requestLayout`. Without this, libvlc's programmatically-added inner `SurfaceView` never gets a size and `play()` stalls in `areSurfacesWaiting`.
- Snapshots use `PixelCopy.request` (SurfaceView pixels live on a Surface owned by SurfaceFlinger; this is the only public readback API). PNG encoding runs on a dedicated single-thread executor to keep the UI thread free.
- Background/foreground is observed via `ProcessLifecycleOwner` (whole-app, not per-Activity).
- Audio focus is requested when libvlc reports Playing (so a paused/failed player never holds it) and abandoned on release or permanent loss; transient loss pauses and resumes on regain. `ACTION_AUDIO_BECOMING_NOISY` (headphone unplug / BT drop) pauses with no auto-resume.
- `PlayerSession` (in the same file) wraps a `LibVLC` + `MediaPlayer` pair so the parent view doesn't have to track libvlc state directly.

### Two-level libvlc configuration

`initOptions` (`--`-prefixed) go to the `LibVLC` constructor; `mediaOptions` (`:`-prefixed) go to `Media.addOption`. Most caching/network/decoding tweaks belong in `mediaOptions` — only audio-output-module-style settings need `initOptions`. The README's Troubleshooting section documents the canonical recipes (force TCP for RTSP, lower `network-caching` for latency).

Hardware decoding is controlled via the `hardwareDecoding` boolean prop, not by passing libvlc option strings — the two platforms' underlying APIs are different (iOS injects `:codec=avcodec,all` to demote VideoToolbox; Android calls `Media.setHWDecoderEnabled(false, false)`), and mixing user-supplied `:codec=` / `:no-hw-dec` in `mediaOptions` will be clobbered by the prop's authoritative path. Both platforms' `disabled` behavior mirrors the official VLC apps (VLC-iOS Settings → Hardware decoding → Off; VLC-Android Settings → Hardware acceleration → Disabled).

### Build output (`lib/`)

`yarn prepare` runs `react-native-builder-bob`:

- `module` target → `lib/module/**` (ESM, what `package.json` `main` points to)
- `typescript` target → `lib/typescript/**` (uses `tsconfig.build.json`)

The `exports` map in `package.json` resolves `.` to `src/index.tsx` as `source` (for the example app via Metro) and `lib/module/index.js` as `default` (for published consumers). Don't commit `lib/` changes by hand — it's a build artifact.

### Example app

Expo SDK 55 with `expo-router`. `example/react-native.config.js` + `react-native-monorepo-config` wire the example to use the workspace library directly. Verifying with `fabric:true,concurrentRoot:true` in Metro logs confirms the new architecture is active — if you don't see those, native changes won't take effect even with a rebuild.
