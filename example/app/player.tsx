import { useRef, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Image,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import {
  VlcPlayerView,
  type VlcPlayerHandle,
  type VlcPlayerResizeMode,
} from '@wekor/react-native-vlc-player';

// ---------------------------------------------------------------------------
// Test sources. Pick from these to exercise different formats / network stacks.
// ---------------------------------------------------------------------------
const SOURCES: { name: string; url: string; note: string }[] = [
  {
    name: 'MP4 / HTTPS',
    url: 'https://www.w3schools.com/Html/mov_bbb.mp4',
    note: 'VOD 标准用例，应能拿到 duration，onProgress 持续触发',
  },
  {
    name: 'HLS m3u8',
    url: 'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8',
    note: 'Apple 官方测试流，自适应码率',
  },
  {
    name: 'HLS (Mux)',
    url: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
    note: 'Mux 公开测试流',
  },
  {
    name: 'DASH mpd',
    url: 'https://dash.akamaized.net/akamai/bbb_30fps/bbb_30fps.mpd',
    note: 'Akamai DASH 测试源',
  },
  {
    name: 'RTSP (本机摄像头)',
    url: 'rtsp://172.27.1.38:50001/live/0',
    note: '直播源,videoSize 可能从未被报告',
  },
  {
    name: '坏 URL',
    url: 'https://invalid-host.example.com/nonexistent.mp4',
    note: '应在 ~8s 内触发 onError',
  },
];

const RESIZE_MODES: VlcPlayerResizeMode[] = [
  'contain',
  'cover',
  'stretch',
  'original',
];

type EventLog = { ts: string; kind: string; data: string };

export default function App() {
  const ref = useRef<VlcPlayerHandle>(null);
  const [sourceIdx, setSourceIdx] = useState(0);
  const [loading, setLoading] = useState(true);
  const [bufferPct, setBufferPct] = useState(0);
  const [paused, setPaused] = useState(false);
  const [resizeMode, setResizeMode] = useState<VlcPlayerResizeMode>('contain');
  const [logs, setLogs] = useState<EventLog[]>([]);
  const [snapshotData, setSnapshotData] = useState<string | null>(null);

  const source = SOURCES[sourceIdx]!;

  const log = (kind: string, data: string) => {
    setLogs((prev) =>
      [{ ts: new Date().toLocaleTimeString(), kind, data }, ...prev].slice(
        0,
        30
      )
    );
  };

  const switchSource = (idx: number) => {
    setSourceIdx(idx);
    setLoading(true);
    setBufferPct(0);
    setPaused(false);
    setSnapshotData(null);
    setLogs([]);
  };

  return (
    <View style={styles.container}>
      {/* ---- source picker ---- */}
      <View style={styles.sourceBar}>
        <ScrollView horizontal showsHorizontalScrollIndicator={false}>
          {SOURCES.map((s, i) => {
            const active = i === sourceIdx;
            return (
              <Pressable
                key={s.name}
                onPress={() => switchSource(i)}
                style={[styles.sourceChip, active && styles.sourceChipActive]}
              >
                <Text
                  style={[
                    styles.sourceChipText,
                    active && styles.sourceChipTextActive,
                  ]}
                >
                  {s.name}
                </Text>
              </Pressable>
            );
          })}
        </ScrollView>
      </View>
      <Text style={styles.sourceNote} numberOfLines={2}>
        {source.note}
      </Text>

      {/* ---- player ---- */}
      <View style={styles.playerWrap}>
        <VlcPlayerView
          ref={ref}
          style={styles.player}
          url={source.url}
          paused={paused}
          resizeMode={resizeMode}
          mediaOptions={[':rtsp-tcp', ':network-caching=200']}
          onLoad={({ nativeEvent: { duration, videoSize } }) => {
            log(
              'onLoad',
              `duration=${duration} videoSize=${videoSize?.width}x${videoSize?.height}`
            );
          }}
          onPlaying={() => {
            log('onPlaying', '');
            setLoading(false);
          }}
          onBuffer={({ nativeEvent: { isBuffering, percent } }) => {
            setLoading(isBuffering);
            setBufferPct(percent);
            if (isBuffering || percent >= 100) {
              log('onBuffer', `${isBuffering} ${percent.toFixed(0)}%`);
            }
          }}
          onProgress={({ nativeEvent: { currentTime, duration, percent } }) => {
            // 只记录关键点,不刷屏
            if (
              Math.floor(percent) % 10 === 0 &&
              Math.floor(percent) !== Math.floor((percent - 0.5) % 10)
            ) {
              log(
                'onProgress',
                `${currentTime}/${duration} (${percent.toFixed(0)}%)`
              );
            }
          }}
          onEnd={() => log('onEnd', '')}
          onError={(e) => {
            log('onError', e.nativeEvent.message);
            Alert.alert('Error', e.nativeEvent.message);
          }}
        />

        {loading && (
          <View style={styles.loaderOverlay} pointerEvents="none">
            <ActivityIndicator color="white" size="large" />
            <Text style={styles.loaderText}>{bufferPct.toFixed(0)}%</Text>
          </View>
        )}
      </View>

      {/* ---- resize modes ---- */}
      <View style={styles.row}>
        {RESIZE_MODES.map((mode) => {
          const active = mode === resizeMode;
          return (
            <Pressable
              key={mode}
              onPress={() => setResizeMode(mode)}
              style={[styles.modeChip, active && styles.modeChipActive]}
            >
              <Text
                style={[
                  styles.modeChipText,
                  active && styles.modeChipTextActive,
                ]}
              >
                {mode}
              </Text>
            </Pressable>
          );
        })}
      </View>

      {/* ---- controls ---- */}
      <View style={styles.row}>
        <Pressable style={styles.button} onPress={() => setPaused((p) => !p)}>
          <Text style={styles.buttonText}>{paused ? '播放' : '暂停'}</Text>
        </Pressable>
        <Pressable
          style={styles.button}
          onPress={() => {
            setLoading(true);
            ref.current?.reload();
          }}
        >
          <Text style={styles.buttonText}>重连</Text>
        </Pressable>
        <Pressable
          style={styles.button}
          onPress={async () => {
            try {
              const b64 = await ref.current?.snapshot();
              if (b64) {
                setSnapshotData(`data:image/png;base64,${b64}`);
                log('snapshot', `ok ${(b64.length / 1024).toFixed(0)}KB`);
              }
            } catch (e: any) {
              log('snapshot', `err ${e?.message ?? e}`);
            }
          }}
        >
          <Text style={styles.buttonText}>截图</Text>
        </Pressable>
      </View>

      {/* ---- snapshot preview ---- */}
      {snapshotData && (
        <Pressable
          style={styles.snapshotWrap}
          onPress={() => setSnapshotData(null)}
        >
          <Image source={{ uri: snapshotData }} style={styles.snapshotImg} />
          <Text style={styles.snapshotHint}>点击关闭</Text>
        </Pressable>
      )}

      {/* ---- event log ---- */}
      <ScrollView style={styles.logBox}>
        {logs.map((l, i) => (
          <Text key={i} style={styles.logLine}>
            <Text style={styles.logTs}>{l.ts}</Text>{' '}
            <Text style={styles.logKind}>{l.kind}</Text>{' '}
            <Text style={styles.logData}>{l.data}</Text>
          </Text>
        ))}
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#000' },
  sourceBar: {
    paddingHorizontal: 8,
    paddingTop: 50,
    paddingBottom: 4,
  },
  sourceChip: {
    paddingHorizontal: 12,
    paddingVertical: 6,
    marginHorizontal: 4,
    backgroundColor: '#222',
    borderRadius: 14,
  },
  sourceChipActive: { backgroundColor: '#1e88e5' },
  sourceChipText: { color: '#aaa', fontSize: 12 },
  sourceChipTextActive: { color: 'white', fontWeight: '600' },
  sourceNote: {
    color: '#888',
    fontSize: 11,
    paddingHorizontal: 12,
    paddingBottom: 8,
  },
  playerWrap: {
    height: 240,
    backgroundColor: 'black',
  },
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
  row: {
    flexDirection: 'row',
    paddingHorizontal: 12,
    paddingTop: 8,
    gap: 8,
  },
  modeChip: {
    flex: 1,
    paddingVertical: 8,
    backgroundColor: '#222',
    borderRadius: 4,
    alignItems: 'center',
  },
  modeChipActive: { backgroundColor: '#1e88e5' },
  modeChipText: { color: '#aaa', fontSize: 13 },
  modeChipTextActive: { color: 'white', fontWeight: '600' },
  button: {
    flex: 1,
    backgroundColor: '#444',
    paddingVertical: 10,
    alignItems: 'center',
    borderRadius: 6,
  },
  buttonText: { color: 'white', fontSize: 14 },
  snapshotWrap: {
    position: 'absolute',
    top: 100,
    left: 12,
    right: 12,
    bottom: 100,
    backgroundColor: 'rgba(0,0,0,0.9)',
    borderRadius: 8,
    padding: 12,
    alignItems: 'center',
    justifyContent: 'center',
  },
  snapshotImg: {
    flex: 1,
    width: '100%',
    resizeMode: 'contain',
  },
  snapshotHint: { color: '#aaa', marginTop: 8, fontSize: 12 },
  logBox: {
    flex: 1,
    backgroundColor: '#111',
    margin: 12,
    padding: 8,
    borderRadius: 4,
  },
  logLine: { fontSize: 11, marginBottom: 2 },
  logTs: { color: '#666' },
  logKind: { color: '#4fc3f7' },
  logData: { color: '#ddd' },
});
