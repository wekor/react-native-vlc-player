# @wekor/react-native-vlc-player

**English** · [中文](./README.zh-CN.md)

A fully-featured video player for iOS + Android. **One line and it plays.**

```tsx
import { VlcPlayerView } from '@wekor/react-native-vlc-player';

<VlcPlayerView
  source="rtsp://192.168.1.10/live"
  style={{ flex: 1 }}
/>
```

Supports RTSP, RTMP, HLS, HTTP MP4 and local files — anything VLC can play. The library picks the right strategy based on the URL; **no extra configuration needed**.

---

## Install

```sh
npm install @wekor/react-native-vlc-player
cd ios && pod install
```

Requires React Native 0.80+ with the New Architecture enabled.

---

## Usage

### Minimal

```tsx
<VlcPlayerView source={url} style={{ flex: 1 }} />
```

### Playback control

```tsx
const [paused, setPaused] = useState(false);

<VlcPlayerView
  source={url}
  paused={paused}
  muted={isMuted}
  volume={0.8}
  rate={1.5}
/>
```

### Loading indicator

```tsx
const [loading, setLoading] = useState(true);

<View>
  <VlcPlayerView
    source={url}
    onBuffer={({ nativeEvent: { isBuffering } }) => setLoading(isBuffering)}
  />
  {loading && <ActivityIndicator style={StyleSheet.absoluteFill} />}
</View>
```

### Progress bar

```tsx
const [progress, setProgress] = useState({ currentTime: 0, duration: 0 });
const ref = useRef<VlcPlayerHandle>(null);

<VlcPlayerView
  ref={ref}
  source={url}
  onProgress={(e) => setProgress(e.nativeEvent)}
/>
<Slider
  value={progress.currentTime}
  maximumValue={progress.duration}
  onSlidingComplete={(t) => ref.current?.seek(t)}
/>
```

### Snapshot

```tsx
const ref = useRef<VlcPlayerHandle>(null);

<VlcPlayerView ref={ref} source={url} />
<Button onPress={async () => {
  const uri = await ref.current?.snapshot(); // file:// URI of a PNG
  // display directly: <Image source={{ uri }} />
  // The file lives in the app cache dir — copy it out for persistence.
}} />
```

---

## Props

| Prop | Type | Default | Description |
|---|---|---|---|
| `source` | `string \| { uri: string; referer?: string; userAgent?: string }` | — | Video source (required). String form is shorthand for `{ uri: ... }`. Object form supports `Referer` / `User-Agent` headers (the only HTTP headers libvlc can inject). |
| `style` | `ViewStyle` | — | Standard RN style |
| `paused` | `boolean` | `false` | Pause playback |
| `muted` | `boolean` | `false` | Mute audio |
| `volume` | `number` | `1` | Volume, 0..1 |
| `rate` | `number` | `1` | Playback rate (1 = normal). Changing it does not reload the media. VOD only — live streams and some protocols ignore the request. |
| `repeat` | `boolean` | `false` | Loop playback (VOD). Toggling it reloads the media; the playback position is preserved. See the `onEnd` note below for per-platform loop behavior. |
| `resizeMode` | `'contain' \| 'cover' \| 'stretch' \| 'original'` | `'contain'` | Scaling mode |
| `hardwareDecoding` | `boolean` | `true` | Toggle hardware video decoding. Set `false` to force software decoding when the HW decoder produces artifacts. |
| `initOptions` | `string[]` | `[]` | libvlc instance options, e.g. `['--rtsp-tcp']` |
| `mediaOptions` | `string[]` | `[]` | libvlc media options, e.g. `[':network-caching=200']` |
| `audioTrack` | `string` | `'auto'` | Audio track selection: `'auto'`, `'none'`, or a track id from `onTracksChanged`. Survives media reloads. |
| `textTrack` | `string` | `'auto'` | Subtitle track selection: `'auto'`, `'none'`, or a track id from `onTracksChanged`. |
| `subtitleUri` | `string` | — | External subtitle file (`file://` or `http(s)://`, e.g. `.srt`). Loaded with the media and auto-selected. |
| `progressUpdateInterval` | `number` | `500` | Minimum ms between `onProgress` events (native-side throttle — raise it for multi-player grids). |

## Events

| Event | When it fires | Payload |
|---|---|---|
| `onLoad` | Metadata parsed, before the first frame (once per media) | `{ duration, videoWidth, videoHeight }` |
| `onPlaying` | First frame rendered (once per media) | — |
| `onPlaybackStateChanged` | Play/pause ground truth — includes native-initiated pauses (phone call, headphones unplugged, backgrounding) that the `paused` prop can't know about | `{ isPlaying }` |
| `onBuffer` | Buffering state changes (startup + stalls) | `{ isBuffering, percent }` |
| `onProgress` | Playback progress. Live streams report `currentTime` with `duration: 0` | `{ currentTime, duration, percent }` |
| `onEnd` | Playback finished (VOD) | — |
| `onError` | Playback error | `{ message }` |
| `onTracksChanged` | Available audio/subtitle tracks changed (tracks resolve asynchronously after playback starts) | `{ audioTracks: Track[], textTracks: Track[] }`, each `{ id, name, language, selected }` |

