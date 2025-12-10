package com.oney.WebRTCModule.palabra;

public interface PalabraListener {
    void onTranscription(String text, String lang, boolean isFinal);
    void onConnectionState(String state);
    void onError(int code, String message);
}
