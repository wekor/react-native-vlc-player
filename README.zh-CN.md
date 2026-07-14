# @wekor/react-native-vlc-player

[English](./README.md) · **中文**

iOS + Android 全能视频播放器，**一行代码就能播**。

```tsx
import { VlcPlayerView } from '@wekor/react-native-vlc-player';

<VlcPlayerView
  source="rtsp://192.168.1.10/live"
  style={{ flex: 1 }}
/>
```

支持 RTSP、RTMP、HLS、HTTP MP4、本地文件 —— 任何 VLC 能播的都能播。库会根据 URL 自动选最合适的策略，**不需要任何额外配置**。

---

## 安装

```sh
npm install @wekor/react-native-vlc-player
cd ios && pod install
```

要求 React Native 0.80+，且启用新架构。

---

## 用法

### 最简

```tsx
<VlcPlayerView source={url} style={{ flex: 1 }} />
```

### 播放控制

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

### 加载指示

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

### 进度条

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

### 截图

```tsx
const ref = useRef<VlcPlayerHandle>(null);

<VlcPlayerView ref={ref} source={url} />
<Button onPress={async () => {
  const uri = await ref.current?.snapshot(); // PNG 的 file:// URI
  // 可直接显示：<Image source={{ uri }} />
  // 文件在应用缓存目录，需要长期保存请自行拷贝。
}} />
```

---

## Props

| Prop | 类型 | 默认 | 说明 |
|---|---|---|---|
| `source` | `string \| { uri: string; referer?: string; userAgent?: string }` | — | 视频源（必填）。字符串等价于 `{ uri: ... }`。对象形式支持 `Referer` / `User-Agent` 头（libvlc 仅支持这两个 HTTP 头）。 |
| `style` | `ViewStyle` | — | 标准 RN 样式 |
| `paused` | `boolean` | `false` | 暂停播放 |
| `muted` | `boolean` | `false` | 静音 |
| `volume` | `number` | `1` | 音量，0..1 |
| `rate` | `number` | `1` | 播放速率（1 为原速），运行时可变、不重载媒体。仅点播可靠——直播流及部分协议会忽略该请求。 |
| `repeat` | `boolean` | `false` | 循环播放（仅点播）。播放中开关会重载媒体，**播放位置会保持**。每圈行为的平台差异见下方 `onEnd` 说明。 |
| `resizeMode` | `'contain' \| 'cover' \| 'stretch' \| 'original'` | `'contain'` | 缩放方式 |
| `hardwareDecoding` | `boolean` | `true` | 硬件解码开关。花屏/颜色错乱/解码失败时设为 `false` 强制软解。 |
| `initOptions` | `string[]` | `[]` | libvlc 实例级选项，如 `['--rtsp-tcp']` |
| `mediaOptions` | `string[]` | `[]` | libvlc 媒体级选项，如 `[':network-caching=200']` |
| `audioTrack` | `string` | `'auto'` | 音轨选择：`'auto'`、`'none'`（关闭声音）、或 `onTracksChanged` 给出的轨道 id。声明式，媒体重载后自动恢复。 |
| `textTrack` | `string` | `'auto'` | 字幕轨选择：`'auto'`、`'none'`（关字幕）、或 `onTracksChanged` 给出的轨道 id。 |
| `subtitleUri` | `string` | — | 外挂字幕文件（`file://` 或 `http(s)://`，如 `.srt`）。随媒体加载并自动选中。 |
| `progressUpdateInterval` | `number` | `500` | `onProgress` 的最小触发间隔（毫秒），原生侧节流——多路宫格场景可调大。 |

## 事件

| 事件 | 触发时机 | Payload |
|---|---|---|
| `onLoad` | 元数据解析完成、首帧之前（每个媒体一次） | `{ duration, videoWidth, videoHeight }` |
| `onPlaying` | 首帧画出（每个媒体一次） | — |
| `onPlaybackStateChanged` | 播放/暂停的真实状态——包含原生自动暂停（来电、拔耳机、退后台），这些场景 `paused` prop 不会变 | `{ isPlaying }` |
| `onBuffer` | 缓冲状态变化（启动 + 播放中卡顿） | `{ isBuffering, percent }` |
| `onProgress` | 播放进度。直播流会报 `currentTime`、`duration` 为 0 | `{ currentTime, duration, percent }` |
| `onEnd` | 播放完毕（仅点播） | — |
| `onError` | 出错 | `{ message }` |
| `onTracksChanged` | 可用音轨/字幕轨变化（轨道在播放开始后异步解析出来） | `{ audioTracks: Track[], textTracks: Track[] }`，每条 `{ id, name, language, selected }` |

说明：
- `duration` / `currentTime` 单位为毫秒。
- `onBuffer` 的 `percent` 是缓冲填充 0..100；`onProgress` 的是播放进度 0..100。
- 开启 `repeat` 后每圈行为有平台差异：Android 在 libvlc 内部无缝循环、不发每圈事件；iOS（VLCKit 4 alpha）每圈之间短暂重载并各发一次 `onEnd`。勿用 `onEnd` 计圈。
- 播放器自动遵循平台音频惯例：耳机（有线/蓝牙）断开、音频中断（来电、闹钟；Android 音频焦点丢失）时自动暂停。中断结束仅在系统允许时恢复（iOS `ShouldResume` / Android 瞬时焦点回归）；拔耳机永不自动恢复。这些原生暂停不会改写 `paused` prop——用 `onPlaybackStateChanged` 获取真实状态。

