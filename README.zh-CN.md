# @wekor/react-native-vlc-player

[English](./README.md) · **中文**

iOS + Android 全能视频播放器，**一行代码就能播**。

```tsx
import { VlcPlayerView } from '@wekor/react-native-vlc-player';

<VlcPlayerView
  url="rtsp://192.168.1.10/live"
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

要求 React Native 0.74+ 并启用 New Architecture。

---

## 用法

### 最简

```tsx
<VlcPlayerView url={url} style={{ flex: 1 }} />
```

### 控制播放

```tsx
const [paused, setPaused] = useState(false);

<VlcPlayerView
  url={url}
  paused={paused}
  muted={isMuted}
  volume={0.8}
/>
```

### 加载动画

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

### 进度条

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

### 截图

```tsx
const ref = useRef<VlcPlayerHandle>(null);

<VlcPlayerView ref={ref} url={url} />
<Button onPress={async () => {
  const base64Png = await ref.current?.snapshot();
  // 存盘 / 上传 / 显示
}} />
```

---

## Props

| Prop | 类型 | 默认 | 说明 |
|---|---|---|---|
| `url` | `string` | — | 视频地址（必填） |
| `style` | `ViewStyle` | — | 标准 RN style |
| `paused` | `boolean` | `false` | 暂停 |
| `muted` | `boolean` | `false` | 静音 |
| `volume` | `number` | `1` | 音量 0..1 |
| `repeat` | `boolean` | `false` | 循环播放 |
| `resizeMode` | `'contain' \| 'cover' \| 'stretch' \| 'original'` | `'contain'` | 缩放方式 |
| `initOptions` | `string[]` | `[]` | libvlc 实例选项，如 `['--rtsp-tcp']` |
| `mediaOptions` | `string[]` | `[]` | libvlc media 选项，如 `[':network-caching=200']` |

## 事件

| 事件 | 时机 | Payload |
|---|---|---|
| `onLoad` | 元数据解析完成，还没出画面 | `{ duration, videoSize: { width, height } }` |
| `onPlaying` | 第一帧画出 | — |
| `onBuffer` | 缓冲状态变化（启动 + 播放中卡顿） | `{ isBuffering, percent }` |
| `onProgress` | 播放进度（每 500ms，点播） | `{ currentTime, duration, percent }` |
| `onEnd` | 播放完毕（点播） | — |
| `onError` | 出错 | `{ message }` |

字段说明：
- `duration` / `currentTime` 单位是毫秒
- `percent` 在 `onBuffer` 是 0..100 的缓冲百分比；在 `onProgress` 是 0..100 的播放进度

## ref 方法

```ts
interface VlcPlayerHandle {
  play(): void;
  pause(): void;
  seek(seconds: number): void;        // 跳到指定秒（点播）
  snapshot(): Promise<string>;        // 截图，返回 base64 PNG
  reload(): void;                     // 重新拉流，断流恢复用
}
```

---

## 遇到问题？

默认配置满足不了你的场景时，用 `initOptions` / `mediaOptions` 传 libvlc 原生选项。这是 libvlc 的两层配置体系，**用过 VLC 的人会熟**。

### 公网摄像头连不上 / 卡住

通常是 NAT 挡了 UDP。切到 TCP：

```tsx
<VlcPlayerView
  url="rtsp://camera.public.ip/live"
  initOptions={['--rtsp-tcp']}
/>
```

### 延迟太高，想更实时

```tsx
<VlcPlayerView
  url={url}
  mediaOptions={[':network-caching=20', ':clock-jitter=0']}
/>
```

### 弱网经常卡，想更稳

```tsx
<VlcPlayerView
  url={url}
  mediaOptions={[':network-caching=3000']}
/>
```

### 花屏 / 颜色错乱

硬件解码器对某些视频不兼容，关掉走软解：

```tsx
<VlcPlayerView
  url={url}
  mediaOptions={[':no-hw-dec']}
/>
```

### 只要音频不要视频（或反之）

```tsx
<VlcPlayerView url={url} mediaOptions={[':no-video']} />
<VlcPlayerView url={url} mediaOptions={[':no-audio']} />
```

> `initOptions` 前缀用 `--`，`mediaOptions` 前缀用 `:`。完整选项列表见 [VLC 官方文档](https://wiki.videolan.org/VLC_command-line_help/)。
>
> 大多数 caching / 网络 / 解码相关选项放在 `mediaOptions` 里更可靠；libvlc 实例级别（音频输出模块等）才放 `initOptions`。

---

## 系统要求

React Native 0.74+，已启用 New Architecture（Fabric）。iOS 15.1+，Android 7.0+。

Legacy bridge 不支持，请用 [react-native-vlc-media-player](https://github.com/razorRun/react-native-vlc-media-player)。

## License

MIT
