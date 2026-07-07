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

// Internal: snapshot() Promise resolution.
// JS issues a snapshot command with a callId and the native side replies via
// this event. The JS wrapper holds a callId→Promise registry and never
// exposes this event to library users.
type SnapshotResultEvent = Readonly<{
  callId: CodegenTypes.Int32;
  base64: string;
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

  onLoad?: CodegenTypes.DirectEventHandler<LoadEvent>;
  onPlaying?: CodegenTypes.DirectEventHandler<PlayingEvent>;
  onBuffer?: CodegenTypes.DirectEventHandler<BufferEvent>;
  onProgress?: CodegenTypes.DirectEventHandler<ProgressEvent>;
  onEnd?: CodegenTypes.DirectEventHandler<EndEvent>;
  onError?: CodegenTypes.DirectEventHandler<ErrorEvent>;
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
