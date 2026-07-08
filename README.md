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

Requires React Native 0.74+ with the New Architecture enabled.

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
    onBuffer={({ isBuffering }) => setLoading(isBuffering)}
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
  onProgress={setProgress}
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
| `repeat` | `boolean` | `false` | Loop playback (VOD). Toggling it reloads the media and restarts from the beginning, like `hardwareDecoding`. See the `onEnd` note below for per-platform loop behavior. |
| `resizeMode` | `'contain' \| 'cover' \| 'stretch' \| 'original'` | `'contain'` | Scaling mode |
| `hardwareDecoding` | `boolean` | `true` | Toggle hardware video decoding. Set `false` to force software decoding when the HW decoder produces artifacts. |
| `initOptions` | `string[]` | `[]` | libvlc instance options, e.g. `['--rtsp-tcp']` |
| `mediaOptions` | `string[]` | `[]` | libvlc media options, e.g. `[':network-caching=200']` |

## Events

| Event | When it fires | Payload |
|---|---|---|
| `onLoad` | Metadata parsed, before the first frame | `{ duration, videoSize: { width, height } }` |
| `onPlaying` | First frame rendered | — |
| `onBuffer` | Buffering state changes (startup + stalls) | `{ isBuffering, percent }` |
| `onProgress` | Playback progress (every 500ms, VOD only) | `{ currentTime, duration, percent }` |
| `onEnd` | Playback finished (VOD) | — |
| `onError` | Playback error | `{ message }` |

Notes:
- `duration` / `currentTime` are in milliseconds.
- In `onBuffer`, `percent` is the buffer fill 0..100; in `onProgress` it's the playback progress 0..100.
- With `repeat` enabled, loop behavior differs per platform: Android loops seamlessly inside libvlc and fires no per-loop events; iOS loops via VLCMediaListPlayer's native repeat mode and fires `onEnd` each pass. Don't rely on `onEnd` for loop counting.

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

- iOS (MobileVLCKit 3) adds `:codec=avcodec,all` so libvlc tries the FFmpeg software
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

React Native 0.74+ with the New Architecture (Fabric) enabled. iOS 15.1+, Android 7.0+.

The legacy bridge is not supported — use [react-native-vlc-media-player](https://github.com/razorRun/react-native-vlc-media-player) on the old architecture.

## License

MIT
