import 'dart:async';

import 'package:webrtc_interface/webrtc_interface.dart';

import 'native/media_stream_track_impl.dart';
import 'native/utils.dart';

/// Records PCM audio from a remote [MediaStreamTrack] (audio) to a WAV file.
///
/// This works on iOS and Android. On the web, use [MediaRecorder] instead.
class AudioRecorder {
  AudioRecorder();

  static int _nextId = 0;
  final _recorderId = _nextId++;
  bool _isStarted = false;

  /// Starts recording audio from [track] to [path] as a WAV file (PCM 16-bit).
  ///
  /// [track] must be an audio track obtained from a remote [MediaStream]
  /// (i.e. received via [RTCPeerConnection.onTrack] or [onAddStream]).
  Future<void> start(String path, MediaStreamTrack track) async {
    if (_isStarted) {
      throw Exception('AudioRecorder already started');
    }
    if (track.kind != 'audio') {
      throw Exception('Track must be an audio track, got: ${track.kind}');
    }

    final peerConnectionId = track is MediaStreamTrackNative
        ? track.peerConnectionId
        : null;

    try {
      await WebRTC.invokeMethod('startAudioRecordToFile', {
        'path': path,
        'trackId': track.id,
        'recorderId': _recorderId,
        'peerConnectionId': peerConnectionId,
      });
      _isStarted = true;
    } catch (e) {
      _isStarted = false;
      rethrow;
    }
  }

  /// Stops recording and finalizes the WAV file.
  Future<void> stop() async {
    if (!_isStarted) {
      throw Exception('AudioRecorder not started');
    }
    try {
      await WebRTC.invokeMethod('stopAudioRecordToFile', {
        'recorderId': _recorderId,
      });
    } finally {
      _isStarted = false;
    }
  }

  /// Releases native resources if the recorder is still active.
  /// Call this if you need to abort recording without finalizing the file.
  Future<void> dispose() async {
    if (_isStarted) {
      await stop();
    }
  }
}