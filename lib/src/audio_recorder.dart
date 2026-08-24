import 'dart:async';

import 'package:webrtc_interface/webrtc_interface.dart';

import 'native/media_stream_track_impl.dart';
import 'native/utils.dart';

/// Records audio from a remote [MediaStreamTrack] (audio) to a compressed
/// M4A (AAC) file on iOS/macOS, or an AMR/WAV file on Android.
///
/// This works on iOS and Android. On the web, use [MediaRecorder] instead.
class AudioRecorder {
  AudioRecorder();

  static int _nextId = 0;
  final _recorderId = _nextId++;
  bool _isPrepared = false;
  bool _isStarted = false;

  /// Prepares the audio sink for [track] without starting the file writer.
  ///
  /// After calling this, the WebRTC audio will be audible on the device
  /// (because the sink is attached as an audio renderer), but no file is
  /// created yet. Call [start] to begin recording.
  ///
  /// [track] must be an audio track obtained from a remote [MediaStream]
  /// (i.e. received via [RTCPeerConnection.onTrack] or [onAddStream]).
  Future<void> prepare(MediaStreamTrack track) async {
    if (_isPrepared) {
      throw Exception('AudioRecorder already prepared');
    }
    if (track.kind != 'audio') {
      throw Exception('Track must be an audio track, got: ${track.kind}');
    }

    final peerConnectionId =
        track is MediaStreamTrackNative ? track.peerConnectionId : null;

    await WebRTC.invokeMethod('prepareAudioRecord', {
      'trackId': track.id,
      'recorderId': _recorderId,
      'peerConnectionId': peerConnectionId,
    });

    _isPrepared = true;
  }

  /// Starts recording audio from [track] to [path] as a compressed audio file
  /// (M4A/AAC on iOS/macOS).
  ///
  /// [track] must be an audio track obtained from a remote [MediaStream]
  /// (i.e. received via [RTCPeerConnection.onTrack] or [onAddStream]).
  ///
  /// For the new two-step flow, call [prepare] first and then use
  /// [start] without a track.
  Future<void> start(
    String path,
    MediaStreamTrack track, {
    double? recordingStartTime,
  }) async {
    if (_isPrepared) {
      return startFromPrepared(path, recordingStartTime: recordingStartTime);
    }

    if (_isStarted) {
      throw Exception('AudioRecorder already started');
    }
    if (track.kind != 'audio') {
      throw Exception('Track must be an audio track, got: ${track.kind}');
    }

    final peerConnectionId =
        track is MediaStreamTrackNative ? track.peerConnectionId : null;

    try {
      await WebRTC.invokeMethod('startAudioRecordToFile', {
        'path': path,
        'trackId': track.id,
        'recorderId': _recorderId,
        'peerConnectionId': peerConnectionId,
        if (recordingStartTime != null)
          'recordingStartTime': recordingStartTime,
      });
      _isStarted = true;
    } catch (e) {
      _isStarted = false;
      rethrow;
    }
  }

  /// Starts recording to [path] using the track passed to [prepare].
  ///
  /// If [recordingStartTime] is provided, it should be seconds since the
  /// epoch (e.g. `DateTime.now().millisecondsSinceEpoch / 1000.0`) and
  /// must match the start time used by the other stream you want to
  /// synchronize with (e.g. camera). When omitted, the legacy behavior
  /// (timeline starts at zero) is used.
  Future<void> startFromPrepared(
    String path, {
    double? recordingStartTime,
  }) async {
    if (!_isPrepared) {
      throw Exception('AudioRecorder not prepared. Call prepare() first.');
    }
    if (_isStarted) {
      throw Exception('AudioRecorder already started');
    }

    try {
      await WebRTC.invokeMethod('startAudioRecord', {
        'path': path,
        'recorderId': _recorderId,
        if (recordingStartTime != null)
          'recordingStartTime': recordingStartTime,
      });
      _isStarted = true;
    } catch (e) {
      _isStarted = false;
      rethrow;
    }
  }

  /// Stops recording and finalizes the audio file.
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
