import { router } from 'expo-router';
import { Button, StyleSheet, View } from 'react-native';

export default function App() {
  return (
    <View style={styles.container}>
      <Button title="Go to Player" onPress={() => router.push('./player')} />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
  },
});