### 轨道选择与字幕

```tsx
const [tracks, setTracks] = useState({ audioTracks: [], textTracks: [] });
const [audioTrack, setAudioTrack] = useState('auto');
const [textTrack, setTextTrack] = useState('auto');

<VlcPlayerView
  source={url}
  audioTrack={audioTrack}                    // 'auto' | 'none' | 轨道 id
  textTrack={textTrack}
  subtitleUri="file:///path/to/movie.srt"    // 可选：外挂字幕
  onTracksChanged={(e) => setTracks(e.nativeEvent)}
/>

// 用 tracks.audioTracks / tracks.textTracks 渲染菜单，把用户选的 id
// 传回 prop 即可。字幕由 libvlc 渲染进画面，无需任何叠加层。
```

想按语言偏好而不是具体轨道？跳过这些 prop，让 libvlc 自己挑：

```tsx
<VlcPlayerView source={url} mediaOptions={[':audio-language=zh', ':sub-language=zh']} />
```

说明：
- **`'auto'` 模式下字幕通常是关闭的**——和桌面 VLC 一样，libvlc 只在容器
  标记了默认字幕或语言偏好命中时才自动开字幕。想显示字幕就选一个轨道 id
  （或设置 `:sub-language=`）。
- **HLS 的轨道 id 不稳定**：切换 rendition 可能把轨道拆掉并以新 id 重建。
  每次 `onTracksChanged` 都重建菜单，并重新校验手里持有的 id
  （MP4/MKV 的内嵌轨道没有这个问题）。

## 命令式方法（ref）

```ts
interface VlcPlayerHandle {
  play(): void;
  pause(): void;
  seek(seconds: number): void;        // 跳转到指定秒（点播）
  snapshot(): Promise<string>;        // 截图，返回 file:// PNG URI
  reload(): void;                     // 重新拉流，断流恢复用
}
```

---

## 疑难排查

默认配置不合适时，用 `initOptions` / `mediaOptions` 直接下探到 libvlc 原始选项。这就是 libvlc 的两级配置——**用过 VLC 就熟悉**。

### 公网摄像头连不上 / 卡住

通常是 NAT 挡了 UDP，切 TCP：

```tsx
<VlcPlayerView
  source="rtsp://camera.public.ip/live"
  initOptions={['--rtsp-tcp']}
/>
```

### 延迟太高，想更实时

```tsx
<VlcPlayerView
  source={url}
  mediaOptions={[':network-caching=20', ':clock-jitter=0']}
/>
```

### 弱网卡顿，想更稳

```tsx
<VlcPlayerView
  source={url}
  mediaOptions={[':network-caching=3000']}
/>
```

### 花屏 / 颜色错乱 / 解码失败

硬件解码器可能不支持该流，强制软解：

```tsx
<VlcPlayerView
  source={url}
  hardwareDecoding={false}
/>
```

修改 `hardwareDecoding` 会重载媒体。底层实现：

- iOS（VLCKit 4）注入 `:codec=avcodec,all`，让 libvlc 优先用 FFmpeg 软解
  而不是 VideoToolbox——与 VLC iOS 官方 app 的"硬件解码：关"同路径。
- Android（libvlc-android 3.x）调用 `Media.setHWDecoderEnabled(false, false)`，
  即 VLC Android 官方 app 的"硬件加速：禁用"。

不要同时在 `mediaOptions` 里传 `:codec=...` 或 `:no-hw-dec`——两个平台底层
选项字符串不同，你的覆盖会被打掉。

### 只要声音（或只要画面）

```tsx
<VlcPlayerView source={url} mediaOptions={[':no-video']} />
<VlcPlayerView source={url} mediaOptions={[':no-audio']} />
```

### 被 Referer 防盗链拦截（403 / 404）

部分 CDN 校验 `Referer` 头，通过 source 对象传入：

```tsx
<VlcPlayerView
  source={{
    uri: 'https://cdn.example.com/anti-hotlink.m3u8',
    referer: 'https://www.example.com/',
    userAgent: 'Mozilla/5.0',  // 可选
  }}
/>
```

> **libvlc 只支持 `Referer` 和 `User-Agent`**——其他 HTTP 头
> （如 `Authorization: Bearer ...`、`X-Custom-*`）受 libvlc 网络栈限制
> 无法注入。需要 Bearer token 鉴权时，把 token 放进 URL 查询参数，
> 或用 HTTP Basic Auth（`https://user:pass@host/...`）。

> `initOptions` 用 `--` 前缀；`mediaOptions` 用 `:` 前缀。完整列表见
> [VLC 命令行参考](https://wiki.videolan.org/VLC_command-line_help/)。
>
> 大多数缓存/网络/解码选项用 `mediaOptions` 更可靠；`initOptions` 只用于
> libvlc 实例级配置（音频输出模块等）。

---

## 环境要求

React Native 0.80+，启用新架构（Fabric）。iOS 15.1+，Android 7.0+。

不支持旧架构（legacy bridge）——老架构请使用
[react-native-vlc-media-player](https://github.com/razorRun/react-native-vlc-media-player)。

## 许可

MIT
