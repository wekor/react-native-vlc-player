import { Pressable, StyleSheet, Text, View } from 'react-native';

// 进度显示(观察态) + 播控动作。播放按钮的文字由 onPlaybackStateChanged
// 的真实状态驱动,而不是 paused 意图 —— 原生自动暂停(来电/拔耳机)时
// 按钮依然显示正确。
export type Progress = {
  currentTime: number;
  duration: number;
  percent: number;
};

const fmtTime = (ms: number) => {
  if (!Number.isFinite(ms) || ms < 0) return '--:--';
  const total = Math.floor(ms / 1000);
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}`;
};

type Props = {
  progress: Progress;
  isPlaying: boolean;
  onTogglePause: () => void;
  onReload: () => void;
  onSnapshot: () => void;
};

export const PlayerControls = ({
  progress,
  isPlaying,
  onTogglePause,
  onReload,
  onSnapshot,
}: Props) => (
  <View>
    <View style={styles.progressBox}>
      <View style={styles.progressRow}>
        <Text style={styles.time}>{fmtTime(progress.currentTime)}</Text>
        <Text style={styles.pct}>{progress.percent.toFixed(1)}%</Text>
        <Text style={styles.time}>{fmtTime(progress.duration)}</Text>
      </View>
      <View style={styles.barTrack}>
        <View
          style={[
            styles.barFill,
            { width: `${Math.max(0, Math.min(100, progress.percent))}%` },
          ]}
        />
      </View>
    </View>
    <View style={styles.row}>
      <Pressable style={styles.button} onPress={onTogglePause}>
        <Text style={styles.text}>{isPlaying ? '暂停' : '播放'}</Text>
      </Pressable>
      <Pressable style={styles.button} onPress={onReload}>
        <Text style={styles.text}>重连</Text>
      </Pressable>
      <Pressable style={styles.button} onPress={onSnapshot}>
        <Text style={styles.text}>截图</Text>
      </Pressable>
    </View>
  </View>
);

const styles = StyleSheet.create({
  progressBox: { paddingHorizontal: 12, paddingTop: 8 },
  progressRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    marginBottom: 4,
  },
  time: { color: '#aaa', fontSize: 12, fontVariant: ['tabular-nums'] },
  pct: { color: '#4fc3f7', fontSize: 12, fontVariant: ['tabular-nums'] },
  barTrack: {
    height: 3,
    backgroundColor: '#222',
    borderRadius: 2,
    overflow: 'hidden',
  },
  barFill: { height: '100%', backgroundColor: '#1e88e5' },
  row: { flexDirection: 'row', paddingHorizontal: 12, paddingTop: 8, gap: 8 },
  button: {
    flex: 1,
    backgroundColor: '#444',
    paddingVertical: 10,
    alignItems: 'center',
    borderRadius: 6,
  },
  text: { color: 'white', fontSize: 14 },
});
