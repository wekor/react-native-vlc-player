import type { ViewProps } from 'react-native';

/** How the video is scaled inside the view. */
export type VlcPlayerResizeMode = 'contain' | 'cover' | 'stretch' | 'original';

/**
 * Video source.
 *
 * String form is equivalent to `{ uri: ... }`. Object form allows extra
 * HTTP request configuration — but libvlc **only supports the `Referer`
 * and `User-Agent` headers**; arbitrary headers (e.g. `Authorization`)
 * cannot be injected due to libvlc network stack constraints. For
 * bearer-token auth, put the token in the URL query string or use HTTP
 * Basic Auth.
 */
export type VideoSource =
  | string
  | {
      /** Stream/file URL. RTSP / RTMP / HTTP(S) / HLS / file:// all work. */
      uri: string;
      /**
       * HTTP `Referer` header — commonly needed for anti-hotlinking CDNs.
       * HTTP/HTTPS streams only.
       */
      referer?: string;
      /**
       * HTTP `User-Agent` header, for servers that reject libvlc's default.
       * HTTP/HTTPS streams only.
       */
      userAgent?: string;
    };

/** `onLoad` payload — media metadata is known. */
export type VlcPlayerLoadPayload = {
  /** Total duration in milliseconds. 0 for live streams. */
  duration: number;
  /** Native video width in pixels. */
  videoWidth: number;
  /** Native video height in pixels. */
  videoHeight: number;
};

/** `onBuffer` payload — buffering state changed. */
export type VlcPlayerBufferPayload = {
  /** True while buffering — show a loading indicator. */
  isBuffering: boolean;
  /** Buffer fill, 0..100. */
  percent: number;
};

/** `onProgress` payload — playback position. */
export type VlcPlayerProgressPayload = {
  /** Elapsed playback time in milliseconds. */
  currentTime: number;
  /** Total duration in milliseconds. 0 for live streams. */
  duration: number;
  /** Playback progress, 0..100. 0 for live streams. */
  percent: number;
};

/** `onError` payload. */
export type VlcPlayerErrorPayload = {
  message: string;
};

/**
 * One selectable track (audio or text). `id` is an opaque native
 * identifier — round-trip it into the `audioTrack` / `textTrack` prop
 * as-is, never parse it (libvlc string ids on iOS, stringified ints on
 * Android).
 */
export type VlcPlayerTrack = {
  id: string;
  name: string;
  /**
   * Language code when the container declares one. iOS reports it from
   * VLC metadata; Android always reports '' (the name usually carries
   * the language).
   */
  language: string;
  /** Whether this track is currently selected for playback. */
  selected: boolean;
};

/** `onTracksChanged` payload — the available track lists changed. */
export type VlcPlayerTracksPayload = {
  audioTracks: readonly VlcPlayerTrack[];
  textTracks: readonly VlcPlayerTrack[];
};

