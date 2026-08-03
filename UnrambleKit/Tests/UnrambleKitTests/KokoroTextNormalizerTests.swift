import Foundation
import Testing

@testable import UnrambleKit

@Suite("Kokoro text normalizer")
struct KokoroTextNormalizerTests {

    @Test("Hyphenated compounds split into their words")
    func hyphenatedCompoundsSplit() {
        #expect(
            KokoroTextNormalizer.normalize(
                "The read-aloud voice uses focused-pane matching.")
                == "The read aloud voice uses focused pane matching.")
    }

    @Test("Number ranges split and spell out")
    func numberRangesSpell() {
        #expect(
            KokoroTextNormalizer.normalize("Rows 5-10 changed.")
                == "Rows five ten changed.")
    }

    @Test("Dashes become comma pauses")
    func dashesBecomePauses() {
        #expect(
            KokoroTextNormalizer.normalize("One thing — the tests pass.")
                == "One thing, the tests pass.")
        #expect(
            KokoroTextNormalizer.normalize("A – B")
                == "A, B")
    }

    @Test("Leading and trailing hyphens stay untouched")
    func bareHyphensStay() {
        #expect(
            KokoroTextNormalizer.normalize("Use the - flag, or -v.")
                == "Use the - flag, or -v.")
    }

    @Test("Plain text passes through unchanged")
    func plainTextUnchanged() {
        #expect(
            KokoroTextNormalizer.normalize("Nothing to change here.")
                == "Nothing to change here.")
    }

    @Test("Keyboard glyphs read as modifier names")
    func keyboardGlyphsReadAsNames() {
        #expect(
            KokoroTextNormalizer.normalize("Press ⌃⇧R to read aloud.")
                == "Press control shift R to read aloud.")
    }

    @Test("Multipliers after numbers read as times")
    func multipliersReadAsTimes() {
        #expect(
            KokoroTextNormalizer.normalize("The voice speaks at 1.1x now.")
                == "The voice speaks at one point one times now.")
        #expect(
            KokoroTextNormalizer.normalize("Warm generation runs 35× realtime.")
                == "Warm generation runs thirty five times real time.")
        #expect(
            KokoroTextNormalizer.normalize("Speed is now 1.2×.")
                == "Speed is now one point two times.")
    }

    @Test("Decimals speak their point instead of vanishing")
    func decimalsSpeakThePoint() {
        #expect(
            KokoroTextNormalizer.normalize("Version 0.3.1 shipped.")
                == "Version zero point three point one shipped.")
        #expect(
            KokoroTextNormalizer.normalize("It took 2.5 seconds.")
                == "It took two point five seconds.")
    }

    @Test("Dimensions between numbers read as by")
    func dimensionsReadAsBy() {
        #expect(
            KokoroTextNormalizer.normalize("A 1920×1080 screen.")
                == "A nineteen twenty by one thousand eighty screen.")
        #expect(
            KokoroTextNormalizer.normalize("A 1920x1080 screen.")
                == "A nineteen twenty by one thousand eighty screen.")
        #expect(
            KokoroTextNormalizer.normalize("A 3x5 card.")
                == "A three by five card.")
    }

    @Test("Hex literals spell per character")
    func hexLiteralsSpell() {
        #expect(
            KokoroTextNormalizer.normalize("Flag 0x1F is set.")
                == "Flag zero x one F is set.")
    }

    @Test("Missing compounds respell as their words")
    func compoundsRespell() {
        #expect(
            KokoroTextNormalizer.normalize("It runs 35x realtime.")
                == "It runs thirty five times real time.")
    }

    @Test("Years read as date pairs")
    func yearsReadAsDatePairs() {
        #expect(
            KokoroTextNormalizer.normalize("Signed on July 27, 2026.")
                == "Signed on July twenty seven, twenty twenty six.")
        #expect(
            KokoroTextNormalizer.normalize("Back in 1984 and 2005.")
                == "Back in nineteen eighty four and two thousand five.")
    }

    @Test("Counts spell as cardinals")
    func countsSpellAsCardinals() {
        #expect(
            KokoroTextNormalizer.normalize("It moved 1,432 files.")
                == "It moved one thousand four hundred thirty two files.")
        #expect(
            KokoroTextNormalizer.normalize("All 27 tests pass.")
                == "All twenty seven tests pass.")
    }

    @Test("Ordinals keep their suffix reading")
    func ordinalsKeepReading() {
        #expect(
            KokoroTextNormalizer.normalize("The 27th try on the 2nd.")
                == "The twenty seventh try on the second.")
    }

    @Test("Percentages read as percent")
    func percentagesReadAsPercent() {
        #expect(
            KokoroTextNormalizer.normalize("Coverage rose 27%.")
                == "Coverage rose twenty seven percent.")
    }

    @Test("Curly quotes become straight ones")
    func curlyQuotesBecomeStraight() {
        #expect(
            KokoroTextNormalizer.normalize("that\u{2019}s Fluent\u{2019}s plan")
                == "that's Fluent's plan")
    }

    @Test("Past-tense read pins the red sound after auxiliaries")
    func pastTenseReadPinsSound() {
        #expect(
            KokoroTextNormalizer.normalize("The file was read aloud.")
                == "The file was [read](/ɹˈɛd/) aloud.")
        #expect(
            KokoroTextNormalizer.normalize("They've read the docs.")
                == "They've [read](/ɹˈɛd/) the docs.")
        #expect(
            KokoroTextNormalizer.normalize("Press it to read aloud.")
                == "Press it to read aloud.")
    }

    @Test("Mixed identifiers spell character by character")
    func mixedIdentifiersSpell() {
        #expect(
            KokoroTextNormalizer.normalize("Commit 1db11e86 is ready.")
                == "Commit one d b one one e eight six is ready.")
    }

    @Test("Letters glued to numbers split apart")
    func gluedLettersSplit() {
        #expect(
            KokoroTextNormalizer.normalize("A 24kHz sample rate.")
                == "A twenty four kHz sample rate.")
    }

    @Test("Unspeakable symbols drop instead of garbling")
    func unspeakableSymbolsDrop() {
        #expect(
            KokoroTextNormalizer.normalize("Done ✅ ship it 🚀 now")
                == "Done ship it now")
        #expect(
            KokoroTextNormalizer.normalize("│ box ─ drawing ╰ art")
                == "box drawing art")
        #expect(
            KokoroTextNormalizer.normalize("Run `make test` first.")
                == "Run make test first.")
    }

    @Test("URLs read as their host")
    func urlsReadAsHost() {
        #expect(
            KokoroTextNormalizer.normalize(
                "See https://example.com/articles/how-i-built-a-factory/ today.")
                == "See example dot com today.")
        #expect(
            KokoroTextNormalizer.normalize(
                "Clone https://www.github.com/Blaizzy/mlx-audio-swift now.")
                == "Clone github dot com now.")
    }

    @Test("Mispronounced words carry phoneme overrides")
    func mispronouncedWordsCarryOverrides() {
        #expect(
            KokoroTextNormalizer.normalize("It was written by Mrinal Wadhwa.")
                == "It was [written](/ɹˈɪtᵊn/) by [Mrinal](/mɹinˈɑl/) [Wadhwa](/wˈɑdwɑ/).")
    }

    @Test("Arrows and bullets read as phrasing")
    func arrowsAndBulletsPhrase() {
        #expect(
            KokoroTextNormalizer.normalize("idle → speaking")
                == "idle to speaking")
        #expect(
            KokoroTextNormalizer.normalize("Steps: • build • sign")
                == "Steps:, build, sign")
    }
}
