package com.cloudwebrtc.webrtc.record;

import android.content.Context;
import android.media.AudioManager;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.media.MediaMuxer;
import android.media.audiofx.AcousticEchoCanceler;
import android.media.audiofx.NoiseSuppressor;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Log;

import org.webrtc.AudioTrack;
import org.webrtc.AudioTrackSink;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * Records audio from a remote (or local) {@link AudioTrack} to a compressed
 * M4A/AAC file, mirroring the iOS {@code FlutterRTCAudioRecorder} behaviour.
 *
 * <p>Uses {@link AudioTrack#addSink(AudioTrackSink)} to receive raw PCM samples
 * from the WebRTC audio pipeline, encodes them to AAC with {@link MediaCodec}
 * and muxes into an MPEG-4 container with {@link MediaMuxer}.
 *
 * <p>While recording, the audio session is switched to
 * {@link AudioManager#MODE_IN_COMMUNICATION} and acoustic echo cancellation /
 * noise suppression are enabled when available. The previous audio mode is
 * restored when recording stops.
 */
public class AudioRecorderImpl implements AudioTrackSink {

    private static final String TAG = "AudioRecorderImpl";
    private static final String MIME_TYPE = "audio/mp4a-latm";
    private static final int BIT_RATE = 128 * 1024; // 128 kbps AAC
    private static final long RELEASE_TIMEOUT_MS = 2000;

    private final Context context;
    private final AudioTrack audioTrack;
    private final String outputPath;
    private final HandlerThread audioThread;
    private final Handler audioThreadHandler;

    private MediaCodec audioEncoder;
    private MediaMuxer mediaMuxer;
    private MediaCodec.BufferInfo audioBufferInfo;
    private ByteBuffer[] audioInputBuffers;
    private ByteBuffer[] audioOutputBuffers;

    private int audioTrackIndex = -1;
    private boolean audioEncoderStarted = false;
    private volatile boolean muxerStarted = false;
    private volatile boolean isRunning = true;
    private boolean isInitialized = false;
    private volatile boolean stopped = false;

    private int sampleRate = 0;
    private int channels = 0;
    private int bitsPerSample = 16;
    private long presentationTimeUs = 0L;

    // Audio session state saved before recording so it can be restored.
    private AudioManager audioManager;
    private int previousAudioMode = AudioManager.MODE_NORMAL;
    private boolean previousSpeakerphoneOn = false;
    private AcousticEchoCanceler acousticEchoCanceler;
    private NoiseSuppressor noiseSuppressor;

    public AudioRecorderImpl(Context context, AudioTrack audioTrack, String outputPath) {
        this.context = context.getApplicationContext();
        this.audioTrack = audioTrack;
        this.outputPath = outputPath;
        this.audioThread = new HandlerThread(TAG + "AudioThread");
        this.audioThread.start();
        this.audioThreadHandler = new Handler(audioThread.getLooper());
    }

    public void start() throws IOException {
        File file = new File(outputPath);
        File parent = file.getParentFile();
        if (parent != null && !parent.exists()) {
            //noinspection ResultOfMethodCallIgnored
            parent.mkdirs();
        }

        // Prepare the muxer before any audio arrives.
        mediaMuxer = new MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);

        applyEchoCancellationAudioSession();

        try {
            audioTrack.addSink(this);
        } catch (Exception e) {
            releaseEncoderAndMuxer();
            restoreAudioSession();
            throw e;
        }
    }

    @Override
    public void onData(ByteBuffer audioData, int bitsPerSample, int sampleRate,
                       int numberOfChannels, int frames, long absoluteCaptureTimestampMs) {
        if (stopped || !isRunning) {
            return;
        }

        if (this.sampleRate == 0) {
            this.sampleRate = sampleRate;
            this.channels = numberOfChannels;
            this.bitsPerSample = bitsPerSample;
        }

        final int dataSize = audioData.remaining();
        if (dataSize == 0) {
            return;
        }
        final byte[] pcmCopy = new byte[dataSize];
        audioData.get(pcmCopy);

        audioThreadHandler.post(() -> {
            if (stopped || !isRunning) {
                return;
            }
            try {
                initializeEncoderIfNeeded();
                if (audioEncoder == null || !audioEncoderStarted) {
                    Log.w(TAG, "Encoder not ready, dropping audio frame");
                    return;
                }
                feedEncoder(pcmCopy);
                drainEncoder();
            } catch (Exception e) {
                Log.e(TAG, "Error processing audio data", e);
            }
        });
    }

    // Legacy overload used by some WebRTC SDK versions.
    public void onData(ByteBuffer audioData, int bitsPerSample, int sampleRate,
                       int numberOfChannels, int frames) {
        onData(audioData, bitsPerSample, sampleRate, numberOfChannels, frames, 0);
    }

    private void initializeEncoderIfNeeded() throws IOException {
        if (audioEncoder != null || sampleRate == 0 || channels == 0) {
            return;
        }

        MediaFormat format = new MediaFormat();
        format.setString(MediaFormat.KEY_MIME, MIME_TYPE);
        format.setInteger(MediaFormat.KEY_CHANNEL_COUNT, channels);
        format.setInteger(MediaFormat.KEY_SAMPLE_RATE, sampleRate);
        format.setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE);
        format.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC);

        audioEncoder = MediaCodec.createEncoderByType(MIME_TYPE);
        audioEncoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
        audioEncoder.start();

        audioInputBuffers = audioEncoder.getInputBuffers();
        audioOutputBuffers = audioEncoder.getOutputBuffers();
        audioEncoderStarted = true;
        isInitialized = true;

        Log.i(TAG, "Audio encoder initialized: " + sampleRate + " Hz, " + channels + " channels");
    }

    private void feedEncoder(byte[] pcmData) {
        if (audioEncoder == null) {
            return;
        }
        int inputBufferIndex = audioEncoder.dequeueInputBuffer(0);
        if (inputBufferIndex < 0) {
            return;
        }
        ByteBuffer buffer = audioInputBuffers[inputBufferIndex];
        buffer.clear();

        // WebRTC delivers PCM as int16. Each sample is 2 bytes.
        int bytesPerSample = bitsPerSample / 8;
        long frameTimeUs = (long) pcmData.length * 1_000_000L
                / (bytesPerSample * sampleRate * channels);

        if (pcmData.length <= buffer.remaining()) {
            buffer.put(pcmData);
            audioEncoder.queueInputBuffer(inputBufferIndex, 0, pcmData.length, presentationTimeUs, 0);
            presentationTimeUs += frameTimeUs;
        } else {
            Log.w(TAG, "Audio data too large for encoder buffer: " + pcmData.length);
            audioEncoder.queueInputBuffer(inputBufferIndex, 0, 0, presentationTimeUs, 0);
        }
    }

    private void drainEncoder() {
        if (audioBufferInfo == null) {
            audioBufferInfo = new MediaCodec.BufferInfo();
        }
        if (audioEncoder == null) {
            return;
        }

        while (isRunning) {
            int encoderStatus = audioEncoder.dequeueOutputBuffer(audioBufferInfo, 0);
            if (encoderStatus == MediaCodec.INFO_TRY_AGAIN_LATER) {
                break;
            } else if (encoderStatus == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED) {
                audioOutputBuffers = audioEncoder.getOutputBuffers();
            } else if (encoderStatus == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                MediaFormat newFormat = audioEncoder.getOutputFormat();
                if (audioTrackIndex == -1 && mediaMuxer != null) {
                    audioTrackIndex = mediaMuxer.addTrack(newFormat);
                    if (audioTrackIndex != -1 && !muxerStarted) {
                        mediaMuxer.start();
                        muxerStarted = true;
                    }
                }
                if (!muxerStarted) {
                    break;
                }
            } else if (encoderStatus < 0) {
                Log.e(TAG, "Unexpected encoder status: " + encoderStatus);
                break;
            } else {
                ByteBuffer encodedData = audioOutputBuffers[encoderStatus];
                if (encodedData == null) {
                    Log.e(TAG, "Encoder output buffer is null");
                    break;
                }
                encodedData.position(audioBufferInfo.offset);
                encodedData.limit(audioBufferInfo.offset + audioBufferInfo.size);

                if (muxerStarted && audioTrackIndex != -1) {
                    mediaMuxer.writeSampleData(audioTrackIndex, encodedData, audioBufferInfo);
                }
                audioEncoder.releaseOutputBuffer(encoderStatus, false);

                if ((audioBufferInfo.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                    break;
                }
            }
        }
    }

    private void applyEchoCancellationAudioSession() {
        audioManager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        if (audioManager == null) {
            Log.w(TAG, "AudioManager not available");
            return;
        }

        previousAudioMode = audioManager.getMode();
        previousSpeakerphoneOn = audioManager.isSpeakerphoneOn();

        try {
            audioManager.setMode(AudioManager.MODE_IN_COMMUNICATION);
            audioManager.setSpeakerphoneOn(true);
        } catch (Exception e) {
            Log.w(TAG, "Failed to set audio mode/speakerphone", e);
        }

        try {
            if (AcousticEchoCanceler.isAvailable()) {
                // Session ID 0 applies to the global audio output mix.
                acousticEchoCanceler = AcousticEchoCanceler.create(0);
                if (acousticEchoCanceler != null) {
                    acousticEchoCanceler.setEnabled(true);
                }
            }
            if (NoiseSuppressor.isAvailable()) {
                noiseSuppressor = NoiseSuppressor.create(0);
                if (noiseSuppressor != null) {
                    noiseSuppressor.setEnabled(true);
                }
            }
        } catch (Exception e) {
            Log.w(TAG, "Failed to create audio effects", e);
        }
    }

    private void restoreAudioSession() {
        if (audioManager != null) {
            try {
                audioManager.setMode(previousAudioMode);
                audioManager.setSpeakerphoneOn(previousSpeakerphoneOn);
            } catch (Exception e) {
                Log.w(TAG, "Failed to restore audio session", e);
            }
        }

        if (acousticEchoCanceler != null) {
            try {
                acousticEchoCanceler.setEnabled(false);
                acousticEchoCanceler.release();
            } catch (Exception e) {
                Log.w(TAG, "Failed to release AEC", e);
            }
            acousticEchoCanceler = null;
        }

        if (noiseSuppressor != null) {
            try {
                noiseSuppressor.setEnabled(false);
                noiseSuppressor.release();
            } catch (Exception e) {
                Log.w(TAG, "Failed to release NS", e);
            }
            noiseSuppressor = null;
        }
    }

    public void stop(final Runnable onComplete) {
        if (stopped) {
            if (onComplete != null) {
                onComplete.run();
            }
            return;
        }
        stopped = true;
        isRunning = false;

        // Remove the sink first (stops callbacks from the WebRTC audio thread).
        try {
            audioTrack.removeSink(this);
        } catch (Exception e) {
            Log.w(TAG, "removeSink failed", e);
        }

        audioThreadHandler.post(() -> {
            try {
                // If no audio buffer ever arrived, create an empty output file so callers
                // can still attempt muxing (FFmpeg will handle the missing audio).
                if (!isInitialized) {
                    Log.w(TAG, "stop called before any audio buffer; creating empty file");
                    releaseEncoderAndMuxer();
                    createEmptyFile();
                    restoreAudioSession();
                    finishThread();
                    if (onComplete != null) {
                        onComplete.run();
                    }
                    return;
                }

                // Signal end of stream and drain remaining encoded data.
                if (audioEncoder != null && audioEncoderStarted) {
                    try {
                        int inputBufferIndex = audioEncoder.dequeueInputBuffer(10000);
                        if (inputBufferIndex >= 0) {
                            audioEncoder.queueInputBuffer(inputBufferIndex, 0, 0, 0,
                                    MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                        }
                        drainEncoder();
                        audioEncoder.stop();
                        audioEncoderStarted = false;
                    } catch (Exception e) {
                        Log.e(TAG, "Error stopping audio encoder", e);
                    }
                }

                releaseEncoderAndMuxer();
                restoreAudioSession();
                finishThread();

                if (onComplete != null) {
                    onComplete.run();
                }
            } catch (Exception e) {
                Log.e(TAG, "Error during stop", e);
                restoreAudioSession();
                finishThread();
                if (onComplete != null) {
                    onComplete.run();
                }
            }
        });
    }

    private void createEmptyFile() {
        try {
            File file = new File(outputPath);
            File parent = file.getParentFile();
            if (parent != null && !parent.exists()) {
                //noinspection ResultOfMethodCallIgnored
                parent.mkdirs();
            }
            try (FileOutputStream fos = new FileOutputStream(file)) {
                // Empty MPEG-4 container.
            }
        } catch (IOException e) {
            Log.e(TAG, "Failed to create empty output file", e);
        }
    }

    private void releaseEncoderAndMuxer() {
        if (audioEncoder != null) {
            try {
                if (audioEncoderStarted) {
                    audioEncoder.stop();
                    audioEncoderStarted = false;
                }
                audioEncoder.release();
            } catch (Exception e) {
                Log.e(TAG, "Error releasing audio encoder", e);
            }
            audioEncoder = null;
        }
        if (mediaMuxer != null) {
            try {
                if (muxerStarted && audioTrackIndex != -1) {
                    mediaMuxer.stop();
                    muxerStarted = false;
                }
                mediaMuxer.release();
            } catch (Exception e) {
                Log.e(TAG, "Error releasing muxer", e);
            }
            mediaMuxer = null;
        }
    }

    private void finishThread() {
        if (audioThread != null) {
            try {
                audioThread.quit();
            } catch (Exception e) {
                Log.w(TAG, "Error quitting audio thread", e);
            }
        }
    }

    /**
     * Releases resources if the recorder was abandoned without calling {@link #stop(Runnable)}.
     */
    public void release() {
        if (!stopped) {
            stop(null);
            return;
        }
        CountDownLatch latch = new CountDownLatch(1);
        audioThreadHandler.post(() -> {
            releaseEncoderAndMuxer();
            restoreAudioSession();
            finishThread();
            latch.countDown();
        });
        try {
            if (!latch.await(RELEASE_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                Log.w(TAG, "Release timed out");
            }
        } catch (InterruptedException e) {
            Log.e(TAG, "Release interrupted", e);
            Thread.currentThread().interrupt();
        }
    }
}