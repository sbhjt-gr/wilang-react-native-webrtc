package com.oney.WebRTCModule.palabra;

import android.content.Context;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import android.os.Handler;
import android.os.Looper;
import android.util.Base64;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import org.webrtc.AudioTrackSink;

import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.WebSocket;
import okhttp3.WebSocketListener;

public class PalabraClient implements AudioTrackSink {
    private static final String TAG = "PalabraClient";
    private static final int SAMPLE_RATE_IN = 16000;
    private static final int SAMPLE_RATE_OUT = 24000;
    private static final int CHANNELS = 1;
    private static final int CHUNK_MS = 320;
    private static final int CHUNK_SAMPLES = SAMPLE_RATE_IN * CHUNK_MS / 1000;
    private static final int CHUNK_BYTES = CHUNK_SAMPLES * 2;

    private final Context context;
    private final PalabraConfig config;
    private PalabraListener listener;

    private org.webrtc.AudioTrack remoteTrack;
    private OkHttpClient httpClient;
    private WebSocket webSocket;

    private AudioTrack audioPlayer;
    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final Handler mainHandler = new Handler(Looper.getMainLooper());

    private String sessionId;
    private String wsUrl;
    private String publisherToken;

    private AtomicBoolean connected = new AtomicBoolean(false);
    private AtomicBoolean translating = new AtomicBoolean(false);

    private ByteArrayOutputStream audioBuffer = new ByteArrayOutputStream();
    private final Object bufferLock = new Object();

