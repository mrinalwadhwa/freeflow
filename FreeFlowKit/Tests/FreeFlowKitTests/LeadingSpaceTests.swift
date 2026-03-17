import Foundation
import Testing

@testable import FreeFlowKit

@Suite("Smart leading space")
struct LeadingSpaceTests {

    private let injector = AppTextInjector()

    // MARK: - Space Added After Regular Characters

    @Test("Add space after a letter")
    func spaceAfterLetter() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "world",
            fieldContent: "hello",
            cursorPosition: 5
        )
        #expect(result == " world")
    }

    @Test("Add space after a digit")
    func spaceAfterDigit() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "items",
            fieldContent: "42",
            cursorPosition: 2
        )
        #expect(result == " items")
    }

    @Test("Add space after a period")
    func spaceAfterPeriod() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "Next sentence",
            fieldContent: "Done.",
            cursorPosition: 5
        )
        #expect(result == " Next sentence")
    }

    @Test("Add space after a comma")
    func spaceAfterComma() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "then",
            fieldContent: "first,",
            cursorPosition: 6
        )
        #expect(result == " then")
    }

    @Test("Add space after a closing parenthesis")
    func spaceAfterCloseParen() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "next",
            fieldContent: "(done)",
            cursorPosition: 6
        )
        #expect(result == " next")
    }

    // MARK: - No Space After Whitespace

    @Test("No space after existing space")
    func noSpaceAfterSpace() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "world",
            fieldContent: "hello ",
            cursorPosition: 6
        )
        #expect(result == "world")
    }

    @Test("No space after tab")
    func noSpaceAfterTab() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "indented",
            fieldContent: "\t",
            cursorPosition: 1
        )
        #expect(result == "indented")
    }

    @Test("No space after newline")
    func noSpaceAfterNewline() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "next line",
            fieldContent: "first line\n",
            cursorPosition: 11
        )
        #expect(result == "next line")
    }

    @Test("No space after carriage return")
    func noSpaceAfterCR() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "text",
            fieldContent: "line\r",
            cursorPosition: 5
        )
        #expect(result == "text")
    }

    // MARK: - No Space After Opening Brackets

    @Test("No space after opening parenthesis")
    func noSpaceAfterOpenParen() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "content",
            fieldContent: "(",
            cursorPosition: 1
        )
        #expect(result == "content")
    }

    @Test("No space after opening square bracket")
    func noSpaceAfterOpenBracket() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "item",
            fieldContent: "[",
            cursorPosition: 1
        )
        #expect(result == "item")
    }

    @Test("No space after opening curly brace")
    func noSpaceAfterOpenBrace() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "key",
            fieldContent: "{",
            cursorPosition: 1
        )
        #expect(result == "key")
    }

    @Test("No space after opening angle bracket")
    func noSpaceAfterOpenAngle() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "tag",
            fieldContent: "<",
            cursorPosition: 1
        )
        #expect(result == "tag")
    }

    // MARK: - No Space After Quotes

    @Test("No space after double quote")
    func noSpaceAfterDoubleQuote() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "quoted",
            fieldContent: "\"",
            cursorPosition: 1
        )
        #expect(result == "quoted")
    }

    @Test("No space after single quote")
    func noSpaceAfterSingleQuote() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "quoted",
            fieldContent: "'",
            cursorPosition: 1
        )
        #expect(result == "quoted")
    }

    @Test("No space after backtick")
    func noSpaceAfterBacktick() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "code",
            fieldContent: "`",
            cursorPosition: 1
        )
        #expect(result == "code")
    }

    // MARK: - No Space After Path Separators

    @Test("No space after forward slash")
    func noSpaceAfterForwardSlash() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "path",
            fieldContent: "/",
            cursorPosition: 1
        )
        #expect(result == "path")
    }

    @Test("No space after backslash")
    func noSpaceAfterBackslash() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "path",
            fieldContent: "\\",
            cursorPosition: 1
        )
        #expect(result == "path")
    }

    // MARK: - Cursor at Start of Field

    @Test("No space when cursor is at position 0")
    func noSpaceAtStart() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "hello",
            fieldContent: "existing text",
            cursorPosition: 0
        )
        #expect(result == "hello")
    }

    // MARK: - Empty or Nil Field Content

    @Test("No space when field content is nil")
    func noSpaceWhenContentNil() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "hello",
            fieldContent: nil,
            cursorPosition: 5
        )
        #expect(result == "hello")
    }

    @Test("No space when cursor position is nil")
    func noSpaceWhenPositionNil() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "hello",
            fieldContent: "some text",
            cursorPosition: nil
        )
        #expect(result == "hello")
    }

    @Test("No space when both content and position are nil")
    func noSpaceWhenBothNil() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "hello",
            fieldContent: nil,
            cursorPosition: nil
        )
        #expect(result == "hello")
    }

    @Test("No space for empty field content at position 0")
    func noSpaceEmptyFieldAtZero() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "hello",
            fieldContent: "",
            cursorPosition: 0
        )
        #expect(result == "hello")
    }

    // MARK: - Text Already Has Leading Space

    @Test("No extra space when text already starts with space")
    func noDoubleSpace() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: " world",
            fieldContent: "hello",
            cursorPosition: 5
        )
        #expect(result == " world")
    }

    // MARK: - Cursor in Middle of Content

    @Test("Add space when cursor is mid-word")
    func spaceWhenCursorMidContent() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "injected",
            fieldContent: "helloworld",
            cursorPosition: 5
        )
        #expect(result == " injected")
    }

    @Test("No space when cursor follows a space in the middle")
    func noSpaceAfterMidSpace() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "injected",
            fieldContent: "hello world",
            cursorPosition: 6
        )
        #expect(result == "injected")
    }

    // MARK: - Cursor Position Out of Bounds

    @Test("No space when cursor position exceeds content length")
    func noSpaceWhenPositionExceedsLength() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "hello",
            fieldContent: "ab",
            cursorPosition: 100
        )
        #expect(result == "hello")
    }

    @Test("Add space with UTF-16 cursor offset after emoji")
    func spaceAfterEmojiWithUTF16CursorOffset() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "world",
            fieldContent: "🙂",
            cursorPosition: 2
        )
        #expect(result == " world")
    }

    // MARK: - Injected Text Starts with Punctuation

    @Test("No space when injected text starts with a period")
    func noSpaceBeforePeriod() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: ".",
            fieldContent: "Hello",
            cursorPosition: 5
        )
        #expect(result == ".")
    }

    @Test("No space when injected text starts with a comma")
    func noSpaceBeforeComma() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: ", world",
            fieldContent: "Hello",
            cursorPosition: 5
        )
        #expect(result == ", world")
    }

    @Test("No space when injected text starts with a question mark")
    func noSpaceBeforeQuestionMark() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "?",
            fieldContent: "Really",
            cursorPosition: 6
        )
        #expect(result == "?")
    }

    @Test("No space when injected text starts with an exclamation mark")
    func noSpaceBeforeExclamation() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "!",
            fieldContent: "Wow",
            cursorPosition: 3
        )
        #expect(result == "!")
    }

    @Test("No space when injected text starts with a semicolon")
    func noSpaceBeforeSemicolon() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "; next",
            fieldContent: "first",
            cursorPosition: 5
        )
        #expect(result == "; next")
    }

    @Test("No space when injected text starts with a colon")
    func noSpaceBeforeColon() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: ": value",
            fieldContent: "key",
            cursorPosition: 3
        )
        #expect(result == ": value")
    }

    // MARK: - Injected Text Starts with Newline

    @Test("No space when injected text starts with a newline")
    func noSpaceBeforeNewline() {
        let result = injector.addLeadingSpaceIfNeeded(
            text: "\nworld",
            fieldContent: "Hello",
            cursorPosition: 5
        )
        #expect(result == "\nworld")
    }
}
