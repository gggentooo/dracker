/**
 * File:         source/compose/script/lexer.d
 * Module:       compose.script.lexer
 * Phase:        Composition helper (dracker-compose) — T83 (Script language lexer)
 *
 * Purpose:
 *   Tokenizes composition scripts per decision T67: one command per line, double-slash comments outside
 *   quotes (leaving '#' free for sharp notes and keys such as C#4 and F# minor), trailing backslash line
 *   continuation across physical lines, double-quoted strings with standard escapes, and name=value /
 *   name="value" options. Every token and lex error carries its exact 1-based physical line, column, and
 *   byte length. Never prints or performs I/O.
 *
 * Real-Time & Safety Contract:
 *   Off-RT. Pure @safe nothrow lexer with no global state and no exceptions.
 *
 * Dependencies:
 *   Internal: none
 *   External: none
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum TokenKind; struct Token; struct CommandLine
 *   - enum LexErrorKind; struct LexError; struct LexResult
 *   - lexLine(), lexScript()
 *
 * See_Also:
 *   docs/todo.md (T67, T83), source/compose/script/interpreter.d
 */
module compose.script.lexer;

/** The lexical category of a single token on a command line. */
enum TokenKind : ubyte {
    word = 0,
    quoted = 1,
    option = 2
}

/**
 * One token produced by the script lexer, with 1-based physical source coordinates.
 */
struct Token {
    TokenKind kind = TokenKind.word;
    string text = "";
    string optionName = "";
    string optionValue = "";
    bool valueQuoted = false;
    uint line = 1;
    uint column = 1;
    uint length = 1;
}

/**
 * One logical command (possibly spanning multiple physical lines joined by trailing '\').
 */
struct CommandLine {
    uint line = 1;
    Token[] tokens;
}

/** Diagnostic categories for lexer errors. */
enum LexErrorKind : ubyte {
    none = 0,
    unterminatedString = 1,
    invalidEscape = 2,
    malformedOption = 3,
    missingOptionValue = 4,
    unexpectedAfterQuote = 5
}

/**
 * A lexical error with exact 1-based line, column and span length.
 */
struct LexError {
    LexErrorKind kind = LexErrorKind.none;
    uint line = 1;
    uint column = 1;
    uint length = 1;
    string reason = "";
}

/**
 * Output of lexing a script or single line.
 */
struct LexResult {
    CommandLine[] commands;
    LexError[] errors;

    /**
     * Reports whether lexing finished with zero errors.
     *
     * Returns:
     *   True when errors is empty.
     */
    bool ok() const @safe pure nothrow @nogc {
        return errors.length == 0;
    }
}

/**
 * Reports whether a byte is horizontal whitespace (space or tab).
 *
 * Params:
 *   c = Byte to test.
 *
 * Returns:
 *   True for space or tab.
 */
private bool isSpace(char c) @safe pure nothrow @nogc {
    return c == ' ' || c == '\t';
}

/**
 * Reports whether a byte is an ASCII letter.
 *
 * Params:
 *   c = Byte to test.
 *
 * Returns:
 *   True for A-Z or a-z.
 */
private bool isAsciiLetter(char c) @safe pure nothrow @nogc {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
}

/**
 * Reports whether a string is a valid option name: starts with an ASCII letter and contains only
 * ASCII letters, digits, '_' and '-'.
 *
 * Params:
 *   name = Candidate option name.
 *
 * Returns:
 *   True when valid.
 */
private bool isValidOptionName(string name) @safe pure nothrow @nogc {
    if (name.length == 0 || !isAsciiLetter(name[0])) {
        return false;
    }
    foreach (c; name) {
        immutable bool ok = isAsciiLetter(c) || (c >= '0' && c <= '9') || c == '_' || c == '-';
        if (!ok) {
            return false;
        }
    }
    return true;
}

/**
 * Reports whether position idx starts a double-slash comment.
 *
 * Params:
 *   line = Physical line text without line terminator.
 *   idx = Byte offset in line.
 *
 * Returns:
 *   True when line[idx] and line[idx + 1] are both '/'.
 */
private bool isCommentStart(string line, size_t idx) @safe pure nothrow @nogc {
    return idx + 1 < line.length && line[idx] == '/' && line[idx + 1] == '/';
}

/**
 * Reports whether a backslash at idx is a line continuation (only spaces or tabs follow it to EOL).
 *
 * Params:
 *   line = Physical line text without line terminator.
 *   idx = Byte offset of the backslash.
 *
 * Returns:
 *   True when line[idx] == '\\' and only horizontal whitespace follows it.
 */
private bool isLineContinuation(string line, size_t idx) @safe pure nothrow @nogc {
    if (idx >= line.length || line[idx] != '\\') {
        return false;
    }
    foreach (j; idx + 1 .. line.length) {
        if (!isSpace(line[j])) {
            return false;
        }
    }
    return true;
}