    public PalabraClient(Context context, PalabraConfig config) {
        this.context = context;
        this.config = config;
        this.httpClient = new OkHttpClient.Builder()
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS)
            .build();
        setupAudioPlayer();
    }

    public void setListener(PalabraListener listener) {
        this.listener = listener;
    }

    public boolean isConnected() {
        return connected.get();
    }

    public boolean isTranslating() {
        return translating.get();
    }

    private void setupAudioPlayer() {
        int channelConfig = AudioFormat.CHANNEL_OUT_MONO;
        int audioFormat = AudioFormat.ENCODING_PCM_16BIT;
        int bufferSize = AudioTrack.getMinBufferSize(SAMPLE_RATE_OUT, channelConfig, audioFormat) * 2;

        audioPlayer = new AudioTrack(
            AudioManager.STREAM_VOICE_CALL,
            SAMPLE_RATE_OUT,
            channelConfig,
            audioFormat,
            bufferSize,
            AudioTrack.MODE_STREAM
        );
    }

    public void start(org.webrtc.AudioTrack remoteAudioTrack) {
        if (translating.get()) {
            return;
        }

        this.remoteTrack = remoteAudioTrack;
        remoteAudioTrack.setVolume(0);

        notifyConnectionState("connecting");

        executor.execute(() -> {
            try {
                JSONObject session = createSession();
                Log.d(TAG, "session_response: " + session.toString());
                JSONObject data = session.getJSONObject("data");
                sessionId = data.getString("id");
                wsUrl = data.getString("ws_url");
                publisherToken = data.getString("publisher");
                Log.d(TAG, "ws_url: " + wsUrl);

                mainHandler.post(this::connectWebSocket);
            } catch (Exception e) {
                Log.e(TAG, "session_create_failed", e);
                mainHandler.post(() -> {
                    if (remoteAudioTrack != null) {
                        remoteAudioTrack.setVolume(1.0);
                    }
                    notifyError(500, e.getMessage());
                });
            }
        });
    }

    private JSONObject createSession() throws IOException, JSONException {
        URL url = new URL(config.apiUrl + "/session-storage/session");
        HttpURLConnection conn = (HttpURLConnection) url.openConnection();
        conn.setRequestMethod("POST");
        conn.setRequestProperty("ClientId", config.clientId);
        conn.setRequestProperty("ClientSecret", config.clientSecret);
        conn.setRequestProperty("Content-Type", "application/json");
        conn.setDoOutput(true);

        JSONObject body = new JSONObject();
        JSONObject bodyData = new JSONObject();
        bodyData.put("subscriber_count", 0);
        bodyData.put("publisher_can_subscribe", true);
        body.put("data", bodyData);

        try (OutputStream os = conn.getOutputStream()) {
            os.write(body.toString().getBytes(StandardCharsets.UTF_8));
        }

        int responseCode = conn.getResponseCode();
        if (responseCode < 200 || responseCode >= 300) {
            throw new IOException("session_http_error_" + responseCode);
        }

        StringBuilder response = new StringBuilder();
        try (BufferedReader br = new BufferedReader(new InputStreamReader(conn.getInputStream()))) {
            String line;
            while ((line = br.readLine()) != null) {
                response.append(line);
            }
        }

        return new JSONObject(response.toString());
    }

    private void connectWebSocket() {
        String endpoint = wsUrl + "?token=" + publisherToken;
        Log.d(TAG, "connecting_ws: " + endpoint);

        Request request = new Request.Builder()
            .url(endpoint)
            .build();

        webSocket = httpClient.newWebSocket(request, new WebSocketListener() {
            @Override
            public void onOpen(WebSocket ws, Response response) {
                Log.d(TAG, "ws_open");
                connected.set(true);
                translating.set(true);

                remoteTrack.addSink(PalabraClient.this);
                audioPlayer.play();

                mainHandler.post(() -> notifyConnectionState("connected"));

                mainHandler.postDelayed(() -> sendSetTask(), 500);
            }

            @Override
            public void onMessage(WebSocket ws, String text) {
                handleMessage(text);
            }

            @Override
            public void onFailure(WebSocket ws, Throwable t, Response response) {
                Log.e(TAG, "ws_error", t);
                mainHandler.post(() -> {
                    stop();
                    notifyError(500, t.getMessage());
                });
            }

            @Override
            public void onClosed(WebSocket ws, int code, String reason) {
                Log.d(TAG, "ws_closed: " + code);
                mainHandler.post(() -> stop());
            }
        });
    }

    private void sendSetTask() {
        if (webSocket == null || !connected.get()) {
            return;
        }

        try {
            JSONObject msg = new JSONObject();
            msg.put("message_type", "set_task");

            JSONObject data = new JSONObject();

            JSONObject inputStream = new JSONObject();
            inputStream.put("content_type", "audio");
            JSONObject source = new JSONObject();
            source.put("type", "ws");
            source.put("format", "pcm_s16le");
            source.put("sample_rate", SAMPLE_RATE_IN);
            source.put("channels", CHANNELS);
            inputStream.put("source", source);
            data.put("input_stream", inputStream);

            JSONObject outputStream = new JSONObject();
            outputStream.put("content_type", "audio");
            JSONObject target = new JSONObject();
            target.put("type", "ws");
            target.put("format", "pcm_s16le");
            outputStream.put("target", target);
            data.put("output_stream", outputStream);

            JSONObject pipeline = new JSONObject();

            JSONObject transcription = new JSONObject();
            transcription.put("source_language", config.sourceLang);
            pipeline.put("transcription", transcription);

            JSONArray translations = new JSONArray();
            JSONObject translation = new JSONObject();
            translation.put("target_language", config.targetLang);
            JSONObject speechGen = new JSONObject();
            speechGen.put("voice_cloning", false);
            translation.put("speech_generation", speechGen);
            translations.put(translation);
            pipeline.put("translations", translations);

            JSONArray allowedTypes = new JSONArray();
            allowedTypes.put("partial_transcription");
            allowedTypes.put("validated_transcription");
            allowedTypes.put("translated_transcription");
            pipeline.put("allowed_message_types", allowedTypes);

            data.put("pipeline", pipeline);
            msg.put("data", data);

            String payload = msg.toString();
            Log.d(TAG, "set_task: " + payload);
            webSocket.send(payload);
        } catch (JSONException e) {
            Log.e(TAG, "set_task_error", e);
        }
    }

    private void handleMessage(String text) {
        try {
            JSONObject json = new JSONObject(text);
            String type = json.optString("message_type", "");

            if ("output_audio_data".equals(type)) {
                JSONObject data = json.getJSONObject("data");
                String audioBase64 = data.optString("data", "");
                if (!audioBase64.isEmpty()) {
                    byte[] audioBytes = Base64.decode(audioBase64, Base64.DEFAULT);
                    if (audioPlayer != null && translating.get()) {
                        audioPlayer.write(audioBytes, 0, audioBytes.length);
                    }
                }
            } else if (type.contains("transcription")) {
                JSONObject data = json.getJSONObject("data");
                JSONObject transcription = data.optJSONObject("transcription");
                if (transcription != null) {
                    String txt = transcription.optString("text", "");
                    String lang = transcription.optString("language", "");
                    boolean isFinal = !"partial_transcription".equals(type);
                    mainHandler.post(() -> notifyTranscription(txt, lang, isFinal));
                }
            } else if ("error".equals(type)) {
                JSONObject data = json.optJSONObject("data");
                String desc = data != null ? data.optString("desc", "unknown") : "unknown";
                Log.e(TAG, "palabra_error: " + desc);
                mainHandler.post(() -> notifyError(500, desc));
            }
        } catch (JSONException e) {
            Log.e(TAG, "msg_parse_error", e);
        }
    }

    public void stop() {
        if (!translating.getAndSet(false)) {
            return;
        }

        connected.set(false);

        if (remoteTrack != null) {
            try {
                remoteTrack.removeSink(this);
                remoteTrack.setVolume(1.0);
            } catch (Exception e) {
                Log.w(TAG, "stop_track_cleanup_error: " + e.getMessage());
            }
        }

        if (webSocket != null) {
            try {
                JSONObject endMsg = new JSONObject();
                endMsg.put("message_type", "end_task");
                endMsg.put("data", new JSONObject().put("force", false));
                webSocket.send(endMsg.toString());
            } catch (JSONException e) {
                Log.e(TAG, "end_task_error", e);
            }
            try {
                webSocket.close(1000, "stop");
            } catch (Exception e) {
                Log.w(TAG, "websocket_close_error: " + e.getMessage());
            }
            webSocket = null;
        }

        if (audioPlayer != null) {
            try {
                audioPlayer.stop();
            } catch (Exception e) {
                Log.w(TAG, "audio_player_stop_error: " + e.getMessage());
            }
        }

        synchronized (bufferLock) {
            audioBuffer.reset();
        }

        remoteTrack = null;
        notifyConnectionState("disconnected");
    }

    @Override
    public void onData(ByteBuffer audioData, int bitsPerSample, int sampleRate, int channels, int frames, long timestamp) {
        if (!translating.get() || webSocket == null) {
            return;
        }

        byte[] samples = new byte[audioData.remaining()];
        audioData.get(samples);

        byte[] resampled = resample(samples, sampleRate, channels, SAMPLE_RATE_IN, CHANNELS);

        synchronized (bufferLock) {
            try {
                audioBuffer.write(resampled);

                while (audioBuffer.size() >= CHUNK_BYTES) {
                    byte[] chunk = new byte[CHUNK_BYTES];
                    byte[] all = audioBuffer.toByteArray();
                    System.arraycopy(all, 0, chunk, 0, CHUNK_BYTES);

                    audioBuffer.reset();
                    if (all.length > CHUNK_BYTES) {
                        audioBuffer.write(all, CHUNK_BYTES, all.length - CHUNK_BYTES);
                    }

                    sendAudioChunk(chunk);
                }
            } catch (IOException e) {
                Log.e(TAG, "buffer_error", e);
            }
        }
    }

    private byte[] resample(byte[] input, int srcRate, int srcChannels, int dstRate, int dstChannels) {
        if (srcRate == dstRate && srcChannels == dstChannels) {
            return input;
        }

        int srcSamples = input.length / (2 * srcChannels);
        int dstSamples = (int) ((long) srcSamples * dstRate / srcRate);

        short[] srcData = new short[srcSamples * srcChannels];
        ByteBuffer.wrap(input).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(srcData);

        short[] monoSrc = srcData;
        if (srcChannels == 2) {
            monoSrc = new short[srcSamples];
            for (int i = 0; i < srcSamples; i++) {
                monoSrc[i] = (short) ((srcData[i * 2] + srcData[i * 2 + 1]) / 2);
            }
        }

        short[] dstData = new short[dstSamples];
        for (int i = 0; i < dstSamples; i++) {
            float srcIdx = (float) i * (monoSrc.length - 1) / (dstSamples - 1);
            int idx0 = (int) srcIdx;
            int idx1 = Math.min(idx0 + 1, monoSrc.length - 1);
            float frac = srcIdx - idx0;
            dstData[i] = (short) (monoSrc[idx0] * (1 - frac) + monoSrc[idx1] * frac);
        }

        byte[] output = new byte[dstSamples * 2];
        ByteBuffer.wrap(output).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().put(dstData);
        return output;
    }

    private void sendAudioChunk(byte[] chunk) {
        if (webSocket == null || !connected.get()) {
            return;
        }

        try {
            JSONObject msg = new JSONObject();
            msg.put("message_type", "input_audio_data");
            JSONObject data = new JSONObject();
            data.put("data", Base64.encodeToString(chunk, Base64.NO_WRAP));
            msg.put("data", data);
            webSocket.send(msg.toString());
        } catch (JSONException e) {
            Log.e(TAG, "send_audio_error", e);
        }
    }

    private void notifyConnectionState(String state) {
        if (listener != null) {
            listener.onConnectionState(state);
        }
    }

    private void notifyError(int code, String message) {
        if (listener != null) {
            listener.onError(code, message);
        }
    }

    private void notifyTranscription(String text, String lang, boolean isFinal) {
        if (listener != null) {
            listener.onTranscription(text, lang, isFinal);
        }
    }
}
