import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import type { TestSource } from '../sources';

type Props = {
  sources: TestSource[];
  index: number;
  onSelect: (index: number) => void;
};

export const SourcePicker = ({ sources, index, onSelect }: Props) => (
  <View>
    <View style={styles.bar}>
      <ScrollView horizontal showsHorizontalScrollIndicator={false}>
        {sources.map((s, i) => (
          <Pressable
            key={s.name}
            onPress={() => onSelect(i)}
            style={[styles.chip, i === index && styles.chipActive]}
          >
            <Text
              style={[styles.chipText, i === index && styles.chipTextActive]}
            >
              {s.name}
            </Text>
          </Pressable>
        ))}
      </ScrollView>
    </View>
    <Text style={styles.note} numberOfLines={2}>
      {sources[index]!.note}
    </Text>
  </View>
);

const styles = StyleSheet.create({
  bar: { paddingHorizontal: 8, paddingTop: 50, paddingBottom: 4 },
  chip: {
    paddingHorizontal: 12,
    paddingVertical: 6,
    marginHorizontal: 4,
    backgroundColor: '#222',
    borderRadius: 14,
  },
  chipActive: { backgroundColor: '#1e88e5' },
  chipText: { color: '#aaa', fontSize: 12 },
  chipTextActive: { color: 'white', fontWeight: '600' },
  note: {
    color: '#888',
    fontSize: 11,
    paddingHorizontal: 12,
    paddingBottom: 8,
  },
});