export type VlcPlayerViewProps = ViewProps & {
  /**
   * Video source, as a string or an object (the object form supports
   * `referer` / `userAgent`).
   *
   * @example
   * source="https://example.com/stream.m3u8"
   * @example
   * source={{ uri: 'https://example.com/stream.m3u8', referer: 'https://example.com/' }}
   */
  source?: VideoSource;

  /**
   * Pause playback. Controlled prop. @default false
   *
   * Note: system events (phone-call interruptions, headphone/Bluetooth
   * disconnects) make the native side pause automatically per platform
   * convention — this prop is NOT mutated when that happens. Listen to
   * `onPlaybackStateChanged` for the ground truth.
   */
  paused?: boolean;
  /** Mute audio. @default false */
  muted?: boolean;
  /** Volume, 0..1. @default 1 */
  volume?: number;
  /**
   * Playback rate; 1 is normal speed. Changing it does not reload the
   * media. Reliable for VOD only — live streams and some protocols ignore
   * the request (libvlc limitation). Values <= 0 are treated as 1.
   * @default 1
   */
  rate?: number;
  /**
   * Loop playback (VOD only). Toggling while playing reloads the media
   * (same semantics as `hardwareDecoding`); playback position is
   * preserved. Loop behavior differs per platform: Android loops
   * seamlessly inside libvlc and fires no per-loop events; iOS briefly
   * reloads between passes and fires `onEnd` once per pass. Don't count
   * loops via onEnd.
   * @default false
   */
  repeat?: boolean;

  /** How the video is scaled inside the view. @default 'contain' */
  resizeMode?: VlcPlayerResizeMode;

  /**
   * Toggle hardware video decoding. Set `false` to force software
   * decoding when the hardware decoder produces artifacts / wrong colors
   * / decode failures. Changing this reloads the media.
   *
   * - iOS (VLCKit 4 / VideoToolbox): disabling injects
   *   `:codec=avcodec,all`, same as the official VLC-iOS app.
   * - Android: uses libvlc-android's `setHWDecoderEnabled`.
   *
   * Use this prop instead of passing `:codec=...` / `:no-hw-dec` in
   * `mediaOptions` — the platforms use different option strings and this
   * prop's path would clobber yours.
   *
   * @default true
   */
  hardwareDecoding?: boolean;

  /**
   * libvlc instance-level options (`--` prefix, passed to the LibVLC
   * constructor), e.g. `['--rtsp-tcp']`. For audio-output-module-style
   * global settings. Prefer `mediaOptions` for most tweaks.
   */
  initOptions?: readonly string[];

  /**
   * libvlc media-level options (`:` prefix, passed to Media.addOption),
   * e.g. `[':network-caching=200']`. Caching / network / decoding tweaks
   * belong here. For hardware decoding use the `hardwareDecoding` prop.
   */
  mediaOptions?: readonly string[];

  /**
   * Audio track selection: `'auto'` (libvlc's default choice), `'none'`
   * (audio off), or a track id from `onTracksChanged`. Declarative — the
   * choice survives media reloads (repeat/hardwareDecoding toggles,
   * recovery). For a language preference you don't need this prop: use
   * `mediaOptions` `':audio-language=zh'` instead.
   * @default 'auto'
   */
  audioTrack?: string;
  /**
   * Subtitle track selection: `'auto'`, `'none'` (subtitles off), or a
   * track id from `onTracksChanged`. For a language preference use
   * `mediaOptions` `':sub-language=zh'`.
   * @default 'auto'
   */
  textTrack?: string;
  /**
   * External subtitle file (`file://` or `http(s)://`, e.g. `.srt`).
   * Loaded with the media and auto-selected; libvlc renders subtitles
   * into the video itself.
   */
  subtitleUri?: string;
  /**
   * Minimum milliseconds between `onProgress` events (throttled on the
   * native side). Raise it in multi-player grids to cut bridge traffic.
   * @default 500
   */
  progressUpdateInterval?: number;

  /** Metadata known (duration / video size), before the first frame. Once per media. */
  onLoad?: (event: { nativeEvent: VlcPlayerLoadPayload }) => void;
  /** First frame rendered — the moment to hide posters/loaders. Once per media. */
  onPlaying?: () => void;
  /**
   * The play/pause ground truth — includes native-initiated pauses
   * (phone call, headphones unplugged, backgrounding) that never mutate
   * the `paused` prop. Drive play-button UI state from this.
   */
  onPlaybackStateChanged?: (event: {
    nativeEvent: { isPlaying: boolean };
  }) => void;
  /** Buffering state changes (startup + mid-playback stalls). */
  onBuffer?: (event: { nativeEvent: VlcPlayerBufferPayload }) => void;
  /**
   * Playback progress. VOD carries duration/percent; live streams report
   * duration 0 and percent 0 while currentTime keeps counting. Interval
   * is controlled by `progressUpdateInterval`.
   */
  onProgress?: (event: { nativeEvent: VlcPlayerProgressPayload }) => void;
  /** Playback finished (VOD only). */
  onEnd?: () => void;
  /** Playback error. */
  onError?: (event: { nativeEvent: VlcPlayerErrorPayload }) => void;
  /**
   * Available tracks changed (tracks resolve asynchronously after
   * playback starts, and on media switches). Build audio/subtitle menus
   * from this.
   */
  onTracksChanged?: (event: { nativeEvent: VlcPlayerTracksPayload }) => void;
};

/** Imperative API, reachable through the ref. */
export type VlcPlayerHandle = {
  /** Start playback. */
  play: () => void;
  /** Pause playback. */
  pause: () => void;
  /** Seek to a position in seconds (VOD only). */
  seek: (seconds: number) => void;
  /**
   * Capture the current frame. Resolves to a `file://` URI of a PNG,
   * directly usable in `<Image source={{ uri }}>`. The file lives in the
   * app cache directory and may be reclaimed by the OS — copy it out for
   * persistence.
   */
  snapshot: () => Promise<string>;
  /** Reconnect the stream — for recovering from a dropped connection. */
  reload: () => void;
};
