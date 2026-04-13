import { useState } from 'react';
import {
  Text,
  View,
  StyleSheet,
  Pressable,
  SafeAreaView,
  useColorScheme,
} from 'react-native';
import { setShowTaps, setPointerLocation } from 'react-native-pointer-location';

export default function App() {
  const colorScheme = useColorScheme();
  const isDark = colorScheme === 'dark';
  const theme = isDark ? darkTheme : lightTheme;

  const [showTaps, setShowTapsState] = useState(false);
  const [pointerLocation, setPointerLocationState] = useState(false);

  const toggleShowTaps = () => {
    const next = !showTaps;
    setShowTapsState(next);
    setShowTaps(next);
  };

  const togglePointerLocation = () => {
    const next = !pointerLocation;
    setPointerLocationState(next);
    setPointerLocation(next);
  };

  return (
    <SafeAreaView style={[styles.container, { backgroundColor: theme.bg }]}>
      <View style={styles.content}>
        <Text style={[styles.title, { color: theme.text }]}>
          Pointer Location Demo
        </Text>
        <Text style={[styles.subtitle, { color: theme.subtext }]}>
          Toggle features independently and touch anywhere on screen
        </Text>

        <View style={styles.buttonContainer}>
          <Pressable
            style={[
              styles.button,
              { backgroundColor: theme.buttonBg, borderColor: theme.border },
              showTaps && styles.buttonActive,
            ]}
            onPress={toggleShowTaps}
          >
            <Text
              style={[
                styles.buttonText,
                { color: theme.buttonText },
                showTaps && styles.buttonTextActive,
              ]}
            >
              Show Taps: {showTaps ? 'ON' : 'OFF'}
            </Text>
          </Pressable>

          <Pressable
            style={[
              styles.button,
              { backgroundColor: theme.buttonBg, borderColor: theme.border },
              pointerLocation && styles.buttonActive,
            ]}
            onPress={togglePointerLocation}
          >
            <Text
              style={[
                styles.buttonText,
                { color: theme.buttonText },
                pointerLocation && styles.buttonTextActive,
              ]}
            >
              Pointer Location: {pointerLocation ? 'ON' : 'OFF'}
            </Text>
          </Pressable>
        </View>
      </View>
    </SafeAreaView>
  );
}

const lightTheme = {
  bg: '#f5f5f5',
  text: '#1a1a1a',
  subtext: '#666',
  buttonBg: '#fff',
  buttonText: '#333',
  border: '#ddd',
};

const darkTheme = {
  bg: '#121212',
  text: '#e0e0e0',
  subtext: '#999',
  buttonBg: '#1e1e1e',
  buttonText: '#e0e0e0',
  border: '#333',
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  content: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    padding: 24,
  },
  title: {
    fontSize: 24,
    fontWeight: '700',
    marginBottom: 8,
  },
  subtitle: {
    fontSize: 14,
    textAlign: 'center',
    marginBottom: 32,
  },
  buttonContainer: {
    gap: 16,
    width: '100%',
    maxWidth: 300,
  },
  button: {
    paddingVertical: 14,
    paddingHorizontal: 24,
    borderRadius: 12,
    borderWidth: 2,
    alignItems: 'center',
  },
  buttonActive: {
    backgroundColor: '#2563eb',
    borderColor: '#2563eb',
  },
  buttonText: {
    fontSize: 16,
    fontWeight: '600',
  },
  buttonTextActive: {
    color: '#fff',
  },
});
