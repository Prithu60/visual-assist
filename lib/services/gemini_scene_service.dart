import 'dart:typed_data';

import 'package:google_generative_ai/google_generative_ai.dart';

import 'api_keys_service.dart';

/// Wraps Gemini 2.5 Flash for blind-friendly scene description.
///
/// Hybrid edge-cloud design: the on-device pipeline (YOLO + MiDaS +
/// DeepLab) computes structured measurements — object identity,
/// distance in metres, depth-zone hazards. We pass those measurements
/// to Gemini alongside the photo. Gemini then has both the visual
/// scene AND the measured numbers, so it can ground its description
/// in real measurements rather than guessing.
///
/// What this version handles that earlier ones didn't:
///
///   1. Higher token cap (400 vs 220). The previous cap was tight
///      enough that any wordy frame got truncated mid-sentence and
///      TTS spoke half a thought.
///
///   2. MAX_TOKENS detection + retry. If the response was cut off
///      because it hit the cap, we retry once with a stricter "be
///      very brief" reminder.
///
///   3. Sentence-boundary guard. Even after retry, if the final
///      response ends without proper sentence-ending punctuation we
///      trim back to the last complete sentence.
///
///   4. Optional structured facts. The caller can pass a [facts]
///      string containing on-device measurements; Gemini is
///      instructed to use those numbers instead of guessing.
class GeminiSceneService {
  GenerativeModel? _model;
  GenerativeModel? _shorterModel;
  String? _loadedKey;

  bool get isReady => _model != null;

  /// Initialise (or re-initialise if the key changed). Throws if no key set.
  Future<void> initialize() async {
    final key = await ApiKeysService.readGeminiKey();

    if (key.isEmpty) {
      _model = null;
      _shorterModel = null;
      _loadedKey = null;
      throw StateError(
        'Gemini API key is not configured. Open settings to add one.',
      );
    }

    if (key == _loadedKey && _model != null) return;

    final speakingRules = 'You are describing a scene for a blind user '
        'who has just taken a photo with their phone. Your reply will '
        'be read aloud through text-to-speech, so:\n'
        '\n'
        '  - Speak in 2 to 4 short, plain sentences. No bullet points, '
        'no headings, no markdown.\n'
        '  - Lead with anything dangerous (traffic, stairs, drop-offs, '
        'fire, broken glass, large obstacles) or with people present '
        'and what they are doing.\n'
        '  - Then say what kind of place it looks like (kitchen, '
        'sidewalk, office, park, bus stop).\n'
        '  - When the user provides MEASURED FACTS below the prompt, '
        'use those exact numbers in your description. For example, if '
        'the facts say "person at 2.1 metres ahead", say "a person '
        'about two metres ahead". Round to one decimal place or '
        'whole metres for short distances; never invent your own '
        'measurements when measured facts are provided.\n'
        '  - For objects NOT in the measured facts, use qualitative '
        'distance words like "close", "across the room", "far away" — '
        'do NOT invent specific metres for them.\n'
        '  - Use direction words like "ahead", "to your right", "to '
        'your left", "behind a person ahead".\n'
        '  - Skip colour unless it carries safety meaning (red light, '
        'yellow tape) or is needed to identify a specific person '
        '("the man in the red jacket").\n'
        '  - Speak directly to the user. Never start with "the image '
        'shows" or "I can see".\n'
        '  - If the photo is dark, blurry, or pointed at the floor, '
        'say so briefly so the user can take another shot.\n'
        '  - Always finish your last sentence. Never stop mid-thought.';

    _model = GenerativeModel(
      model: 'gemini-2.5-flash',
      apiKey: key,
      generationConfig: GenerationConfig(
        temperature: 0.4,
        // 400 tokens is roughly 280-320 English words. Comfortably
        // covers 4 sentences even when Gemini is verbose, without
        // letting the response balloon into a paragraph.
        maxOutputTokens: 400,
      ),
      systemInstruction: Content.text(speakingRules),
    );

    // Backup model used for the retry path. Same speaking rules but
    // with an extra "BE EXTREMELY BRIEF" reminder, lower temperature
    // for tighter output, and slightly more headroom on tokens.
    _shorterModel = GenerativeModel(
      model: 'gemini-2.5-flash',
      apiKey: key,
      generationConfig: GenerationConfig(
        temperature: 0.2,
        maxOutputTokens: 480,
      ),
      systemInstruction: Content.text(
        '$speakingRules\n\nBE EXTREMELY BRIEF. Use 2 short sentences '
        'only. Skip details. Finish every sentence.',
      ),
    );

    _loadedKey = key;
  }

