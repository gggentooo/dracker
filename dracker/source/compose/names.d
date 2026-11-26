/**
 * File:         source/compose/names.d
 * Module:       compose.names
 * Phase:        Composition helper (dracker-compose) — T92 (shared name matching)
 *
 * Purpose:
 *   How the composition helper compares the names a script or a command line writes with the names it knows
 *   (module types, presets, parameters, option names, subcommands), and how it finds the nearest known name
 *   for a suggestion. Names are compared without regard to ASCII case or spaces ("op1 level" is "Op1 Level").
 *   The nearest name is the one with the smallest edit distance after that normalization, if it is at most half
 *   the length of the longer of the two names (rounded down) apart; a known name that starts with what was
 *   written counts as one step apart. One module holds these rules so every part of the helper suggests names
 *   the same way.
 *
 * Real-Time & Safety Contract:
 *   Off-RT. Every function is @safe pure nothrow; normalize(), editDistance() and the nearest-name search
 *   allocate on the GC heap.
 *
 * Dependencies:
 *   Internal: none
 *   External: none
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct NameMatch; nearestMatch(); nearestName()
 *   - namesMatch(); normalize(); editDistance(); hasPrefix(); trim(); isSpaceChar(); lowerAscii()
 *
 * See_Also:
 *   docs/todo.md (T66, T70, T92), source/compose/module_writer.d, source/compose_main.d
 */
module compose.names;

/**
 * The nearest candidate to a written name: its index (-1 when none is near enough) and its distance.
 */
struct NameMatch {
    ptrdiff_t index = -1;
    size_t distance = size_t.max;
}

/**
 * Finds the candidate nearest to a written name, comparing without regard to case or spaces.
 *
 * Params:
 *   text = The name as written.
 *   candidates = The known names.
 *
 * Returns:
 *   The index and distance of the nearest candidate; index -1 when none is at most half the length of the
 *   longer of the two (rounded down) apart. A candidate that starts with the text is one step apart; the first
 *   of equally near candidates wins.
 */
NameMatch nearestMatch(string text, scope const(string)[] candidates) @safe pure nothrow {
    NameMatch best;
    immutable string needle = normalize(text);
    if (needle.length == 0) {
        return best;
    }
    foreach (i, ref candidate; candidates) {
        immutable string hay = normalize(candidate);
        if (hay.length == 0) {
            continue;
        }
        immutable size_t longer = needle.length > hay.length ? needle.length : hay.length;
        immutable size_t distance = hay == needle ? 0 : (hasPrefix(hay, needle) ? 1 : editDistance(needle, hay));
        if (distance * 2 <= longer && distance < best.distance) {
            best = NameMatch(cast(ptrdiff_t) i, distance);
        }
    }
    return best;
}

/**
 * The known name nearest to a written one, for a "did you mean" suggestion.
 *
 * Params:
 *   text = The name as written.
 *   candidates = The known names.
 *
 * Returns:
 *   The nearest candidate as it is spelled in candidates, or "" when none is near enough.
 */
string nearestName(string text, scope const(string)[] candidates) @safe pure nothrow {
    immutable NameMatch best = nearestMatch(text, candidates);
    return best.index < 0 ? "" : candidates[cast(size_t) best.index];
}

/**
 * Reports whether two names are the same without regard to ASCII case or spaces.
 *
 * Params:
 *   a = One name.
 *   b = The other name.
 *
 * Returns:
 *   True when, without spaces and in lower case, both read the same.
 */
bool namesMatch(string a, string b) @safe pure nothrow @nogc {
    size_t i = 0;
    size_t j = 0;
    while (true) {
        while (i < a.length && isSpaceChar(a[i])) {
            i++;
        }
        while (j < b.length && isSpaceChar(b[j])) {
            j++;
        }
        if (i == a.length || j == b.length) {
            return i == a.length && j == b.length;
        }
        if (lowerAscii(a[i]) != lowerAscii(b[j])) {
            return false;
        }
        i++;
        j++;
    }
}

/**
 * Lowers a name and drops its spaces, the form in which names are compared.
 *
 * Params:
 *   text = The name.
 *
 * Returns:
 *   The normalized name.
 */
string normalize(string text) @safe pure nothrow {
    char[] buffer = new char[text.length];
    size_t count = 0;
    foreach (c; text) {
        if (!isSpaceChar(c)) {
            buffer[count] = lowerAscii(c);
            count++;
        }
    }
    return buffer[0 .. count].idup;
}

/**
 * The edit distance (Levenshtein) between two texts: the smallest number of single-byte insertions, deletions
 * and substitutions that turn one into the other.
 *
 * Params:
 *   a = One text.
 *   b = The other text.
 *
 * Returns:
 *   The distance.
 */
size_t editDistance(string a, string b) @safe pure nothrow {
    size_t[] previous = new size_t[b.length + 1];
    size_t[] current = new size_t[b.length + 1];
    foreach (j; 0 .. b.length + 1) {
        previous[j] = j;
    }
    foreach (i; 1 .. a.length + 1) {
        current[0] = i;
        foreach (j; 1 .. b.length + 1) {
            immutable size_t substitutionCost = a[i - 1] == b[j - 1] ? 0 : 1;
            size_t best = previous[j - 1] + substitutionCost;
            if (previous[j] + 1 < best) {
                best = previous[j] + 1;
            }
            if (current[j - 1] + 1 < best) {
                best = current[j - 1] + 1;
            }
            current[j] = best;
        }
        size_t[] swap = previous;
        previous = current;
        current = swap;
    }
    return previous[b.length];
}

/**
 * Reports whether a text starts with another.
 *
 * Params:
 *   text = The text.
 *   prefix = The start to look for.
 *
 * Returns:
 *   True when the first bytes of text are prefix.
 */
bool hasPrefix(string text, string prefix) @safe pure nothrow @nogc {
    return text.length >= prefix.length && text[0 .. prefix.length] == prefix;
}

/**
 * Cuts the ASCII space characters from both ends of a text.
 *
 * Params:
 *   text = The text.
 *
 * Returns:
 *   The text without leading and trailing spaces.
 */
string trim(string text) @safe pure nothrow @nogc {
    size_t start = 0;
    size_t end = text.length;
    while (start < end && isSpaceChar(text[start])) {
        start++;
    }
    while (end > start && isSpaceChar(text[end - 1])) {
        end--;
    }
    return text[start .. end];
}

/**
 * Reports whether a character is an ASCII space character.
 *
 * Params:
 *   c = The character.
 *
 * Returns:
 *   True for space, tab, newline, carriage return, vertical tab and form feed.
 */
bool isSpaceChar(char c) @safe pure nothrow @nogc {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f';
}

/**
 * Lowers an ASCII letter.
 *
 * Params:
 *   c = The character.
 *
 * Returns:
 *   The lower-case letter; other characters unchanged.
 */
char lowerAscii(char c) @safe pure nothrow @nogc {
    return c >= 'A' && c <= 'Z' ? cast(char) (c + ('a' - 'A')) : c;
}
