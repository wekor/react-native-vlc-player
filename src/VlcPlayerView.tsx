import * as React from 'react';

import NativeVlcPlayerView, { Commands } from './VlcPlayerViewNativeComponent';
import type {
  VideoSource,
  VlcPlayerHandle,
  VlcPlayerViewProps,
} from './VlcPlayerView.types';

export type {
  VideoSource,
  VlcPlayerBufferPayload,
  VlcPlayerErrorPayload,
  VlcPlayerHandle,
  VlcPlayerLoadPayload,
  VlcPlayerProgressPayload,
  VlcPlayerResizeMode,
  VlcPlayerViewProps,
} from './VlcPlayerView.types';

// Snapshot uses a JS-side callId↔Promise registry. Each call gets a unique
// id, the command goes to native with that id, and the native side replies
// via `onSnapshotResult { callId, path, error }`. We resolve the matching
// promise. Module-level counter is safe because callIds only need to be
// unique within a single view, and each view dispatches results only to
// its own subscriber.
let nextSnapshotCallId = 0;

type CodegenLoadEvent = {
  nativeEvent: {
    duration: number;
    videoWidth: number;
    videoHeight: number;
  };
};

type CodegenPlayingEvent = { nativeEvent: { url: string } };
type CodegenEndEvent = { nativeEvent: { url: string } };
type CodegenSnapshotEvent = {
  nativeEvent: { callId: number; path: string; error: string };
};

type SnapshotPending = {
  resolve: (path: string) => void;
  reject: (error: Error) => void;
};

export const VlcPlayerView = React.forwardRef<
  VlcPlayerHandle,
  VlcPlayerViewProps
>(function VlcPlayerView(props, ref) {
  const {
    onLoad,
    onPlaying,
    onEnd,
    source,
    paused = false,
    muted = false,
    volume = 1,
    rate = 1,
    repeat = false,
    resizeMode = 'contain',
    hardwareDecoding = true,
    initOptions,
    mediaOptions,
    ...rest
  } = props;

  // Normalize the public `source` (string | { uri, referer, userAgent })
  // into the flat fields the codegen component accepts. String form gets
  // unwrapped to `{ uri }`; object form passes through.
  const { url, referer, userAgent } = normalizeSource(source);

  const nativeRef =
    React.useRef<React.ComponentRef<typeof NativeVlcPlayerView>>(null);

  const pendingSnapshots = React.useRef(
    new Map<number, SnapshotPending>()
  ).current;

  // Reject any in-flight snapshot promises when the view unmounts so callers
  // don't await forever.
  React.useEffect(() => {
    return () => {
      pendingSnapshots.forEach(({ reject }) =>
        reject(new Error('VlcPlayerView unmounted before snapshot completed'))
      );
      pendingSnapshots.clear();
    };
  }, [pendingSnapshots]);

  // ---- Event bridges (codegen shape → user-facing shape) ----

  const handleLoad = React.useCallback(
    (event: CodegenLoadEvent) => {
      if (!onLoad) return;
      const { duration, videoWidth, videoHeight } = event.nativeEvent;
      onLoad({
        nativeEvent: {
          duration,
          videoSize: { width: videoWidth, height: videoHeight },
        },
      });
    },
    [onLoad]
  );

  const handlePlaying = React.useCallback(
    (_event: CodegenPlayingEvent) => {
      onPlaying?.();
    },
    [onPlaying]
  );

  const handleEnd = React.useCallback(
    (_event: CodegenEndEvent) => {
      onEnd?.();
    },
    [onEnd]
  );

  const handleSnapshotResult = React.useCallback(
    (event: CodegenSnapshotEvent) => {
      const { callId, path, error } = event.nativeEvent;
      const pending = pendingSnapshots.get(callId);
      if (!pending) return;
      pendingSnapshots.delete(callId);
      if (error) pending.reject(new Error(error));
      else pending.resolve(path);
    },
    [pendingSnapshots]
  );

  // ---- Imperative handle ----

  const snapshot = React.useCallback((): Promise<string> => {
    return new Promise<string>((resolve, reject) => {
      const view = nativeRef.current;
      if (!view) {
        reject(new Error('VlcPlayerView is not mounted'));
        return;
      }
      const callId = ++nextSnapshotCallId;
      pendingSnapshots.set(callId, { resolve, reject });
      Commands.snapshot(view, callId);
    });
  }, [pendingSnapshots]);

  React.useImperativeHandle(
    ref,
    () => ({
      play: () => {
        const view = nativeRef.current;
        if (view) Commands.play(view);
      },
      pause: () => {
        const view = nativeRef.current;
        if (view) Commands.pause(view);
      },
      seek: (seconds: number) => {
        const view = nativeRef.current;
        if (view) Commands.seek(view, seconds);
      },
      snapshot,
      reload: () => {
        const view = nativeRef.current;
        if (view) Commands.reload(view);
      },
    }),
    [snapshot]
  );

  // `rest` is spread first so a stray untyped prop can never override the
  // internal wiring (in particular onSnapshotResult, which snapshot()'s
  // Promise registry depends on).
  return (
    <NativeVlcPlayerView
      {...rest}
      ref={nativeRef}
      url={url}
      referer={referer}
      userAgent={userAgent}
      paused={paused}
      muted={muted}
      volume={volume}
      rate={rate}
      repeat={repeat}
      resizeMode={resizeMode}
      hardwareDecoding={hardwareDecoding}
      initOptions={initOptions}
      mediaOptions={mediaOptions}
      onLoad={handleLoad}
      onPlaying={handlePlaying}
      onEnd={handleEnd}
      onSnapshotResult={handleSnapshotResult}
    />
  );
});

function normalizeSource(source: VideoSource | undefined): {
  url: string | undefined;
  referer: string | undefined;
  userAgent: string | undefined;
} {
  if (source == null) {
    return { url: undefined, referer: undefined, userAgent: undefined };
  }
  if (typeof source === 'string') {
    return { url: source, referer: undefined, userAgent: undefined };
  }
  return {
    url: source.uri,
    referer: source.referer,
    userAgent: source.userAgent,
  };
}