/**
 * Scans a double-quoted string starting at the opening '"' at cursor.
 *
 * Params:
 *   line = Physical line text.
 *   lineNumber = 1-based physical line number.
 *   cursor = In/out byte offset; enters on '"' and leaves one byte past closing '"' (or EOL on error).
 *   value = Receives the unescaped string content.
 *   errors = Appends any LexError encountered.
 *
 * Returns:
 *   True when a valid, terminated quoted string was scanned.
 */
private bool scanQuoted(string line, uint lineNumber, ref size_t cursor, out string value,
        ref LexError[] errors) @safe pure nothrow {
    immutable size_t start = cursor;
    cursor++;
    char[] buf;
    bool hadEscapeError = false;
    while (cursor < line.length) {
        immutable char c = line[cursor];
        if (c == '"') {
            cursor++;
            value = buf.idup;
            return !hadEscapeError;
        }
        if (c == '\\') {
            if (cursor + 1 >= line.length) {
                errors ~= LexError(LexErrorKind.unterminatedString, lineNumber, cast(uint)(start + 1),
                    cast(uint)(line.length - start), "unterminated quoted string");
                cursor = line.length;
                return false;
            }
            immutable char next = line[cursor + 1];
            if (next == '"') {
                buf ~= '"';
            } else if (next == '\\') {
                buf ~= '\\';
            } else if (next == 'n') {
                buf ~= '\n';
            } else if (next == 't') {
                buf ~= '\t';
            } else {
                hadEscapeError = true;
                errors ~= LexError(LexErrorKind.invalidEscape, lineNumber, cast(uint)(cursor + 1), 2,
                    "unknown escape sequence in quoted string");
            }
            cursor += 2;
            continue;
        }
        buf ~= c;
        cursor++;
    }
    errors ~= LexError(LexErrorKind.unterminatedString, lineNumber, cast(uint)(start + 1),
        cast(uint)(line.length - start), "unterminated quoted string");
    return false;
}

/**
 * Lexes one physical line, appending tokens to currentTokens and reporting whether the line ends
 * with a continuation backslash.
 *
 * Params:
 *   line = Physical line text without line terminator.
 *   lineNumber = 1-based physical line number.
 *   currentTokens = In/out token buffer for the active logical command.
 *   commandStartLine = In/out 1-based start line of the active logical command.
 *   errors = Appends any LexError encountered.
 *
 * Returns:
 *   True when the physical line ends with a valid line continuation backslash.
 */
private bool lexPhysicalLine(string line, uint lineNumber, ref Token[] currentTokens,
        ref uint commandStartLine, ref LexError[] errors) @safe pure nothrow {
    size_t i = 0;
    while (i < line.length) {
        while (i < line.length && isSpace(line[i])) {
            i++;
        }
        if (i >= line.length) {
            return false;
        }
        if (isCommentStart(line, i)) {
            return false;
        }
        if (isLineContinuation(line, i)) {
            return true;
        }

        if (currentTokens.length == 0) {
            commandStartLine = lineNumber;
        }

        immutable size_t tokStart = i;
        if (line[i] == '"') {
            string textVal;
            immutable bool ok = scanQuoted(line, lineNumber, i, textVal, errors);
            if (!ok) {
                return false;
            }
            if (i < line.length && !isSpace(line[i]) && !isCommentStart(line, i) && !isLineContinuation(line, i)) {
                immutable size_t badStart = i;
                while (i < line.length && !isSpace(line[i]) && !isCommentStart(line, i)) {
                    i++;
                }
                errors ~= LexError(LexErrorKind.unexpectedAfterQuote, lineNumber, cast(uint)(badStart + 1),
                    cast(uint)(i - badStart), "unexpected characters immediately after closing quote");
                continue;
            }
            currentTokens ~= Token(TokenKind.quoted, textVal, "", "", false, lineNumber,
                cast(uint)(tokStart + 1), cast(uint)(i - tokStart));
            continue;
        }

        size_t eqPos = size_t.max;
        while (i < line.length && !isSpace(line[i]) && !isCommentStart(line, i) && !isLineContinuation(line, i)) {
            if (line[i] == '=') {
                eqPos = i;
                break;
            }
            if (line[i] == '"') {
                break;
            }
            i++;
        }

        if (eqPos != size_t.max) {
            immutable string optName = line[tokStart .. eqPos];
            i = eqPos + 1;
            if (!isValidOptionName(optName)) {
                while (i < line.length && !isSpace(line[i]) && !isCommentStart(line, i)) {
                    i++;
                }
                errors ~= LexError(LexErrorKind.malformedOption, lineNumber, cast(uint)(tokStart + 1),
                    cast(uint)(i - tokStart),
                    optName.length == 0 ? "option name before '=' cannot be empty"
                        : "invalid option name '" ~ optName ~ "'");
                continue;
            }
            if (i >= line.length || isSpace(line[i]) || isCommentStart(line, i) || isLineContinuation(line, i)) {
                errors ~= LexError(LexErrorKind.missingOptionValue, lineNumber, cast(uint)(eqPos + 1), 1,
                    "option '" ~ optName ~ "' is missing a value after '='");
                continue;
            }
            if (line[i] == '"') {
                string optVal;
                immutable bool ok = scanQuoted(line, lineNumber, i, optVal, errors);
                if (!ok) {
                    return false;
                }
                if (i < line.length && !isSpace(line[i]) && !isCommentStart(line, i) && !isLineContinuation(line, i)) {
                    immutable size_t badStart = i;
                    while (i < line.length && !isSpace(line[i]) && !isCommentStart(line, i)) {
                        i++;
                    }
                    errors ~= LexError(LexErrorKind.unexpectedAfterQuote, lineNumber, cast(uint)(badStart + 1),
                        cast(uint)(i - badStart), "unexpected characters immediately after closing quote");
                    continue;
                }
                currentTokens ~= Token(TokenKind.option, optName ~ "=" ~ optVal, optName, optVal, true,
                    lineNumber, cast(uint)(tokStart + 1), cast(uint)(i - tokStart));
            } else {
                immutable size_t valStart = i;
                while (i < line.length && !isSpace(line[i]) && !isCommentStart(line, i)
                        && !isLineContinuation(line, i)) {
                    i++;
                }
                immutable string optVal = line[valStart .. i];
                currentTokens ~= Token(TokenKind.option, optName ~ "=" ~ optVal, optName, optVal, false,
                    lineNumber, cast(uint)(tokStart + 1), cast(uint)(i - tokStart));
            }
            continue;
        }

        if (i < line.length && line[i] == '"') {
            while (i < line.length && !isSpace(line[i]) && !isCommentStart(line, i)) {
                i++;
            }
            errors ~= LexError(LexErrorKind.unexpectedAfterQuote, lineNumber, cast(uint)(tokStart + 1),
                cast(uint)(i - tokStart), "unexpected quote inside unquoted word");
            continue;
        }

        immutable string wordText = line[tokStart .. i];
        currentTokens ~= Token(TokenKind.word, wordText, "", "", false, lineNumber,
            cast(uint)(tokStart + 1), cast(uint)(i - tokStart));
    }
    return false;
}

