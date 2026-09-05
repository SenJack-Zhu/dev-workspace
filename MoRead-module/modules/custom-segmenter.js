/**
 * Custom Dialogue Segmenter Module — Override dialogue/narration segmentation.
 *
 * This module demonstrates how to replace MoRead's built-in dialogue
 * segmentation with custom rules. The JS module receives the full chapter
 * text and returns an array of segments with character offsets.
 *
 * Segment format:
 *   [{ "start": 0, "end": 48, "role": "旁白", "kind": "NARRATION", "confidence": 0.9 }, ...]
 *
 * kind values: "DIALOGUE" or "NARRATION"
 * start/end are UTF-16 character offsets in the chapter text
 */

(function () {
    // Custom dialogue detection patterns
    var QUOTE_PAIRS = {
        '"': '"',
        '"': '"',
        '「': '」',
        '『': '』',
        ''': '''
    };

    // Speaker patterns: "Name said:" or "Name said,"
    var SPEAKER_PATTERN = /^([^\s,，。：]{1,10})(说道|说|道|问|答|喊|叫|笑道|喝道|冷声道|怒道|低声道|轻声道)/;

    // Invalid speaker names (pronouns, generic words)
    var INVALID_SPEAKERS = ["他", "她", "它", "我", "你", "你们", "他们", "她们", "有人", "那人", "众人", "大家", "旁白"];

    function isQuote(char) {
        return char in QUOTE_PAIRS || char === '"' || char === '\'';
    }

    function findDialogueRanges(text) {
        var ranges = [];
        var stack = [];

        for (var i = 0; i < text.length; i++) {
            var ch = text[i];

            if (isQuote(ch)) {
                var top = stack[stack.length - 1];
                if (top && QUOTE_PAIRS[top.char] === ch) {
                    stack.pop();
                    if (i > top.pos + 1) {
                        ranges.push({ start: top.pos, end: i + 1 });
                    }
                } else if (QUOTE_PAIRS[ch]) {
                    stack.push({ char: ch, pos: i });
                }
            }
        }

        // Also detect dash-style dialogue (—— "text")
        var dashPattern = /——\s*/g;
        var match;
        while ((match = dashPattern.exec(text)) !== null) {
            var start = match.index + match[0].length;
            var end = text.indexOf('\n', start);
            if (end < 0) end = text.length;
            if (end > start) {
                ranges.push({ start: match.index, end: end });
            }
        }

        return ranges.sort(function (a, b) { return a.start - b.start; });
    }

    function inferSpeaker(text, start) {
        // Look backwards for speaker pattern
        var before = text.substring(Math.max(0, start - 30), start);
        var match = SPEAKER_PATTERN.exec(before);
        if (match && INVALID_SPEAKERS.indexOf(match[1]) < 0) {
            return match[1];
        }
        return null;
    }

    MoRead.log("Custom segmenter module initializing...");

    MoRead.hook("dialogue.segment", function (p) {
        var text = p.text || "";
        if (!text || text.length < 10) return null;

        var dialogueRanges = findDialogueRanges(text);
        if (dialogueRanges.length === 0) return null;

        var segments = [];
        var cursor = 0;
        var recentSpeaker = null;

        for (var i = 0; i < dialogueRanges.length; i++) {
            var range = dialogueRanges[i];

            // Add narration before this dialogue
            if (range.start > cursor) {
                segments.push({
                    start: cursor,
                    end: range.start,
                    role: "旁白",
                    kind: "NARRATION",
                    confidence: 0.95
                });
            }

            // Try to infer speaker
            var speaker = inferSpeaker(text, range.start);
            if (!speaker && recentSpeaker) {
                speaker = recentSpeaker;
            }
            if (speaker) recentSpeaker = speaker;

            segments.push({
                start: range.start,
                end: range.end,
                role: speaker || "对白",
                kind: "DIALOGUE",
                confidence: speaker ? 0.85 : 0.4
            });

            cursor = range.end;
        }

        // Add trailing narration
        if (cursor < text.length) {
            segments.push({
                start: cursor,
                end: text.length,
                role: "旁白",
                kind: "NARRATION",
                confidence: 0.95
            });
        }

        MoRead.log("Segmented: " + segments.length + " segments from " + dialogueRanges.length + " dialogues");
        return JSON.stringify(segments);
    });

    MoRead.log("Custom segmenter module loaded and hooked dialogue.segment ✓");
})();
