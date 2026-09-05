/**
 * Custom TTS Module — Route TTS synthesis to a custom endpoint.
 *
 * This is a template module that demonstrates how to intercept TTS
 * synthesis and redirect it to any OpenAI-compatible or custom TTS service.
 *
 * For MultiTTS: Set up a local proxy that converts MultiTTS's private
 * protocol to OpenAI-compatible /audio/speech format, then point this
 * module at the proxy.
 *
 * Configuration (in config.json):
 *   "tts.endpoint"     — Base URL of the TTS service (e.g. "http://localhost:8080")
 *   "tts.apiKey"       — API key (if required)
 *   "tts.model"         — Model name (e.g. "cosyvoice-v1")
 *   "tts.defaultVoice" — Default voice when none specified
 *   "tts.format"       — Audio format (mp3, wav, pcm)
 */

(function () {
    var MODULE_NAME = "custom-tts";

    function getConfig() {
        return {
            endpoint: MoRead.configGet("tts.endpoint", ""),
            apiKey: MoRead.configGet("tts.apiKey", ""),
            model: MoRead.configGet("tts.model", "cosyvoice-v1"),
            defaultVoice: MoRead.configGet("tts.defaultVoice", "alloy"),
            format: MoRead.configGet("tts.format", "mp3")
        };
    }

    MoRead.log("Custom TTS module initializing...");

    // Check if endpoint is configured
    var cfg = getConfig();
    if (!cfg.endpoint) {
        MoRead.log("Custom TTS: no endpoint configured, staying inactive.");
        MoRead.log("Set tts.endpoint in config.json to activate (e.g. http://localhost:8080)");
        return;
    }

    MoRead.log("Custom TTS: endpoint = " + cfg.endpoint);

    // Register the TTS synthesis hook
    MoRead.hook("tts.synthesize", function (p) {
        var text = p.text || "";
        var voice = (p.voice || cfg.defaultVoice).trim() || cfg.defaultVoice;
        var model = p.model || cfg.model;
        var format = p.responseFormat || cfg.format;

        MoRead.log("TTS request: text=" + text.substring(0, 50) + "... voice=" + voice + " model=" + model);

        // Build OpenAI-compatible /audio/speech request body
        var body = JSON.stringify({
            model: model,
            input: text,
            voice: voice,
            response_format: format
        });

        // Build headers
        var headers = {
            "Content-Type": "application/json"
        };
        if (cfg.apiKey) {
            headers["Authorization"] = "Bearer " + cfg.apiKey;
        }

        var url = cfg.endpoint + "/v1/audio/speech";
        var resp = MoRead.httpPost(url, body, "application/json", headers);

        if (!resp || !resp.ok) {
            MoRead.log("TTS request failed: " + (resp ? resp.status : "no response"));
            return null; // Fall back to built-in TTS
        }

        // Response body is raw audio bytes (binary).
        // Since MoRead.httpPost returns text, we need the base64 encoding.
        // For binary responses, the proxy should return base64-encoded audio
        // in a JSON wrapper: { "audio": "<base64>", "mediaType": "audio/mp3" }
        // Try JSON first, fall back to raw base64.
        try {
            var json = JSON.parse(resp.body);
            if (json.audio || json.data) {
                return JSON.stringify({
                    audio: json.audio || json.data,
                    mediaType: json.mediaType || json.format || ("audio/" + format)
                });
            }
        } catch (e) {
            // Not JSON — treat response body as raw base64 audio
            if (resp.body && resp.body.length > 0) {
                return JSON.stringify({
                    audio: resp.body,
                    mediaType: "audio/" + format
                });
            }
        }

        MoRead.log("TTS: unexpected response format");
        return null;
    });

    MoRead.log("Custom TTS module loaded and hooked tts.synthesize ✓");
})();
