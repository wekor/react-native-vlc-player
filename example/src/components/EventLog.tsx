import { Image, Pressable, ScrollView, StyleSheet, Text } from 'react-native';

// 证据区:事件日志 + 截图预览。
export type LogEntry = { ts: string; kind: string; data: string };

export type SnapshotData = { uri: string; w: number; h: number };

type Props = {
  logs: LogEntry[];
  snapshot: SnapshotData | null;
  onCloseSnapshot: () => void;
};

export const EventLog = ({ logs, snapshot, onCloseSnapshot }: Props) => (
  <>
    <ScrollView style={styles.box}>
      {logs.map((l, i) => (
        <Text key={i} style={styles.line}>
          <Text style={styles.ts}>{l.ts}</Text>{' '}
          <Text style={styles.kind}>{l.kind}</Text>{' '}
          <Text style={styles.data}>{l.data}</Text>
        </Text>
      ))}
    </ScrollView>
    {snapshot && (
      <Pressable style={styles.snapshotWrap} onPress={onCloseSnapshot}>
        <Image
          source={{ uri: snapshot.uri }}
          style={[styles.snapshotImg, { aspectRatio: snapshot.w / snapshot.h }]}
        />
        <Text style={styles.snapshotHint}>
          {snapshot.w}×{snapshot.h} 点击关闭
        </Text>
      </Pressable>
    )}
  </>
);

const styles = StyleSheet.create({
  box: {
    flex: 1,
    backgroundColor: '#111',
    margin: 12,
    padding: 8,
    borderRadius: 4,
  },
  line: { fontSize: 11, marginBottom: 2 },
  ts: { color: '#666' },
  kind: { color: '#4fc3f7' },
  data: { color: '#ddd' },
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
});
