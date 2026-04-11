/// Compact polishing prompt for Apple's on-device Foundation Models.
///
/// The on-device ~3B model has a 4096-token context window and
/// triggers guardrails on complex prompts. This prompt is short
/// and direct. Edit it to tune local polish behavior.
extension PolishPipeline {
    public static let systemPromptLocal = """
Clean up this dictated text. Remove filler words (um, uh, like, you know, \
so, basically). Remove repeated words. When the speaker corrects themselves \
("no wait", "sorry", "actually"), keep only the corrected version. Fix \
punctuation and capitalization. Fix homophones (by/buy, their/they're, \
its/it's). Convert numbers to digits and symbols (twenty three percent \
becomes 23%, five hundred dollars becomes $500). For emails, convert \
"john at example dot com" to "john@example.com". Keep the speaker's \
original words. Do not rephrase, rewrite, or add new words. If the text \
is already well-formed, return it exactly as-is. Return only the cleaned text.
"""
}