  /// Returns a 2–4 sentence scene description, or throws on failure.
  ///
  /// [jpegBytes] is the JPEG encoded camera frame.
  ///
  /// [userQuestion] is optional — if the user asked something specific
  /// ("is the door open?") it gets passed alongside the image.
  ///
  /// [facts] is optional structured measurement context produced by
  /// the on-device pipeline. When supplied, Gemini is instructed to
  /// use these numbers instead of guessing distances. Example:
  ///
  ///   "Measured facts from on-device sensors:\n"
  ///   "- person at 2.1 metres, ahead\n"
  ///   "- chair at 1.5 metres, on the left\n"
  ///   "- depth: close obstacle on the left\n"
  Future<String> describe(
    Uint8List jpegBytes, {
    String? userQuestion,
    String? facts,
  }) async {
    if (_model == null) await initialize();
    final model = _model!;

    final question = userQuestion?.trim() ?? '';
    final factsBlock = (facts != null && facts.trim().isNotEmpty)
        ? '\n\n$facts'
        : '';

    final promptText = question.isNotEmpty
        ? 'The user asked: "$question". Look at the photo and answer '
            'briefly, following your speaking rules.$factsBlock'
        : 'Describe the scene briefly, following your speaking '
            'rules.$factsBlock';

    final response = await model.generateContent([
      Content.multi([
        TextPart(promptText),
        DataPart('image/jpeg', jpegBytes),
      ]),
    ]).timeout(const Duration(seconds: 25));

    var text = response.text?.trim() ?? '';

    // Detect "this got cut off because we hit the token cap." Gemini
    // exposes this via the candidate's finishReason. If we can prove
    // the response was truncated, retry once with the brief-mode
    // model.
    if (_wasTruncated(response, text)) {
      // ignore: avoid_print
      print('[GeminiSceneService] response truncated, retrying brief...');

      final retry = await (_shorterModel ?? model).generateContent([
        Content.multi([
          TextPart(
            'Describe the scene in TWO short sentences only. Finish '
            'each sentence. $promptText',
          ),
          DataPart('image/jpeg', jpegBytes),
        ]),
      ]).timeout(const Duration(seconds: 25));

      final retryText = retry.text?.trim();
      if (retryText != null && retryText.isNotEmpty) {
        text = retryText;
      }
      // If retry also failed, we fall through to trimming the
      // original — better truncated-but-clean than empty.
    }

    if (text.isEmpty) {
      throw StateError('Gemini returned an empty response.');
    }

    // Final guard: even if Gemini didn't flag truncation, the response
    // might still end mid-sentence. Trim to the last full sentence so
    // TTS never reads a fragment aloud.
    final cleaned = _trimToLastCompleteSentence(text);
    if (cleaned.isEmpty) {
      // Pathological — model returned text with no sentence
      // terminators at all. Speak it as-is rather than show nothing.
      return text;
    }
    return cleaned;
  }

  /// Returns true if the response looks truncated. Two signals:
  ///   * candidate.finishReason == 'maxTokens' (most reliable)
  ///   * text doesn't end in sentence-final punctuation (heuristic)
  bool _wasTruncated(GenerateContentResponse response, String text) {
    try {
      final candidates = response.candidates;
      if (candidates.isNotEmpty) {
        final reason = candidates.first.finishReason;
        if (reason == FinishReason.maxTokens) return true;
      }
    } catch (_) {
      // Older SDK versions may not expose this — fall through to the
      // text heuristic.
    }
    if (text.isEmpty) return false;
    final last = text[text.length - 1];
    return !(last == '.' || last == '!' || last == '?');
  }

  /// Trim to the last complete sentence-ending punctuation.
  /// "She walked into the room. He was waiting for her" → "She walked
  /// into the room." (drops the dangling tail).
  /// Returns '' if no sentence-final punctuation found at all.
  static String _trimToLastCompleteSentence(String text) {
    var lastEnd = -1;
    for (var i = text.length - 1; i >= 0; i--) {
      final ch = text[i];
      if (ch == '.' || ch == '!' || ch == '?') {
        lastEnd = i;
        break;
      }
    }
    if (lastEnd < 0) return '';
    return text.substring(0, lastEnd + 1).trim();
  }
}