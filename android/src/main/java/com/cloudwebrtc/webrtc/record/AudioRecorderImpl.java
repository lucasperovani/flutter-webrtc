package com.cloudwebrtc.webrtc.record;

import android.os.Handler;
import android.os.HandlerThread;
import android.util.Log;

import org.webrtc.AudioTrack;
import org.webrtc.AudioTrackSink;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;


/**
 * Records PCM audio from a remote (or local) {@link AudioTrack} to a WAV file.
 *
 * <p>Uses {@link AudioTrack#addSink(AudioTrackSink)} to receive raw PCM samples
 * from the WebRTC audio pipeline and writes them as a 16-bit PCM WAV file.
 * All file I/O is performed on a dedicated background thread to avoid blocking
 * the WebRTC audio callback thread.
 */
public class AudioRecorderImpl implements AudioTrackSink {

    private static final String TAG = "AudioRecorderImpl";
    private static final int WAV_HEADER_SIZE = 44;

    private final AudioTrack audioTrack;
    private final String outputPath;
    private final HandlerThread ioThread;
    private final Handler ioHandler;

    private FileOutputStream fileOutputStream;
    private long totalDataBytes = 0;
    private int sampleRate = 0;
    private int channels = 0;
    private int bitsPerSample = 16;
    private boolean headerWritten = false;
    private volatile boolean stopped = false;

    public AudioRecorderImpl(AudioTrack audioTrack, String outputPath) {
        this.audioTrack = audioTrack;
        this.outputPath = outputPath;
        this.ioThread = new HandlerThread(TAG + "IO");
        this.ioThread.start();
        this.ioHandler = new Handler(ioThread.getLooper());
    }

    public void start() throws IOException {
        File file = new File(outputPath);
        File parent = file.getParentFile();
        if (parent != null && !parent.exists()) {
            //noinspection ResultOfMethodCallIgnored
            parent.mkdirs();
        }
        //noinspection ResultOfMethodCallIgnored
        file.createNewFile();
        fileOutputStream = new FileOutputStream(file);
        // Write placeholder header — will be patched with correct format in stop().
        writeWAVHeader(0);
        headerWritten = true;

        try {
            audioTrack.addSink(this);
        } catch (Exception e) {
            try {
                fileOutputStream.close();
            } catch (IOException ignored) {
            }
            fileOutputStream = null;
            ioThread.quit();
            throw e;
        }
    }

    @Override
    public void onData(ByteBuffer audioData, int bitsPerSample, int sampleRate,
                       int numberOfChannels, int frames, long absoluteCaptureTimestampMs) {
        if (stopped || fileOutputStream == null) {
            return;
        }

        // Capture format info from the first callback.
        if (this.sampleRate == 0) {
            this.sampleRate = sampleRate;
            this.channels = numberOfChannels;
            this.bitsPerSample = bitsPerSample;
        }

        // Copy PCM bytes — the ByteBuffer is owned by WebRTC and may be reused.
        final int dataSize = audioData.remaining();
        final byte[] pcmCopy = new byte[dataSize];
        audioData.get(pcmCopy);

        final long byteCount = dataSize;
        ioHandler.post(() -> {
            if (stopped || fileOutputStream == null) {
                return;
            }
            try {
                fileOutputStream.write(pcmCopy);
                totalDataBytes += byteCount;
            } catch (IOException e) {
                Log.e(TAG, "Failed to write audio data", e);
            }
        });
    }

    // Legacy overload (some SDK versions call this one).
    public void onData(ByteBuffer audioData, int bitsPerSample, int sampleRate,
                       int numberOfChannels, int frames) {
        onData(audioData, bitsPerSample, sampleRate, numberOfChannels, frames, 0);
    }

    private void writeWAVHeader(long dataBytes) {
        try {
            ByteBuffer header = ByteBuffer.allocate(WAV_HEADER_SIZE);
            header.order(ByteOrder.LITTLE_ENDIAN);

            int blockAlign = channels * bitsPerSample / 8;
            int byteRate = sampleRate * blockAlign;
            int chunkSize = 36 + (int) dataBytes;
            int dataSize = (int) dataBytes;

            // RIFF chunk descriptor
            header.put("RIFF".getBytes());
            header.putInt(chunkSize);
            header.put("WAVE".getBytes());

            // fmt sub-chunk
            header.put("fmt ".getBytes());
            header.putInt(16);              // sub-chunk size
            header.putShort((short) 1);    // PCM format
            header.putShort((short) channels);
            header.putInt(sampleRate);
            header.putInt(byteRate);
            header.putShort((short) blockAlign);
            header.putShort((short) bitsPerSample);

            // data sub-chunk
            header.put("data".getBytes());
            header.putInt(dataSize);

            fileOutputStream.write(header.array());
        } catch (IOException e) {
            Log.e(TAG, "Failed to write WAV header", e);
        }
    }

    private void patchWAVHeader() {
        if (fileOutputStream == null) {
            return;
        }
        FileOutputStream fos = fileOutputStream;
        fileOutputStream = null;
        try {
            fos.flush();
            fos.close();
        } catch (IOException e) {
            Log.e(TAG, "Failed to close file output stream", e);
        }

        // Default format values if no audio data was ever received.
        int sr = sampleRate > 0 ? sampleRate : 48000;
        int ch = channels > 0 ? channels : 1;
        int bps = bitsPerSample > 0 ? bitsPerSample : 16;

        int blockAlign = ch * bps / 8;
        int byteRate = sr * blockAlign;
        int chunkSize = 36 + (int) totalDataBytes;
        int dataSize = (int) totalDataBytes;

        // Rewrite the entire 44-byte header with correct format fields.
        ByteBuffer header = ByteBuffer.allocate(WAV_HEADER_SIZE);
        header.order(ByteOrder.LITTLE_ENDIAN);
        header.put("RIFF".getBytes());
        header.putInt(chunkSize);
        header.put("WAVE".getBytes());
        header.put("fmt ".getBytes());
        header.putInt(16);
        header.putShort((short) 1);
        header.putShort((short) ch);
        header.putInt(sr);
        header.putInt(byteRate);
        header.putShort((short) blockAlign);
        header.putShort((short) bps);
        header.put("data".getBytes());
        header.putInt(dataSize);

        java.io.RandomAccessFile raf = null;
        try {
            raf = new java.io.RandomAccessFile(outputPath, "rw");
            raf.seek(0);
            raf.write(header.array());
        } catch (IOException e) {
            Log.e(TAG, "Failed to patch WAV header", e);
        } finally {
            if (raf != null) {
                try {
                    raf.close();
                } catch (IOException e) {
                    Log.e(TAG, "Failed to close random access file", e);
                }
            }
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

        // Remove the sink first (stops callbacks from the audio thread).
        try {
            audioTrack.removeSink(this);
        } catch (Exception e) {
            Log.w(TAG, "removeSink failed", e);
        }

        ioHandler.post(() -> {
            patchWAVHeader();
            ioThread.quit();
            if (onComplete != null) {
                onComplete.run();
            }
        });
    }
}