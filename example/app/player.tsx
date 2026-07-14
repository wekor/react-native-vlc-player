import { useRef, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Image,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import {
  VlcPlayerView,
  type VlcPlayerHandle,
  type VlcPlayerResizeMode,
  type VlcPlayerTracksPayload,
} from '@wekor/react-native-vlc-player';

import { EXTERNAL_SUBTITLE_URL, SOURCES } from '../src/sources';
import { SourcePicker } from '../src/components/SourcePicker';
import { TrackPickers } from '../src/components/TrackPickers';
import { TestToggles } from '../src/components/TestToggles';
import {
  PlayerControls,
  type Progress,
} from '../src/components/PlayerControls';
import {
  EventLog,
  type LogEntry,
  type SnapshotData,
} from '../src/components/EventLog';

// 测试台的组装层。状态分两组:
// 意图态(要什么) —— 作为 props 传给播放器;
// 观察态(发生了什么) —— 从事件来,只读展示。
export default function App() {
  const ref = useRef<VlcPlayerHandle>(null);

  // ---- 意图态 ----
  const [sourceIdx, setSourceIdx] = useState(0);
  const [paused, setPaused] = useState(false);
  const [resizeMode, setResizeMode] = useState<VlcPlayerResizeMode>('contain');
  const [lowCache, setLowCache] = useState(false);
  const [verboseInit, setVerboseInit] = useState(false);
  const [extSubtitle, setExtSubtitle] = useState(false);
  const [repeat, setRepeat] = useState(false);
  const [rate, setRate] = useState(1);
  const [audioTrack, setAudioTrack] = useState('auto');
  const [textTrack, setTextTrack] = useState('auto');

  // ---- 观察态 ----
  const [loading, setLoading] = useState(true);
  const [bufferPct, setBufferPct] = useState(0);
  const [isPlaying, setIsPlaying] = useState(false);
  const [tracks, setTracks] = useState<VlcPlayerTracksPayload>({
    audioTracks: [],
    textTracks: [],
  });
  const [progress, setProgress] = useState<Progress>({
    currentTime: 0,
    duration: 0,
    percent: 0,
  });
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const [snapshot, setSnapshot] = useState<SnapshotData | null>(null);
  const lastLoggedDecileRef = useRef(-1);
  const lastTracksLineRef = useRef('');

  const source = SOURCES[sourceIdx]!;

  const log = (kind: string, data: string) => {
    // 同步打到 Metro 终端:完整历史,不受热重载和 30 条上限影响
    console.log(`[vlc] ${kind} ${data}`);
    setLogs((prev) =>
      [{ ts: new Date().toLocaleTimeString(), kind, data }, ...prev].slice(
        0,
        200
      )
    );
  };

  const switchSource = (idx: number) => {
    setSourceIdx(idx);
    setLoading(true);
    setBufferPct(0);
    setPaused(false);
    setSnapshot(null);
    setLogs([]);
    setProgress({ currentTime: 0, duration: 0, percent: 0 });
    setTracks({ audioTracks: [], textTracks: [] });
    setAudioTrack('auto');
    setTextTrack('auto');
    setExtSubtitle(false);
    lastLoggedDecileRef.current = -1;
  };

  // HLS 轨道 id 不稳定:选中后 ES 可能换新 id 重建。请求的 id 消失时
  // 跟随实际选中的轨道(✓);彻底没有选中的才回落 auto。
  const followTracks = (payload: VlcPlayerTracksPayload) => {
    const follow = (
      requested: string,
      list: readonly { id: string; selected: boolean }[],
      apply: (id: string) => void,
      kind: string
    ) => {
      if (requested === 'auto' || requested === 'none') return;
      if (list.some((t) => t.id === requested)) return;
      const actual = list.find((t) => t.selected);
      apply(actual ? actual.id : 'auto');
      log('onTracks', `${kind} ${requested} id更替 → ${actual?.id ?? 'auto'}`);
    };
    follow(audioTrack, payload.audioTracks, setAudioTrack, '音轨');
    follow(textTrack, payload.textTracks, setTextTrack, '字幕轨');
  };

  const takeSnapshot = async () => {
    try {
      const uri = await ref.current?.snapshot();
      if (!uri) return;
      Image.getSize(
        uri,
        (w, h) => {
          setSnapshot({ uri, w, h });
          log('snapshot', `${w}x${h} ${uri.split('/').pop()}`);
        },
        (e) => log('snapshot', `getSize err ${e}`)
      );
    } catch (e) {
      log('snapshot', `err ${e instanceof Error ? e.message : e}`);
    }
  };

  return (
    <View style={styles.container}>
      <SourcePicker
        sources={SOURCES}
        index={sourceIdx}
        onSelect={switchSource}
      />

      <View style={styles.playerWrap}>
        <VlcPlayerView
          ref={ref}
          style={styles.player}
          source={source.url}
          paused={paused}
          repeat={repeat}
          rate={rate}
          resizeMode={resizeMode}
          initOptions={verboseInit ? ['-vv'] : []}
          mediaOptions={[
            lowCache ? ':network-caching=300' : ':network-caching=1500',
          ]}
          audioTrack={audioTrack}
          textTrack={textTrack}
          subtitleUri={extSubtitle ? EXTERNAL_SUBTITLE_URL : undefined}
          {...source.overrides}
          onLoad={({ nativeEvent: { duration, videoWidth, videoHeight } }) => {
            log(
              'onLoad',
              `duration=${duration} video=${videoWidth}x${videoHeight}`
            );
          }}
          onPlaying={() => {
            log('onPlaying', '');
            setLoading(false);
          }}
          onPlaybackStateChanged={({ nativeEvent: { isPlaying: playing } }) => {
            setIsPlaying(playing);
            log('onPlaybackState', playing ? 'playing' : 'paused');
          }}
          onBuffer={({ nativeEvent: { isBuffering, percent } }) => {
            setLoading(isBuffering);
            setBufferPct(percent);
            if (isBuffering || percent >= 100) {
              log('onBuffer', `${isBuffering} ${percent.toFixed(0)}%`);
            }
          }}
          onProgress={({ nativeEvent: { currentTime, duration, percent } }) => {
            setProgress({ currentTime, duration, percent });
            // 每 10% 只记录一次,避免刷屏
            const decile = Math.floor(percent / 10);
            if (decile !== lastLoggedDecileRef.current) {
              lastLoggedDecileRef.current = decile;
              log('onProgress', `${currentTime}ms (${percent.toFixed(1)}%)`);
            }
          }}
          onEnd={() => log('onEnd', '')}
          onError={({ nativeEvent: { message } }) => {
            log('onError', message);
            Alert.alert('Error', message);
          }}
          onTracksChanged={({ nativeEvent: payload }) => {
            setTracks(payload);
            followTracks(payload);
            const dump = (list: readonly { id: string; selected: boolean }[]) =>
              list.map((t) => `${t.id}${t.selected ? '*' : ''}`).join(',');
            const line = `audio[${dump(payload.audioTracks)}] text[${dump(payload.textTracks)}]`;
            // 连续重复的轨道快照不重复记录,避免事件风暴挤掉早期日志
            if (line !== lastTracksLineRef.current) {
              lastTracksLineRef.current = line;
              log('onTracks', line);
            }
          }}
        />
        {loading && (
          <View style={styles.loaderOverlay} pointerEvents="none">
            <ActivityIndicator color="white" size="large" />
            <Text style={styles.loaderText}>{bufferPct.toFixed(0)}%</Text>
          </View>
        )}
      </View>

      <TrackPickers
        tracks={tracks}
        audioTrack={audioTrack}
        textTrack={textTrack}
        onAudioTrack={(id) => {
          setAudioTrack(id);
          log('test', `audioTrack=${id}`);
        }}
        onTextTrack={(id) => {
          setTextTrack(id);
          log('test', `textTrack=${id}`);
        }}
      />

      <TestToggles
        resizeMode={resizeMode}
        lowCache={lowCache}
        verboseInit={verboseInit}
        extSubtitle={extSubtitle}
        repeat={repeat}
        rate={rate}
        onResizeMode={setResizeMode}
        onLowCache={(v) => {
          setLowCache(v);
          log('test', `caching→${v ? 300 : 1500} 预期:仅重挂媒体`);
        }}
        onVerboseInit={(v) => {
          setVerboseInit(v);
          log('test', `initOptions ${v ? '+' : '-'}vv 预期:重建核心`);
        }}
        onExtSubtitle={(v) => {
          setExtSubtitle(v);
          log('test', `外挂字幕=${v} (重载媒体)`);
        }}
        onRepeat={(v) => {
          setRepeat(v);
          log('test', `repeat=${v}`);
        }}
        onRate={(v) => {
          setRate(v);
          log('test', `rate=${v}`);
        }}
      />

      <PlayerControls
        progress={progress}
        isPlaying={isPlaying}
        onTogglePause={() => setPaused((p) => !p)}
        onReload={() => {
          setLoading(true);
          ref.current?.reload();
        }}
        onSnapshot={takeSnapshot}
      />

      <EventLog
        logs={logs}
        snapshot={snapshot}
        onCloseSnapshot={() => setSnapshot(null)}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#000' },
  playerWrap: { height: 240, backgroundColor: 'black' },
  player: { flex: 1 },
  loaderOverlay: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    alignItems: 'center',
    justifyContent: 'center',
  },
  loaderText: { color: 'white', marginTop: 8, fontSize: 14 },
});
