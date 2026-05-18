import type { ViewProps } from 'react-native';

/** 视频缩放方式 */
export type VlcPlayerResizeMode = 'contain' | 'cover' | 'stretch' | 'original';

/** `onLoad` 事件 payload —— 元数据解析完成 */
export type VlcPlayerLoadPayload = {
  /** 视频总时长，毫秒。直播流为 0。 */
  duration: number;
  /** 视频原始分辨率。 */
  videoSize: { width: number; height: number };
};

/** `onBuffer` 事件 payload —— 缓冲状态变化 */
export type VlcPlayerBufferPayload = {
  /** 当前是否在缓冲。`true` 时显示 loading 动画，`false` 时隐藏。 */
  isBuffering: boolean;
  /** 缓冲进度，0..100。 */
  percent: number;
};

/** `onProgress` 事件 payload —— 播放进度（仅点播） */
export type VlcPlayerProgressPayload = {
  /** 已播放时长，毫秒。 */
  currentTime: number;
  /** 视频总时长，毫秒。 */
  duration: number;
  /** 播放进度，0..100。 */
  percent: number;
};

/** `onError` 事件 payload */
export type VlcPlayerErrorPayload = {
  message: string;
};

export type VlcPlayerViewProps = ViewProps & {
  /** 视频/流地址。RTSP / RTMP / HTTP(S) / HLS / file:// 都支持。 */
  url?: string;

  /** 暂停。受控属性。@default false */
  paused?: boolean;
  /** 静音。@default false */
  muted?: boolean;
  /** 音量，0..1。@default 1 */
  volume?: number;
  /** 播放完毕循环（仅点播）。@default false */
  repeat?: boolean;

  /** 视频在容器内的缩放方式。@default 'contain' */
  resizeMode?: VlcPlayerResizeMode;

  /**
   * libvlc 实例级别选项（`--` 前缀，传给 LibVLC 构造函数）。
   * 用于配置音频输出模块、verbose 日志等 libvlc 全局设置。
   * 例：`['--rtsp-tcp']`
   *
   * 大多数场景下推荐用 `mediaOptions`，更可靠。
   */
  initOptions?: readonly string[];

  /**
   * libvlc media 级别选项（`:` 前缀，传给 Media.addOption）。
   * 用于配置当前媒体的 caching / 网络 / 解码等行为。
   * 例：`[':network-caching=200', ':no-hw-dec']`
   */
  mediaOptions?: readonly string[];

  /** 媒体元数据已解析（duration / 视频尺寸已知），还没出画面。 */
  onLoad?: (event: { nativeEvent: VlcPlayerLoadPayload }) => void;
  /** 第一帧画出，真正开始播放。 */
  onPlaying?: () => void;
  /** 缓冲状态变化（启动 + 播放中卡顿）。 */
  onBuffer?: (event: { nativeEvent: VlcPlayerBufferPayload }) => void;
  /** 播放进度（每 ~500ms 触发，仅点播）。 */
  onProgress?: (event: { nativeEvent: VlcPlayerProgressPayload }) => void;
  /** 播放完毕（仅点播）。 */
  onEnd?: () => void;
  /** 出错。 */
  onError?: (event: { nativeEvent: VlcPlayerErrorPayload }) => void;
};

/** 通过 ref 拿到的命令式 API。 */
export type VlcPlayerHandle = {
  /** 开始播放。 */
  play: () => void;
  /** 暂停播放。 */
  pause: () => void;
  /** 跳转到指定秒（仅点播）。 */
  seek: (seconds: number) => void;
  /** 截图，返回 base64 编码的 PNG。 */
  snapshot: () => Promise<string>;
  /** 重新拉流，断流恢复用。 */
  reload: () => void;
};