/**
 * Lexes a single line of script text (with optional 1-based line number for diagnostics).
 *
 * Params:
 *   lineText = Single line of script text (trailing CR/LF stripped if present).
 *   lineNumber = 1-based line number reported on tokens and errors.
 *
 * Returns:
 *   LexResult with zero or one CommandLine and any LexError values.
 */
LexResult lexLine(string lineText, uint lineNumber = 1) @safe pure nothrow {
    string clean = lineText;
    if (clean.length > 0 && clean[$ - 1] == '\n') {
        clean = clean[0 .. $ - 1];
    }
    if (clean.length > 0 && clean[$ - 1] == '\r') {
        clean = clean[0 .. $ - 1];
    }
    LexResult result;
    Token[] tokens;
    uint startLine = lineNumber;
    cast(void) lexPhysicalLine(clean, lineNumber, tokens, startLine, result.errors);
    if (tokens.length > 0) {
        result.commands ~= CommandLine(startLine, tokens);
    }
    return result;
}

/**
 * Lexes a complete multi-line composition script into logical commands.
 *
 * Handles LF, CRLF, and CR line endings, ignores blank and comment-only lines, and joins
 * physical lines ending with a continuation backslash into one CommandLine.
 *
 * Params:
 *   source = Script source text.
 *
 * Returns:
 *   LexResult containing all parsed CommandLines and any LexErrors.
 */
LexResult lexScript(string source) @safe pure nothrow {
    LexResult result;
    Token[] activeTokens;
    uint activeStartLine = 1;
    uint lineNumber = 1;
    size_t pos = 0;

    while (pos <= source.length) {
        immutable size_t lineStart = pos;
        while (pos < source.length && source[pos] != '\n' && source[pos] != '\r') {
            pos++;
        }
        immutable string physical = source[lineStart .. pos];
        immutable bool atEnd = pos >= source.length;
        if (pos < source.length) {
            if (source[pos] == '\r' && pos + 1 < source.length && source[pos + 1] == '\n') {
                pos += 2;
            } else {
                pos++;
            }
        }

        immutable bool continued = lexPhysicalLine(physical, lineNumber, activeTokens, activeStartLine,
            result.errors);
        if (!continued && activeTokens.length > 0) {
            result.commands ~= CommandLine(activeStartLine, activeTokens);
            activeTokens = null;
        }

        if (atEnd) {
            break;
        }
        lineNumber++;
    }

    if (activeTokens.length > 0) {
        result.commands ~= CommandLine(activeStartLine, activeTokens);
    }
    return result;
}
