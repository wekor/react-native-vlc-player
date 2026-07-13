import {
  codegenNativeCommands,
  codegenNativeComponent,
  type CodegenTypes,
  type HostComponent,
  type ViewProps,
} from 'react-native';
import type React from 'react';

// ---- Event payloads (codegen-friendly, no optionals in required fields) ----

type LoadEvent = Readonly<{
  duration: CodegenTypes.Int32;
  videoWidth: CodegenTypes.Int32;
  videoHeight: CodegenTypes.Int32;
}>;

type PlayingEvent = Readonly<{
  url: string;
}>;

type BufferEvent = Readonly<{
  isBuffering: boolean;
  percent: CodegenTypes.Float;
}>;

type ProgressEvent = Readonly<{
  currentTime: CodegenTypes.Int32;
  duration: CodegenTypes.Int32;
  percent: CodegenTypes.Float;
}>;

type EndEvent = Readonly<{
  url: string;
}>;

type ErrorEvent = Readonly<{
  message: string;
}>;

// Ground truth of whether media is actually playing. Fires on every
// transition, including native-initiated pauses (phone call, headphones
// unplugged) that the `paused` prop cannot know about.
type PlaybackStateEvent = Readonly<{
  isPlaying: boolean;
}>;

// One playable track (audio or text). `id` is an opaque native identifier:
// libvlc string ids on iOS, stringified ints on Android — JS must treat it
// as a token that round-trips into the track-selection props.
// `language` is a BCP-47-ish code when the container declares one; iOS
// reports it from VLCMediaTrack.language, Android's TrackDescription has no
// language field so it is always '' there (the name usually carries it).
type TracksChangedEvent = Readonly<{
  audioTracks: {
    id: string;
    name: string;
    language: string;
    selected: boolean;
  }[];
  textTracks: {
    id: string;
    name: string;
    language: string;
    selected: boolean;
  }[];
}>;

// Internal: snapshot() Promise resolution.
// JS issues a snapshot command with a callId and the native side replies via
// this event. The JS wrapper holds a callId→Promise registry and never
// exposes this event to library users.
type SnapshotResultEvent = Readonly<{
  callId: CodegenTypes.Int32;
  path: string;
  error: string;
}>;

// ---- Native props ----

interface NativeProps extends ViewProps {
  // Flat wire fields. JS wrapper normalizes the public `source` prop
  // (`string | { uri, referer?, userAgent? }`) into these three.
  url?: string;
  referer?: string;
  userAgent?: string;
  paused?: CodegenTypes.WithDefault<boolean, false>;
  muted?: CodegenTypes.WithDefault<boolean, false>;
  volume?: CodegenTypes.WithDefault<CodegenTypes.Float, 1.0>;
  rate?: CodegenTypes.WithDefault<CodegenTypes.Float, 1.0>;
  repeat?: CodegenTypes.WithDefault<boolean, false>;
  resizeMode?: CodegenTypes.WithDefault<string, 'contain'>;
  hardwareDecoding?: CodegenTypes.WithDefault<boolean, true>;
  initOptions?: ReadonlyArray<string>;
  mediaOptions?: ReadonlyArray<string>;
  // Track selection. 'auto' = libvlc's default choice, 'none' = disabled,
  // otherwise a track id from onTracksChanged. Declarative so the choice
  // survives media reloads (repeat/hardwareDecoding toggles, recovery).
  // Language preference doesn't need this — use mediaOptions
  // ':audio-language=' / ':sub-language=' instead.
  audioTrack?: CodegenTypes.WithDefault<string, 'auto'>;
  textTrack?: CodegenTypes.WithDefault<string, 'auto'>;
  // External subtitle file (file:// or http(s)://), loaded with the media
  // and auto-selected.
  subtitleUri?: string;
  // Minimum milliseconds between onProgress emissions (native-side throttle;
  // matters for multi-player grids where every event crosses the bridge).
  progressUpdateInterval?: CodegenTypes.WithDefault<CodegenTypes.Int32, 500>;

  onLoad?: CodegenTypes.DirectEventHandler<LoadEvent>;
  onPlaying?: CodegenTypes.DirectEventHandler<PlayingEvent>;
  onBuffer?: CodegenTypes.DirectEventHandler<BufferEvent>;
  onProgress?: CodegenTypes.DirectEventHandler<ProgressEvent>;
  onEnd?: CodegenTypes.DirectEventHandler<EndEvent>;
  onError?: CodegenTypes.DirectEventHandler<ErrorEvent>;
  onPlaybackStateChanged?: CodegenTypes.DirectEventHandler<PlaybackStateEvent>;
  onTracksChanged?: CodegenTypes.DirectEventHandler<TracksChangedEvent>;
  onSnapshotResult?: CodegenTypes.DirectEventHandler<SnapshotResultEvent>;
}

type ComponentType = HostComponent<NativeProps>;

// ---- Imperative commands ----

interface NativeCommands {
  play: (viewRef: React.ElementRef<ComponentType>) => void;
  pause: (viewRef: React.ElementRef<ComponentType>) => void;
  seek: (
    viewRef: React.ElementRef<ComponentType>,
    seconds: CodegenTypes.Float
  ) => void;
  snapshot: (
    viewRef: React.ElementRef<ComponentType>,
    callId: CodegenTypes.Int32
  ) => void;
  reload: (viewRef: React.ElementRef<ComponentType>) => void;
}

export const Commands: NativeCommands = codegenNativeCommands<NativeCommands>({
  supportedCommands: ['play', 'pause', 'seek', 'snapshot', 'reload'],
});

export default codegenNativeComponent<NativeProps>(
  'VlcPlayerView'
) as HostComponent<NativeProps>;
