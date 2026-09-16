import 'package:media_kit/src/player/native/core/playback_error.dart';
import 'package:test/test.dart';

void main() {
  group('isPrematureNetworkEof', () {
    test('detects an interrupted HTTP video', () {
      expect(
        isPrematureNetworkEof(
          uri: 'https://example.com/video.mp4',
          position: const Duration(seconds: 60),
          duration: const Duration(minutes: 5),
        ),
        isTrue,
      );
    });

    test('accepts EOF close to the natural end', () {
      expect(
        isPrematureNetworkEof(
          uri: 'https://example.com/video.mp4',
          position: const Duration(seconds: 299),
          duration: const Duration(minutes: 5),
        ),
        isFalse,
      );
    });

    test('does not classify local or explicitly clipped media', () {
      expect(
        isPrematureNetworkEof(
          uri: '/tmp/video.mp4',
          position: const Duration(seconds: 10),
          duration: const Duration(minutes: 5),
        ),
        isFalse,
      );
      expect(
        isPrematureNetworkEof(
          uri: 'https://example.com/video.mp4',
          position: const Duration(seconds: 10),
          duration: const Duration(minutes: 5),
          requestedEnd: const Duration(seconds: 10),
        ),
        isFalse,
      );
    });
  });
}
