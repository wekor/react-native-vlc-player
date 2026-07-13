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
  VlcPlayerTrack,
  VlcPlayerTracksPayload,
  VlcPlayerViewProps,
} from './VlcPlayerView.types';

type NativeSnapshotEvent = {
  nativeEvent: { callId: number; path: string; error: string };
};

type SnapshotPending = {
  resolve: (path: string) => void;
  reject: (error: Error) => void;
};

// The snapshot() loop: the callId travels with the command to native,
// native replies via onSnapshotResult, and the Promise is looked up here
// by callId. A module-level counter is safe: events are dispatched
// per-view, so callIds only need to be unique within one view.
let nextSnapshotCallId = 0;

const normalizeSource = (source: VideoSource | undefined) => {
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
};

export const VlcPlayerView = React.forwardRef<
  VlcPlayerHandle,
  VlcPlayerViewProps
>(function VlcPlayerView(props, ref) {
  const { source, ...rest } = props;
  const { url, referer, userAgent } = normalizeSource(source);

  const nativeRef =
    React.useRef<React.ComponentRef<typeof NativeVlcPlayerView>>(null);
  const pendingSnapshots = React.useRef(
    new Map<number, SnapshotPending>()
  ).current;

  const handleSnapshotResult = (event: NativeSnapshotEvent) => {
    const { callId, path, error } = event.nativeEvent;
    const pending = pendingSnapshots.get(callId);
    if (!pending) return;
    pendingSnapshots.delete(callId);
    if (error) {
      pending.reject(new Error(error));
    } else {
      pending.resolve(path);
    }
  };

  // Without this, a snapshot() awaited across an unmount would hang
  // forever — the native reply has no receiver, so nothing ever settles
  // the Promise.
  React.useEffect(() => {
    return () => {
      pendingSnapshots.forEach(({ reject }) =>
        reject(new Error('VlcPlayerView unmounted before snapshot completed'))
      );
      pendingSnapshots.clear();
    };
  }, [pendingSnapshots]);

  React.useImperativeHandle(
    ref,
    () => ({
      play: () => {
        if (nativeRef.current) Commands.play(nativeRef.current);
      },
      pause: () => {
        if (nativeRef.current) Commands.pause(nativeRef.current);
      },
      seek: (seconds: number) => {
        if (nativeRef.current) Commands.seek(nativeRef.current, seconds);
      },
      reload: () => {
        if (nativeRef.current) Commands.reload(nativeRef.current);
      },
      snapshot: () =>
        new Promise<string>((resolve, reject) => {
          if (!nativeRef.current) {
            reject(new Error('VlcPlayerView is not mounted'));
            return;
          }
          const callId = ++nextSnapshotCallId;
          pendingSnapshots.set(callId, { resolve, reject });
          Commands.snapshot(nativeRef.current, callId);
        }),
    }),
    [pendingSnapshots]
  );

  return (
    <NativeVlcPlayerView
      {...rest}
      ref={nativeRef}
      url={url}
      referer={referer}
      userAgent={userAgent}
      onSnapshotResult={handleSnapshotResult}
    />
  );
});
