import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import type { VlcPlayerTracksPayload } from '@wekor/react-native-vlc-player';

// 蓝色高亮 = 请求的轨道(意图),名字后的 ✓ = 实际在播的轨道(现实)。
// 正常两者重合;切换的过渡瞬间可能短暂分离。
type Props = {
  tracks: VlcPlayerTracksPayload;
  audioTrack: string;
  textTrack: string;
  onAudioTrack: (id: string) => void;
  onTextTrack: (id: string) => void;
};

const PSEUDO = [
  { id: 'auto', name: '自动' },
  { id: 'none', name: '关' },
];

type Chip = { id: string; name: string; selected?: boolean };

const Row = ({
  label,
  list,
  requested,
  onSelect,
}: {
  label: string;
  list: Chip[];
  requested: string;
  onSelect: (id: string) => void;
}) => (
  <ScrollView horizontal showsHorizontalScrollIndicator={false}>
    <Text style={styles.label}>{label}</Text>
    {list.map((t) => (
      <Pressable
        key={t.id}
        onPress={() => onSelect(t.id)}
        style={[styles.chip, requested === t.id && styles.chipActive]}
      >
        <Text style={styles.chipText}>
          {t.selected ? `${t.name} ✓` : t.name}
        </Text>
      </Pressable>
    ))}
  </ScrollView>
);

export const TrackPickers = ({
  tracks,
  audioTrack,
  textTrack,
  onAudioTrack,
  onTextTrack,
}: Props) => {
  if (tracks.audioTracks.length === 0 && tracks.textTracks.length === 0) {
    return null;
  }
  return (
    <View style={styles.box}>
      {tracks.audioTracks.length > 0 && (
        <Row
          label="音轨"
          list={[...PSEUDO, ...tracks.audioTracks]}
          requested={audioTrack}
          onSelect={onAudioTrack}
        />
      )}
      {tracks.textTracks.length > 0 && (
        <Row
          label="字幕"
          list={[...PSEUDO, ...tracks.textTracks]}
          requested={textTrack}
          onSelect={onTextTrack}
        />
      )}
    </View>
  );
};

const styles = StyleSheet.create({
  box: { paddingHorizontal: 12, paddingTop: 8, gap: 6 },
  label: { color: '#888', fontSize: 12, marginRight: 8, alignSelf: 'center' },
  chip: {
    paddingHorizontal: 10,
    paddingVertical: 5,
    marginRight: 6,
    backgroundColor: '#222',
    borderRadius: 12,
  },
  chipActive: { backgroundColor: '#1e88e5' },
  chipText: { color: '#ddd', fontSize: 12 },
});
