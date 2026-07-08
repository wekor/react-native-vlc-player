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
    name: 'RTSP (本机摄像头)',
    url: 'rtsp://172.27.1.52:50001/live/0',
    note: '直播源,videoSize 可能从未被报告',
  },
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
    name: '坏 URL',
    url: 'https://invalid-host.example.com/nonexistent.mp4',
    note: '应在 ~8s 内触发 onError',
  },
];

const RATES = [1, 1.5, 2, 0.5];

const RESIZE_MODES: VlcPlayerResizeMode[] = [
  'contain',
  'cover',
  'stretch',
  'original',
];

type EventLog = { ts: string; kind: string; data: string };
type Progress = { currentTime: number; duration: number; percent: number };

const fmtTime = (ms: number) => {
  if (!Number.isFinite(ms) || ms < 0) return '--:--';
  const total = Math.floor(ms / 1000);
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}`;
};

export default function App() {
  const ref = useRef<VlcPlayerHandle>(null);
  const [sourceIdx, setSourceIdx] = useState(0);
  const [loading, setLoading] = useState(true);
  const [bufferPct, setBufferPct] = useState(0);
  const [paused, setPaused] = useState(false);
  const [resizeMode, setResizeMode] = useState<VlcPlayerResizeMode>('contain');
  // 重构验证用：运行时切换 media/init options 与 repeat。
  // mediaOptions 切换预期只触发 "Loading media"（同一 LibVLC 实例重挂 media）；
  // initOptions 切换预期触发 "Creating player session"（重建 LibVLC，负向对照）。
  const [lowCache, setLowCache] = useState(false);
  const [verboseInit, setVerboseInit] = useState(false);
  // RTSP over TCP。官方 VLC-iOS 该设置默认关闭（走 UDP）——部分摄像头的
  // TCP interleaved 路径极慢甚至不通，强制 TCP 会把"能秒开"变成"打不开"。
  const [rtspTcp, setRtspTcp] = useState(false);
  const [repeat, setRepeat] = useState(false);
  const [rate, setRate] = useState(1);
  const [logs, setLogs] = useState<EventLog[]>([]);
  const [snapshotData, setSnapshotData] = useState<{
    uri: string;
    w: number;
    h: number;
  } | null>(null);
  const [progress, setProgress] = useState<Progress>({
    currentTime: 0,
    duration: 0,
    percent: 0,
  });
  const lastLoggedDecileRef = useRef<number>(-1);

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
    setProgress({ currentTime: 0, duration: 0, percent: 0 });
    lastLoggedDecileRef.current = -1;
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
          source={source.url}
          paused={paused}
          repeat={repeat}
          rate={rate}
          resizeMode={resizeMode}
          initOptions={verboseInit ? ['-vv'] : []}
          mediaOptions={[
            ...(rtspTcp ? [':rtsp-tcp'] : []),
            ...(lowCache ? [':network-caching=300'] : []),
          ]}
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
            setProgress({ currentTime, duration, percent });
            // 每 10% 只记录一次,避免刷屏
            const decile = Math.floor(percent / 10);
            if (decile !== lastLoggedDecileRef.current) {
              lastLoggedDecileRef.current = decile;
              log(
                'onProgress',
                `${fmtTime(currentTime)}/${fmtTime(duration)} (${percent.toFixed(1)}%)`
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

      {/* ---- onProgress 实时显示 ---- */}
      <View style={styles.progressBox}>
        <View style={styles.progressRow}>
          <Text style={styles.progressTime}>
            {fmtTime(progress.currentTime)}
          </Text>
          <Text style={styles.progressPct}>{progress.percent.toFixed(1)}%</Text>
          <Text style={styles.progressTime}>{fmtTime(progress.duration)}</Text>
        </View>
        <View style={styles.progressBar}>
          <View
            style={[
              styles.progressBarFill,
              { width: `${Math.max(0, Math.min(100, progress.percent))}%` },
            ]}
          />
        </View>
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

      {/* ---- 重构验证：运行时切换参数 ---- */}
      <View style={styles.row}>
        <Pressable
          style={[styles.button, lowCache && styles.buttonActive]}
          onPress={() => {
            const next = !lowCache;
            setLowCache(next);
            log(
              'test',
              `caching→${next ? 300 : '默认999'} 预期:仅 Loading media`
            );
          }}
        >
          <Text style={styles.buttonText}>
            缓存 {lowCache ? '300' : '默认'}
          </Text>
        </Pressable>
        <Pressable
          style={[styles.button, verboseInit && styles.buttonActive]}
          onPress={() => {
            const next = !verboseInit;
            setVerboseInit(next);
            log(
              'test',
              `initOptions ${next ? '+' : '-'}vv 预期:Creating session`
            );
          }}
        >
          <Text style={styles.buttonText}>
            init {verboseInit ? '-vv' : '默认'}
          </Text>
        </Pressable>
        <Pressable
          style={[styles.button, rtspTcp && styles.buttonActive]}
          onPress={() => {
            const next = !rtspTcp;
            setRtspTcp(next);
            log('test', `rtsp-tcp=${next}（官方默认关/UDP）`);
          }}
        >
          <Text style={styles.buttonText}>TCP {rtspTcp ? '开' : '关'}</Text>
        </Pressable>
        <Pressable
          style={[styles.button, repeat && styles.buttonActive]}
          onPress={() => {
            const next = !repeat;
            setRepeat(next);
            log('test', `repeat=${next}`);
          }}
        >
          <Text style={styles.buttonText}>循环 {repeat ? '开' : '关'}</Text>
        </Pressable>
        <Pressable
          style={[styles.button, rate !== 1 && styles.buttonActive]}
          onPress={() => {
            const next = RATES[(RATES.indexOf(rate) + 1) % RATES.length]!;
            setRate(next);
            log('test', `rate=${next}`);
          }}
        >
          <Text style={styles.buttonText}>倍速 {rate}x</Text>
        </Pressable>
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
              const uri = await ref.current?.snapshot();
              if (uri) {
                Image.getSize(
                  uri,
                  (w, h) => {
                    setSnapshotData({ uri, w, h });
                    log('snapshot', `${w}x${h} ${uri.split('/').pop()}`);
                  },
                  (e) => log('snapshot', `getSize err ${e}`)
                );
              }
            } catch (e: any) {
              log('snapshot', `err ${e?.message ?? e}`);
            }
          }}
        >
          <Text style={styles.buttonText}>截图</Text>
        </Pressable>
      </View>

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

      {/* ---- snapshot preview ----
           不透明背景 + 盒子贴合图片实际宽高比：预览里看到的每个像素
           都来自 PNG 本身，不会再有遮罩留白造成的"黑色色块"错觉。 */}
      {snapshotData && (
        <Pressable
          style={styles.snapshotWrap}
          onPress={() => setSnapshotData(null)}
        >
          <Image
            source={{ uri: snapshotData.uri }}
            style={[
              styles.snapshotImg,
              { aspectRatio: snapshotData.w / snapshotData.h },
            ]}
          />
          <Text style={styles.snapshotHint}>
            {snapshotData.w}×{snapshotData.h} 点击关闭
          </Text>
        </Pressable>
      )}
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
  progressBox: {
    paddingHorizontal: 12,
    paddingTop: 8,
  },
  progressRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    marginBottom: 4,
  },
  progressTime: { color: '#aaa', fontSize: 12, fontVariant: ['tabular-nums'] },
  progressPct: {
    color: '#4fc3f7',
    fontSize: 12,
    fontVariant: ['tabular-nums'],
  },
  progressBar: {
    height: 3,
    backgroundColor: '#222',
    borderRadius: 2,
    overflow: 'hidden',
  },
  progressBarFill: {
    height: '100%',
    backgroundColor: '#1e88e5',
  },
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
  buttonActive: { backgroundColor: '#1e88e5' },
  buttonText: { color: 'white', fontSize: 14 },
  snapshotWrap: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    backgroundColor: '#000',
    padding: 12,
    alignItems: 'center',
    justifyContent: 'center',
  },
  snapshotImg: {
    width: '100%',
    resizeMode: 'contain',
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: '#555',
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
