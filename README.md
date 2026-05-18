# @wekor/react-native-vlc-player

**English** · [中文](./README.zh-CN.md)

A fully-featured video player for iOS + Android. **One line and it plays.**

```tsx
import { VlcPlayerView } from '@wekor/react-native-vlc-player';

<VlcPlayerView
  url="rtsp://192.168.1.10/live"
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
<VlcPlayerView url={url} style={{ flex: 1 }} />
```

### Playback control

```tsx
const [paused, setPaused] = useState(false);

<VlcPlayerView
  url={url}
  paused={paused}
  muted={isMuted}
  volume={0.8}
/>
```

### Loading indicator

```tsx
const [loading, setLoading] = useState(true);

<View>
  <VlcPlayerView
    url={url}
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
  url={url}
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

<VlcPlayerView ref={ref} url={url} />
<Button onPress={async () => {
  const base64Png = await ref.current?.snapshot();
  // save / upload / display
}} />
```

---

## Props

| Prop | Type | Default | Description |
|---|---|---|---|
| `url` | `string` | — | Video source (required) |
| `style` | `ViewStyle` | — | Standard RN style |
| `paused` | `boolean` | `false` | Pause playback |
| `muted` | `boolean` | `false` | Mute audio |
| `volume` | `number` | `1` | Volume, 0..1 |
| `repeat` | `boolean` | `false` | Loop playback |
| `resizeMode` | `'contain' \| 'cover' \| 'stretch' \| 'original'` | `'contain'` | Scaling mode |
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

## Imperative methods (ref)

```ts
interface VlcPlayerHandle {
  play(): void;
  pause(): void;
  seek(seconds: number): void;        // Seek to second (VOD)
  snapshot(): Promise<string>;        // Snapshot, returns base64 PNG
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
  url="rtsp://camera.public.ip/live"
  initOptions={['--rtsp-tcp']}
/>
```

### Latency too high, want it more real-time

```tsx
<VlcPlayerView
  url={url}
  mediaOptions={[':network-caching=20', ':clock-jitter=0']}
/>
```

### Stalls on flaky networks, want it more stable

```tsx
<VlcPlayerView
  url={url}
  mediaOptions={[':network-caching=3000']}
/>
```

### Artifacts / wrong colors

The hardware decoder may not support the stream. Force software decoding:

```tsx
<VlcPlayerView
  url={url}
  mediaOptions={[':no-hw-dec']}
/>
```

### Audio only (or video only)

```tsx
<VlcPlayerView url={url} mediaOptions={[':no-video']} />
<VlcPlayerView url={url} mediaOptions={[':no-audio']} />
```

> `initOptions` use the `--` prefix; `mediaOptions` use the `:` prefix. See the [VLC command-line reference](https://wiki.videolan.org/VLC_command-line_help/) for the full list.
>
> Most caching / network / decoding options are more reliable as `mediaOptions`. Use `initOptions` only for libvlc-instance-level concerns (audio output module, etc.).

---

## Requirements

React Native 0.74+ with the New Architecture (Fabric) enabled. iOS 15.1+, Android 7.0+.

The legacy bridge is not supported — use [react-native-vlc-media-player](https://github.com/razorRun/react-native-vlc-media-player) on the old architecture.

## License

MIT
