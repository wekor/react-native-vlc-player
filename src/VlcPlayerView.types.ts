import type { ViewProps } from 'react-native';

/** 视频缩放方式 */
export type VlcPlayerResizeMode = 'contain' | 'cover' | 'stretch' | 'original';

/**
 * 视频源 / Video source.
 *
 * 字符串形式等价于 `{ uri: ... }`。对象形式允许额外配置 HTTP 请求头——
 * 注意 libvlc **只支持 `Referer` 和 `User-Agent` 两个头**，其他自定义
 * header（如 `Authorization`）受 libvlc 网络栈限制无法注入；如需 Bearer
 * token 鉴权，请把 token 放进 URL 查询参数或用 HTTP Basic Auth。
 *
 * String form is equivalent to `{ uri: ... }`. Object form allows extra
 * HTTP request configuration — but libvlc **only supports `Referer` and
 * `User-Agent` headers**, arbitrary headers (e.g. `Authorization`) cannot
 * be injected due to libvlc network stack constraints.
 */
export type VideoSource =
  | string
  | {
      /** 视频/流地址。RTSP / RTMP / HTTP(S) / HLS / file:// 都支持。 */
      uri: string;
      /**
       * HTTP `Referer` 头。常用于绕开防盗链（B 站、CDN 防盗链等都查 Referer）。
       * 仅对 HTTP/HTTPS 流有效。
       */
      referer?: string;
      /**
       * HTTP `User-Agent` 头。某些服务器对默认 libvlc UA 有限制时使用。
       * 仅对 HTTP/HTTPS 流有效。
       */
      userAgent?: string;
    };

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
  /**
   * 视频源。字符串或对象形式（对象支持 `referer` / `userAgent`）。
   *
   * @example
   * source="https://example.com/stream.m3u8"
   * @example
   * source={{ uri: 'https://example.com/stream.m3u8', referer: 'https://example.com/' }}
   */
  source?: VideoSource;

  /** 暂停。受控属性。@default false */
  paused?: boolean;
  /** 静音。@default false */
  muted?: boolean;
  /** 音量，0..1。@default 1 */
  volume?: number;
  /**
   * 播放速率，1 为原速，运行时可变（不会重载媒体）。仅点播可靠；
   * 直播流及部分协议会忽略该请求（libvlc 层限制）。<=0 按 1 处理。
   * @default 1
   */
  rate?: number;
  /**
   * 播放完毕循环（仅点播）。iOS 走 VLCMediaListPlayer 原生 repeatMode，
   * 运行时可切换、不重载媒体，每圈结束触发一次 onEnd；Android 走 libvlc
   * 内部无缝循环、循环期间不触发 onEnd，播放中开关会重载媒体。
   * 勿用 onEnd 计圈。
   * @default false
   */
  repeat?: boolean;

  /** 视频在容器内的缩放方式。@default 'contain' */
  resizeMode?: VlcPlayerResizeMode;

  /**
   * 是否启用硬件解码。出现花屏 / 颜色错乱 / 解码失败时改成 `false` 强制纯软解
   * 排查。修改此值会重新加载媒体，不能在播放中无缝切换。
   *
   * - iOS 走 MobileVLCKit 3 / VideoToolbox；关闭硬解通过 `:codec=avcodec,all`
   *   实现（与 VLC-iOS 官方应用一致）。
   * - Android 走 libvlc-android 的 `setHWDecoderEnabled` 接口。
   *
   * 控制硬解请使用此 prop，不要直接在 `mediaOptions` 里塞 `:codec=...`
   * 或 `:no-hw-dec` —— 两个平台底层接口不同，混用会被覆盖。
   *
   * @default true
   */
  hardwareDecoding?: boolean;

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
   * 例：`[':network-caching=200']`
   *
   * 控制硬解请使用 `hardwareDecoding` prop。
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
  /**
   * 截取当前画面，返回 PNG 文件的 `file://` URI，可直接用于
   * `<Image source={{ uri }}>`。文件写在应用缓存目录，系统可能随时
   * 清理；需要长期保存请自行拷贝。
   */
  snapshot: () => Promise<string>;
  /** 重新拉流，断流恢复用。 */
  reload: () => void;
};
