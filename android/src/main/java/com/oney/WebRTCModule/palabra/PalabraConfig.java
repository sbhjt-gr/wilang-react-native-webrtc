package com.oney.WebRTCModule.palabra;

public class PalabraConfig {
    public final String clientId;
    public final String clientSecret;
    public final String sourceLang;
    public final String targetLang;
    public final String apiUrl;

    public PalabraConfig(String clientId, String clientSecret, String sourceLang, String targetLang, String apiUrl) {
        this.clientId = clientId;
        this.clientSecret = clientSecret;
        this.sourceLang = sourceLang;
        this.targetLang = targetLang;
        this.apiUrl = apiUrl;
    }
}
