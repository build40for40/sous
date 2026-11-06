import 'package:flutter_test/flutter_test.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:sous/shares/share_receiver.dart';

void main() {
  test('turns shared links and text into text, and images into files', () {
    final incoming = SystemShareReceiver.toIncoming([
      SharedMediaFile(
        path: 'https://www.instagram.com/reel/X/?igsh=1',
        type: SharedMediaType.url,
      ),
      SharedMediaFile(
        path: '  Look https://example.com/r  ',
        type: SharedMediaType.text,
      ),
      SharedMediaFile(path: '/cache/shot.png', type: SharedMediaType.image),
      SharedMediaFile(
        path: '/cache/doc.jpg',
        type: SharedMediaType.file,
        mimeType: 'image/jpeg',
      ),
      SharedMediaFile(path: '/cache/clip.mp4', type: SharedMediaType.video),
      SharedMediaFile(
        path: '/cache/notes.pdf',
        type: SharedMediaType.file,
        mimeType: 'application/pdf',
      ),
      SharedMediaFile(path: '   ', type: SharedMediaType.text),
    ]);
    expect(incoming, const [
      IncomingText('https://www.instagram.com/reel/X/?igsh=1'),
      IncomingText('Look https://example.com/r'),
      IncomingImage('/cache/shot.png'),
      IncomingImage('/cache/doc.jpg'),
    ]);
  });

  test('yields what opened the app, then later shares, and resets', () async {
    ReceiveSharingIntent.setMockValues(
      initialMedia: [
        SharedMediaFile(
          path: 'https://instagram.com/p/A',
          type: SharedMediaType.url,
        ),
      ],
      mediaStream: Stream.value([
        SharedMediaFile(path: '/c/b.png', type: SharedMediaType.image),
      ]),
    );
    final got = await SystemShareReceiver().shares().toList();
    expect(got, const [
      IncomingText('https://instagram.com/p/A'),
      IncomingImage('/c/b.png'),
    ]);
  });
}