Notes:
- `duration` / `currentTime` are in milliseconds.
- In `onBuffer`, `percent` is the buffer fill 0..100; in `onProgress` it's the playback progress 0..100.
- With `repeat` enabled, loop behavior differs per platform: Android loops seamlessly inside libvlc and fires no per-loop events; iOS (VLCKit 4 alpha) briefly reloads between passes and fires `onEnd` each pass. Don't rely on `onEnd` for loop counting.
- The player follows platform audio conventions automatically: it pauses when headphones (wired or Bluetooth) disconnect and on audio interruptions (phone calls, alarms; audio-focus loss on Android). After an interruption it resumes only when the OS says it should (iOS `ShouldResume` / Android transient-focus regain); it never auto-resumes after a headphone unplug. These native pauses do not mutate the `paused` prop — listen to `onPlaybackStateChanged` for the ground truth.

### Track selection & subtitles

```tsx
const [tracks, setTracks] = useState({ audioTracks: [], textTracks: [] });
const [audioTrack, setAudioTrack] = useState('auto');
const [textTrack, setTextTrack] = useState('auto');

<VlcPlayerView
  source={url}
  audioTrack={audioTrack}                    // 'auto' | 'none' | track id
  textTrack={textTrack}
  subtitleUri="file:///path/to/movie.srt"    // optional external subtitle
  onTracksChanged={(e) => setTracks(e.nativeEvent)}
/>

// Render a menu from tracks.audioTracks / tracks.textTracks and feed the
// chosen id back into the prop. Subtitles are rendered by libvlc inside
// the video — no overlay work needed.
```

Prefer a language over an explicit track? Skip the props and let libvlc pick
by preference:

```tsx
<VlcPlayerView source={url} mediaOptions={[':audio-language=zh', ':sub-language=zh']} />
```

Notes:
- **Subtitles are usually off under `'auto'`** — like desktop VLC, libvlc only
  auto-enables a text track when the container marks one as default or a
  language preference matches. Select a track id (or set `:sub-language=`)
  to show subtitles.
- **HLS track ids are not stable**: switching a rendition can tear down and
  recreate its track under a new id. Rebuild your menu from every
  `onTracksChanged` and re-resolve any id you held onto (embedded tracks in
  MP4/MKV don't have this problem).

## Imperative methods (ref)

```ts
interface VlcPlayerHandle {
  play(): void;
  pause(): void;
  seek(seconds: number): void;        // Seek to second (VOD)
  snapshot(): Promise<string>;        // Snapshot, resolves to a file:// PNG URI
  reload(): void;                     // Reconnect the stream
}
```

---

## Troubleshooting

When the defaults don't fit your scenario, drop down to raw libvlc options via `initOptions` / `mediaOptions`. It's libvlc's two-level configuration — **familiar if you've used VLC**.

### Public camera won't connect / hangs

Usually NAT blocking UDP. Switch to TCP:

```tsx
<VlcPlayerView
  source="rtsp://camera.public.ip/live"
  initOptions={['--rtsp-tcp']}
/>
```

### Latency too high, want it more real-time

```tsx
<VlcPlayerView
  source={url}
  mediaOptions={[':network-caching=20', ':clock-jitter=0']}
/>
```

### Stalls on flaky networks, want it more stable

```tsx
<VlcPlayerView
  source={url}
  mediaOptions={[':network-caching=3000']}
/>
```

### Artifacts / wrong colors / decode failures

The hardware decoder may not support the stream. Force software decoding:

```tsx
<VlcPlayerView
  source={url}
  hardwareDecoding={false}
/>
```

Changing `hardwareDecoding` reloads the media. Under the hood:

- iOS (VLCKit 4) adds `:codec=avcodec,all` so libvlc tries the FFmpeg software
  decoder before VideoToolbox. Same path as VLC for iOS's Settings → Hardware
  decoding → Off.
- Android (libvlc-android 3.x) calls `Media.setHWDecoderEnabled(false, false)`,
  which is what VLC for Android's Settings → Hardware acceleration →
  Disabled does.

Do not also pass `:codec=...` or `:no-hw-dec` in `mediaOptions` — the two
platforms use different underlying option strings and your override will be
clobbered.

### Audio only (or video only)

```tsx
<VlcPlayerView source={url} mediaOptions={[':no-video']} />
<VlcPlayerView source={url} mediaOptions={[':no-audio']} />
```

### Stream is blocked by Referer anti-hotlink check (403 / 404)

Some CDNs and video hosts reject requests where the `Referer` header doesn't
match an allowlisted domain. Pass `Referer` via the source object:

```tsx
<VlcPlayerView
  source={{
    uri: 'https://cdn.example.com/anti-hotlink.m3u8',
    referer: 'https://www.example.com/',
    userAgent: 'Mozilla/5.0',  // optional
  }}
/>
```

> **libvlc only supports `Referer` and `User-Agent`** — arbitrary HTTP
> headers (e.g. `Authorization: Bearer ...`, `X-Custom-*`) cannot be
> injected because libvlc's HTTP access module doesn't expose them. If
> your stream needs bearer-token auth, put the token in the URL query
> string or use HTTP Basic Auth (`https://user:pass@host/...`).

> `initOptions` use the `--` prefix; `mediaOptions` use the `:` prefix. See the [VLC command-line reference](https://wiki.videolan.org/VLC_command-line_help/) for the full list.
>
> Most caching / network / decoding options are more reliable as `mediaOptions`. Use `initOptions` only for libvlc-instance-level concerns (audio output module, etc.).

---

## Requirements

React Native 0.80+ with the New Architecture (Fabric) enabled. iOS 15.1+, Android 7.0+.

The legacy bridge is not supported — use [react-native-vlc-media-player](https://github.com/razorRun/react-native-vlc-media-player) on the old architecture.

## License

MIT
