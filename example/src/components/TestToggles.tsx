import { Pressable, StyleSheet, Text, View } from 'react-native';

import type { VlcPlayerResizeMode } from '@wekor/react-native-vlc-player';

// 参数试验台:每个开关对应一个播放器 prop 的运行时切换语义。
// mediaOptions 变化 → 重挂媒体;initOptions 变化 → 重建 libvlc 核心。
const RESIZE_MODES: VlcPlayerResizeMode[] = [
  'contain',
  'cover',
  'stretch',
  'original',
];
const RATES = [1, 1.5, 2, 0.5];

type Props = {
  resizeMode: VlcPlayerResizeMode;
  lowCache: boolean;
  verboseInit: boolean;
  extSubtitle: boolean;
  repeat: boolean;
  rate: number;
  onResizeMode: (mode: VlcPlayerResizeMode) => void;
  onLowCache: (value: boolean) => void;
  onVerboseInit: (value: boolean) => void;
  onExtSubtitle: (value: boolean) => void;
  onRepeat: (value: boolean) => void;
  onRate: (value: number) => void;
};

export const TestToggles = (props: Props) => (
  <View>
    <View style={styles.row}>
      {RESIZE_MODES.map((mode) => (
        <Pressable
          key={mode}
          onPress={() => props.onResizeMode(mode)}
          style={[styles.modeChip, props.resizeMode === mode && styles.active]}
        >
          <Text style={styles.text}>{mode}</Text>
        </Pressable>
      ))}
    </View>
    <View style={styles.row}>
      <Pressable
        style={[styles.button, props.lowCache && styles.active]}
        onPress={() => props.onLowCache(!props.lowCache)}
      >
        <Text style={styles.text}>缓存 {props.lowCache ? '300' : '1500'}</Text>
      </Pressable>
      <Pressable
        style={[styles.button, props.verboseInit && styles.active]}
        onPress={() => props.onVerboseInit(!props.verboseInit)}
      >
        <Text style={styles.text}>
          init {props.verboseInit ? '-vv' : '默认'}
        </Text>
      </Pressable>
      <Pressable
        style={[styles.button, props.extSubtitle && styles.active]}
        onPress={() => props.onExtSubtitle(!props.extSubtitle)}
      >
        <Text style={styles.text}>外挂字幕</Text>
      </Pressable>
      <Pressable
        style={[styles.button, props.repeat && styles.active]}
        onPress={() => props.onRepeat(!props.repeat)}
      >
        <Text style={styles.text}>循环 {props.repeat ? '开' : '关'}</Text>
      </Pressable>
      <Pressable
        style={[styles.button, props.rate !== 1 && styles.active]}
        onPress={() =>
          props.onRate(RATES[(RATES.indexOf(props.rate) + 1) % RATES.length]!)
        }
      >
        <Text style={styles.text}>倍速 {props.rate}x</Text>
      </Pressable>
    </View>
  </View>
);

const styles = StyleSheet.create({
  row: { flexDirection: 'row', paddingHorizontal: 12, paddingTop: 8, gap: 8 },
  modeChip: {
    flex: 1,
    paddingVertical: 8,
    backgroundColor: '#222',
    borderRadius: 4,
    alignItems: 'center',
  },
  button: {
    flex: 1,
    backgroundColor: '#444',
    paddingVertical: 10,
    alignItems: 'center',
    borderRadius: 6,
  },
  active: { backgroundColor: '#1e88e5' },
  text: { color: 'white', fontSize: 12 },
});
