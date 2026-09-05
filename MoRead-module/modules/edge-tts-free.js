/**
 * Edge TTS Module — Free Microsoft Edge TTS via WebSocket proxy.
 *
 * Edge TTS provides free, high-quality neural voices but uses a WebSocket
 * protocol (not REST). This module expects a lightweight local WebSocket-to-HTTP
 * bridge running on the device (e.g. via Termux + a small Node.js script).
 *
 * If no bridge is running, this module stays inactive and the built-in TTS
 * is used instead.
 *
 * Configuration (in config.json):
 *   "edgeTts.bridgeUrl" — URL of the WebSocket-to-HTTP bridge
 *                         (default: http://localhost:9880)
 *   "edgeTts.voice"     — Default Edge TTS voice name
 *                         (default: zh-CN-XiaoxiaoNeural)
 *   "edgeTts.rate"      — Speaking rate, e.g. "+0%" (default: "+0%")
 *   "edgeTts.pitch"     — Pitch adjustment (default: "+0Hz")
 *
 * Available Chinese voices include:
 *   zh-CN-XiaoxiaoNeural (female, warm)
 *   zh-CN-YunxiNeural (male, young)
 *   zh-CN-YunjianNeural (male, mature)
 *   zh-CN-XiaoyiNeural (female, lively)
 *   zh-CN-YunyangNeural (male, professional)
 */

(function () {
    var BRIDGE_URL = MoRead.configGet("edgeTts.bridgeUrl", "http://localhost:9880");
    var DEFAULT_VOICE = MoRead.configGet("edgeTts.voice", "zh-CN-XiaoxiaoNeural");
    var RATE = MoRead.configGet("edgeTts.rate", "+0%");
    var PITCH = MoRead.configGet("edgeTts.pitch", "+0Hz");

    // Map MoRead voice IDs to Edge TTS voice names
    var VOICE_MAP = {
        "female": "zh-CN-XiaoxiaoNeural",
        "male": "zh-CN-YunxiNeural",
        "narrator": "zh-CN-YunyangNeural",
        "young_female": "zh-CN-XiaoyiNeural",
        "mature_male": "zh-CN-YunjianNeural"
    };

    MoRead.log("Edge TTS module initializing...");
    MoRead.log("Bridge URL: " + BRIDGE_URL);
    MoRead.log("Default voice: " + DEFAULT_VOICE);

    // Test if bridge is available
    var test = MoRead.httpGet(BRIDGE_URL + "/health", {});
    if (!test || !test.ok) {
        MoRead.log("Edge TTS: bridge not available at " + BRIDGE_URL + ", staying inactive.");
        MoRead.log("Start a WebSocket-to-HTTP bridge (e.g. edge-tts-bridge in Termux) to activate.");
        return;
    }
    MoRead.log("Edge TTS: bridge is online ✓");

    // Register TTS hook
    MoRead.hook("tts.synthesize", function (p) {
        var text = p.text || "";
        if (!text) return null;

        // Resolve voice: try voice map, then config, then default
        var voice = DEFAULT_VOICE;
        if (p.voice && VOICE_MAP[p.voice]) {
            voice = VOICE_MAP[p.voice];
        } else if (p.voice && p.voice.startsWith("zh-")) {
            voice = p.voice;
        }

        // Build request for the bridge
        var body = JSON.stringify({
            text: text,
            voice: voice,
            rate: RATE,
            pitch: PITCH,
            format: "mp3"
        });

        var resp = MoRead.httpPost(BRIDGE_URL + "/tts", body, "application/json", {});

        if (!resp || !resp.ok) {
            MoRead.log("Edge TTS request failed: " + (resp ? resp.status : "no response"));
            return null;
        }

        // Bridge returns { "audio": "<base64 mp3>", "format": "mp3" }
        try {
            var json = JSON.parse(resp.body);
            if (json.audio || json.data) {
                return JSON.stringify({
                    audio: json.audio || json.data,
                    mediaType: "audio/" + (json.format || "mp3")
                });
            }
        } catch (e) {
            // Raw base64
            if (resp.body && resp.body.length > 100) {
                return JSON.stringify({
                    audio: resp.body,
                    mediaType: "audio/mp3"
                });
            }
        }

        return null;
    });

    MoRead.log("Edge TTS module loaded and hooked tts.synthesize ✓");
})();
