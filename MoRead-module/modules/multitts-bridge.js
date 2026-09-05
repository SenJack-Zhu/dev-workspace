/**
 * MultiTTS Bridge Module — Connect MoRead to a local MultiTTS server.
 *
 * MultiTTS is a powerful TTS aggregation gateway with:
 *   - Multi-protocol support (Edge TTS, CosyVoice, Bert-VITS2, etc.)
 *   - Role pool & voice pool management
 *   - Regex-based text preprocessing
 *   - Role analysis features
 *
 * Since MultiTTS uses a private protocol (not standard OpenAI API),
 * this module acts as a protocol bridge by sending requests to the
 * MultiTTS HTTP API port and returning results in MoRead's expected format.
 *
 * Configuration (in config.json):
 *   "multitts.endpoint"  — MultiTTS HTTP API endpoint
 *                           (default: http://localhost:8080)
 *   "multitts.defaultVoice" — Default voice ID when none is specified
 */

(function () {
    var ENDPOINT = MoRead.configGet("multitts.endpoint", "");
    var DEFAULT_VOICE = MoRead.configGet("multitts.defaultVoice", "");

    MoRead.log("MultiTTS Bridge module initializing...");

    if (!ENDPOINT) {
        MoRead.log("MultiTTS: no endpoint configured, staying inactive.");
        MoRead.log("Set multitts.endpoint in config.json to activate");
        MoRead.log("(e.g. http://localhost:8080)");
        return;
    }

    // Test connectivity
    var test = MoRead.httpGet(ENDPOINT + "/api/voices", {});
    if (!test || !test.ok) {
        MoRead.log("MultiTTS: server not reachable at " + ENDPOINT);
        MoRead.log("Make sure MultiTTS is running and the HTTP API port is correct.");
        return;
    }

    // Load voice list
    var voices = {};
    try {
        var voiceList = JSON.parse(test.body);
        if (Array.isArray(voiceList)) {
            voiceList.forEach(function (v) {
                if (v.id && v.name) {
                    voices[v.id] = v.name;
                }
            });
            MoRead.log("MultiTTS: loaded " + Object.keys(voices).length + " voices");
        }
    } catch (e) {
        MoRead.log("MultiTTS: could not parse voice list, continuing anyway");
    }

    // Register TTS synthesis hook
    MoRead.hook("tts.synthesize", function (p) {
        var text = p.text || "";
        if (!text) return null;

        var voice = (p.voice || DEFAULT_VOICE).trim();
        if (!voice) {
            // Pick first available voice
            voice = Object.keys(voices)[0] || "";
        }

        MoRead.log("MultiTTS: synthesize voice=" + voice + " text=" + text.substring(0, 40) + "...");

        // MultiTTS API: POST /api/tts
        // Body: { "text": "...", "voice": "...", "format": "mp3" }
        var body = JSON.stringify({
            text: text,
            voice: voice,
            format: "mp3"
        });

        var resp = MoRead.httpPost(ENDPOINT + "/api/tts", body, "application/json", {});

        if (!resp || !resp.ok) {
            MoRead.log("MultiTTS: request failed: " + (resp ? resp.status : "no response"));
            return null; // Fall back to built-in TTS
        }

        // MultiTTS returns audio in one of these formats:
        // 1. Raw audio bytes (binary) — we can't handle binary directly via HTTP text
        // 2. Base64-encoded audio in JSON: { "audio": "<base64>", "format": "mp3" }
        // 3. Base64-encoded audio as plain text
        try {
            var json = JSON.parse(resp.body);
            if (json.audio || json.data || json.audio_base64) {
                return JSON.stringify({
                    audio: json.audio || json.data || json.audio_base64,
                    mediaType: "audio/" + (json.format || "mp3")
                });
            }
        } catch (e) {
            // Treat as raw base64 if it looks valid
            if (resp.body && resp.body.length > 100 && /^[A-Za-z0-9+/=\s]+$/.test(resp.body)) {
                return JSON.stringify({
                    audio: resp.body.replace(/\s/g, ""),
                    mediaType: "audio/mp3"
                });
            }
        }

        MoRead.log("MultiTTS: unexpected response format, falling back");
        return null;
    });

    // Register dialogue segment hook (optional: use MultiTTS role analysis)
    // Only enable if the MultiTTS server supports role analysis
    var roleAnalysisAvailable = false;
    var roleTest = MoRead.httpGet(ENDPOINT + "/api/roles", {});
    if (roleTest && roleTest.ok) {
        roleAnalysisAvailable = true;
        MoRead.log("MultiTTS: role analysis API detected ✓");
    }

    if (roleAnalysisAvailable) {
        MoRead.hook("dialogue.segment", function (p) {
            var text = p.text || "";
            if (!text || text.length < 100) return null; // Don't send short texts

            // Use MultiTTS role analysis API
            var body = JSON.stringify({ text: text });
            var resp = MoRead.httpPost(ENDPOINT + "/api/analyze-roles", body, "application/json", {});

            if (!resp || !resp.ok) return null;

            try {
                var result = JSON.parse(resp.body);
                if (result.segments && Array.isArray(result.segments)) {
                    return JSON.stringify(result.segments.map(function (s) {
                        return {
                            start: s.start,
                            end: s.end,
                            role: s.role || s.speaker || "对白",
                            kind: s.is_dialogue ? "DIALOGUE" : "NARRATION",
                            confidence: s.confidence || 0.8
                        };
                    }));
                }
            } catch (e) {
                MoRead.log("MultiTTS: role analysis parse error: " + e.message);
            }

            return null; // Fall back to built-in segmentation
        });
        MoRead.log("MultiTTS: hooked dialogue.segment ✓");
    }

    MoRead.log("MultiTTS Bridge module loaded ✓");
    MoRead.log("  - TTS synthesis hooked");
    if (roleAnalysisAvailable) {
        MoRead.log("  - Dialogue segmentation hooked");
    }
})();
