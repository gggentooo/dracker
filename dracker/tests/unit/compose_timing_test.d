/**
 * File:         tests/unit/compose_timing_test.d
 * Module:       tests.unit.compose_timing_test
 * Phase:        Composition helper (dracker-compose) — T73 (positions and lengths: bars, beats, lines)
 *
 * Purpose:
 *   Verifies compose.timing: the line counts of the time signatures 4/4, 3/4, 6/8, 7/8 and 5/16; parsing and
 *   formatting of positions (bar, bar.beat, bar.beat.sixteenth) with the offset and suggestion of every
 *   refusal; parsing and formatting of lengths in beats, bars and lines; conversion between a position and a
 *   line index in both directions for every signature; a length that is not a whole number of lines and a
 *   beat past the bar being refused with the nearest valid value; a sweep of malformed texts that must never
 *   throw; and that the API is usable from immutable (pure) bindings.
 *
 * Real-Time & Safety Contract:
 *   Pure single-threaded checks; no session, audio, GUI, or files.
 *
 * Dependencies:
 *   Internal: compose.timing, io.project_format (MAX_LINES)
 *   External: none
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites
 *
 * See_Also:
 *   docs/todo.md (T66, T67, T73)
 */
module tests.unit.compose_timing_test;

version (unittest) {
    import compose.timing;
    import io.project_format : MAX_LINES;

    private immutable TimeSignature[5] SIGS = [TimeSignature(4, 4), TimeSignature(3, 4), TimeSignature(6, 8),
        TimeSignature(7, 8), TimeSignature(5, 16)];
    private immutable uint[5] EXPECTED_LINES_PER_BEAT = [4, 4, 2, 2, 1];
    private immutable uint[5] EXPECTED_LINES_PER_BAR = [16, 12, 12, 14, 5];

    private string reasonOf(TimingError e) {
        return e.reason;
    }

    unittest {
        assert(LINES_PER_WHOLE_NOTE == 16);
        assert(MAX_POSITION_LINES == MAX_LINES);
        foreach (i, sig; SIGS) {
            assert(sig.isValid());
            assert(linesPerBeat(sig) == EXPECTED_LINES_PER_BEAT[i], formatTimeSignature(sig));
            assert(linesPerBar(sig) == EXPECTED_LINES_PER_BAR[i], formatTimeSignature(sig));
        }
        assert(linesPerBeat(TimeSignature(4, 3)) == 0);
        assert(linesPerBar(TimeSignature(4, 3)) == 0);
        assert(linesPerBeat(TimeSignature(0, 4)) == 0);
        assert(linesPerBeat(TimeSignature(17, 4)) == 0);
        assert(defaultTimeSignature() == TimeSignature(4, 4));
    }

    unittest {
        assert(formatTimeSignature(TimeSignature(7, 8)) == "7/8");
        foreach (text; ["4/4", "3/4", "6/8", "7/8", "5/16", "16/2", "1/16", "2/4"]) {
            immutable TimeSignatureResult r = parseTimeSignature(text);
            assert(r.ok, text);
            assert(formatTimeSignature(r.signature) == text, text);
        }
        immutable TimeSignatureResult empty = parseTimeSignature("");
        assert(!empty.ok);
        assert(empty.error.offset == 0);
        assert(empty.error.suggestion == "4/4");
        immutable TimeSignatureResult noSlash = parseTimeSignature("4");
        assert(!noSlash.ok);
        assert(noSlash.error.offset == 0);
        assert(noSlash.error.length == 1);
        immutable TimeSignatureResult missingNumerator = parseTimeSignature("/4");
        assert(!missingNumerator.ok);
        assert(missingNumerator.error.offset == 0);
        assert(missingNumerator.error.length == 0);
        immutable TimeSignatureResult missingDenominator = parseTimeSignature("4/");
        assert(!missingDenominator.ok);
        assert(missingDenominator.error.offset == 2);
        assert(missingDenominator.error.length == 0);
        immutable TimeSignatureResult badNumerator = parseTimeSignature("abc/4");
        assert(!badNumerator.ok);
        assert(badNumerator.error.offset == 0);
        assert(badNumerator.error.length == 3);
        immutable TimeSignatureResult badDenominator = parseTimeSignature("4/3");
        assert(!badDenominator.ok);
        assert(badDenominator.error.offset == 2);
        assert(badDenominator.error.suggestion == "4");
        immutable TimeSignatureResult tooLargeNumerator = parseTimeSignature("17/4");
        assert(!tooLargeNumerator.ok);
        assert(tooLargeNumerator.error.offset == 0);
        assert(tooLargeNumerator.error.suggestion == "16");
        immutable TimeSignatureResult zeroNumerator = parseTimeSignature("0/4");
        assert(!zeroNumerator.ok);
        assert(zeroNumerator.error.suggestion == "1");
        immutable TimeSignatureResult extraSlash = parseTimeSignature("4/4/4");
        assert(!extraSlash.ok);
        assert(extraSlash.error.offset == 3);
        assert(extraSlash.error.length == 1);
        immutable TimeSignatureResult letterDenominator = parseTimeSignature("4/x");
        assert(!letterDenominator.ok);
        assert(letterDenominator.error.offset == 2);
        assert(letterDenominator.error.length == 1);
        assert(letterDenominator.error.suggestion == "4");
        immutable TimeSignatureResult hugeNumerator = parseTimeSignature("99999999999/4");
        assert(!hugeNumerator.ok);
        assert(hugeNumerator.error.offset == 0);
        assert(hugeNumerator.error.length == 11);
        assert(reasonOf(hugeNumerator.error) == "the numerator of a time signature is at most 16");
        assert(hugeNumerator.error.suggestion == "16");
    }

    unittest {
        immutable TimeSignature fourFour = TimeSignature(4, 4);
        immutable TimeSignature threeFour = TimeSignature(3, 4);
        immutable TimeSignature sixEight = TimeSignature(6, 8);
        immutable TimeSignature fiveSixteen = TimeSignature(5, 16);

        assert(parsePosition("3", fourFour).ok);
        assert(parsePosition("3", fourFour).position == BeatPosition(3, 1, 1));
        assert(parsePosition("3.2", fourFour).position == BeatPosition(3, 2, 1));
        assert(parsePosition("3.2.3", fourFour).position == BeatPosition(3, 2, 3));
        assert(parsePosition("16.4.4", fourFour).position == BeatPosition(16, 4, 4));
        assert(parsePosition("1.6.2", sixEight).position == BeatPosition(1, 6, 2));
        assert(parsePosition("2.5.1", fiveSixteen).position == BeatPosition(2, 5, 1));

        immutable PositionResult zeroBar = parsePosition("0", fourFour);
        assert(!zeroBar.ok);
        assert(zeroBar.error.offset == 0);
        assert(zeroBar.error.length == 1);
        assert(zeroBar.error.suggestion == "1");
        immutable PositionResult emptyText = parsePosition("", fourFour);
        assert(!emptyText.ok);
        assert(emptyText.error.offset == 0);
        assert(emptyText.error.length == 0);
        immutable PositionResult trailingDot = parsePosition("1.", fourFour);
        assert(!trailingDot.ok);
        assert(trailingDot.error.offset == 2);
        assert(trailingDot.error.length == 0);
        immutable PositionResult leadingDot = parsePosition(".2", fourFour);
        assert(!leadingDot.ok);
        assert(leadingDot.error.offset == 0);
        immutable PositionResult doubleDot = parsePosition("1..2", fourFour);
        assert(!doubleDot.ok);
        assert(doubleDot.error.offset == 2);
        immutable PositionResult tooManyParts = parsePosition("1.2.3.4", fourFour);
        assert(!tooManyParts.ok);
        assert(tooManyParts.error.offset == 6);
        assert(tooManyParts.error.length == 1);
        assert(tooManyParts.error.suggestion == "3.2.3");
        immutable PositionResult letters = parsePosition("a", fourFour);
        assert(!letters.ok);
        assert(letters.error.offset == 0);
        immutable PositionResult slash = parsePosition("1/2", fourFour);
        assert(!slash.ok);
        assert(slash.error.offset == 0);
        immutable PositionResult huge = parsePosition("100000000000", fourFour);
        assert(!huge.ok);
        assert(huge.error.offset == 0);
        assert(huge.error.length == 12);
        assert(reasonOf(huge.error) == "the position number is too large");
        assert(huge.error.suggestion == "256.4.4");

        immutable PositionResult beatBeyondBar = parsePosition("1.4", threeFour);
        assert(!beatBeyondBar.ok);
        assert(beatBeyondBar.error.offset == 2);
        assert(beatBeyondBar.error.length == 1);
        assert(beatBeyondBar.error.suggestion == "3");
        assert(reasonOf(beatBeyondBar.error) == "a bar of 3/4 has 3 beats");
        immutable PositionResult beatZero = parsePosition("1.0", threeFour);
        assert(!beatZero.ok);
        assert(beatZero.error.offset == 2);
        assert(beatZero.error.suggestion == "1");
        immutable PositionResult beatBeyondBarSixEight = parsePosition("1.7", sixEight);
        assert(!beatBeyondBarSixEight.ok);
        assert(beatBeyondBarSixEight.error.suggestion == "6");
        immutable PositionResult sixteenthBeyondBeat = parsePosition("1.1.5", threeFour);
        assert(!sixteenthBeyondBeat.ok);
        assert(sixteenthBeyondBeat.error.offset == 4);
        assert(sixteenthBeyondBeat.error.length == 1);
        assert(sixteenthBeyondBeat.error.suggestion == "4");
        assert(reasonOf(sixteenthBeyondBeat.error) == "a beat of 3/4 has 4 sixteenths");
        immutable PositionResult sixteenthBeyondBeatFiveSixteen = parsePosition("2.1.2", fiveSixteen);
        assert(!sixteenthBeyondBeatFiveSixteen.ok);
        assert(sixteenthBeyondBeatFiveSixteen.error.offset == 4);
        assert(sixteenthBeyondBeatFiveSixteen.error.suggestion == "1");
        immutable PositionResult sixteenthZero = parsePosition("1.2.0", fourFour);
        assert(!sixteenthZero.ok);
        assert(sixteenthZero.error.offset == 4);

        immutable PositionResult pastLongestPattern = parsePosition("257", fourFour);
        assert(!pastLongestPattern.ok);
        assert(reasonOf(pastLongestPattern.error) == "the position is past the longest pattern (4096 lines)");
        assert(pastLongestPattern.error.suggestion == "256.4.4");
        assert(parsePosition("256", fourFour).ok);

        immutable PositionResult invalidSignature = parsePosition("1.2", TimeSignature(4, 3));
        assert(!invalidSignature.ok);
        assert(reasonOf(invalidSignature.error) == "the time signature 4/3 is not one this project accepts");
        assert(invalidSignature.error.suggestion == "4/4");
    }

    unittest {
        assert(formatPosition(BeatPosition(3, 1, 1)) == "3");
        assert(formatPosition(BeatPosition(3, 2, 1)) == "3.2");
        assert(formatPosition(BeatPosition(3, 2, 3)) == "3.2.3");
        assert(formatPosition(BeatPosition(3, 1, 3)) == "3.1.3");
        assert(formatPosition(BeatPosition(1, 1, 1)) == "1");
    }

    unittest {
        immutable LinesResult first = positionToLine(BeatPosition(1, 1, 1), TimeSignature(4, 4));
        assert(first.ok);
        assert(first.lines == 0);
        assert(positionToLine(BeatPosition(4, 4, 4), TimeSignature(4, 4)).lines == 63);
        assert(positionToLine(BeatPosition(4, 1, 4), TimeSignature(4, 4)).lines == 51);
        assert(positionToLine(BeatPosition(2, 3, 2), TimeSignature(3, 4)).lines == 21);
        assert(positionToLine(BeatPosition(2, 1, 2), TimeSignature(3, 4)).lines == 13);
        assert(positionToLine(BeatPosition(1, 5, 2), TimeSignature(6, 8)).lines == 9);
        assert(positionToLine(BeatPosition(3, 4, 1), TimeSignature(5, 16)).lines == 13);
        assert(positionToLine(BeatPosition(2, 7, 2), TimeSignature(7, 8)).lines == 27);
        assert(lineToPosition(63, TimeSignature(4, 4)).position == BeatPosition(4, 4, 4));
        assert(lineToPosition(51, TimeSignature(4, 4)).position == BeatPosition(4, 1, 4));
        assert(lineToPosition(21, TimeSignature(3, 4)).position == BeatPosition(2, 3, 2));
        assert(lineToPosition(13, TimeSignature(3, 4)).position == BeatPosition(2, 1, 2));
        assert(lineToPosition(9, TimeSignature(6, 8)).position == BeatPosition(1, 5, 2));
        assert(lineToPosition(13, TimeSignature(5, 16)).position == BeatPosition(3, 4, 1));
        assert(lineToPosition(27, TimeSignature(7, 8)).position == BeatPosition(2, 7, 2));

        foreach (sig; SIGS) {
            foreach (uint line; 0 .. 200) {
                immutable PositionResult forward = lineToPosition(line, sig);
                assert(forward.ok, formatTimeSignature(sig));
                immutable LinesResult back = positionToLine(forward.position, sig);
                assert(back.ok, formatTimeSignature(sig));
                assert(back.lines == line, formatTimeSignature(sig));
                immutable PositionResult reparsed = parsePosition(formatPosition(forward.position), sig);
                assert(reparsed.ok, formatPosition(forward.position));
                assert(reparsed.position == forward.position, formatPosition(forward.position));
            }
        }

        immutable LinesResult pastLongest = positionToLine(BeatPosition(257, 1, 1), TimeSignature(4, 4));
        assert(!pastLongest.ok);
        assert(pastLongest.error.suggestion == "256.4.4");
        immutable PositionResult linePastLongest = lineToPosition(cast(uint) MAX_POSITION_LINES, TimeSignature(4, 4));
        assert(!linePastLongest.ok);
        assert(linePastLongest.error.suggestion == "4095");
        immutable LinesResult wrappingBar = positionToLine(BeatPosition(268_435_457, 1, 1), TimeSignature(4, 4));
        assert(!wrappingBar.ok);
        assert(!positionToLine(BeatPosition(uint.max, 4, 4), TimeSignature(4, 4)).ok);
        immutable LinesResult badBeat = positionToLine(BeatPosition(1, 4, 1), TimeSignature(3, 4));
        assert(!badBeat.ok);
        assert(badBeat.error.suggestion == "3");
        immutable LinesResult badSixteenth = positionToLine(BeatPosition(1, 1, 3), TimeSignature(5, 16));
        assert(!badSixteenth.ok);
        assert(badSixteenth.error.suggestion == "1");
        immutable LinesResult badBar = positionToLine(BeatPosition(0, 1, 1), TimeSignature(4, 4));
        assert(!badBar.ok);
        assert(badBar.error.suggestion == "1");
        immutable LinesResult invalidSignature = positionToLine(BeatPosition(1, 1, 1), TimeSignature(4, 3));
        assert(!invalidSignature.ok);
        assert(lineToPosition(1, TimeSignature(4, 3)).error.offset == 0);
    }

    unittest {
        immutable TimeSignature fourFour = TimeSignature(4, 4);
        immutable TimeSignature threeFour = TimeSignature(3, 4);
        immutable TimeSignature sixEight = TimeSignature(6, 8);
        immutable TimeSignature sevenEight = TimeSignature(7, 8);
        immutable TimeSignature fiveSixteen = TimeSignature(5, 16);

        assert(parseLength("1", fourFour).length.lines == 4);
        assert(parseLength("1/2", fourFour).length.lines == 2);
        assert(parseLength("2", fourFour).length.lines == 8);
        assert(parseLength("7/2", fourFour).length.lines == 14);
        assert(parseLength("1b", fourFour).length.lines == 16);
        assert(parseLength("2b", fourFour).length.lines == 32);
        assert(parseLength("3/2b", fourFour).length.lines == 24);
        assert(parseLength("3l", fourFour).length.lines == 3);
        assert(parseLength("3/12b", fourFour).length.lines == 4);
        assert(parseLength("10/20", fourFour).length.lines == 2);
        assert(parseLength("1", threeFour).length.lines == 4);
        assert(parseLength("1b", threeFour).length.lines == 12);
        assert(parseLength("1/2b", threeFour).length.lines == 6);
        assert(parseLength("2", sixEight).length.lines == 4);
        assert(parseLength("1", sixEight).length.lines == 2);
        assert(parseLength("1/2", sixEight).length.lines == 1);
        assert(parseLength("1b", sixEight).length.lines == 12);
        assert(parseLength("1/2b", sixEight).length.lines == 6);
        assert(parseLength("1/2b", sevenEight).length.lines == 7);
        assert(parseLength("1b", sevenEight).length.lines == 14);
        assert(parseLength("2b", fiveSixteen).length.lines == 10);
        assert(parseLength("1", fiveSixteen).length.lines == 1);
        assert(parseLength("3l", fiveSixteen).length.lines == 3);
        assert(parseLength("1024", fourFour).length.lines == 4096);
        assert(!parseLength("1025", fourFour).ok);
        assert(parseLength("1025", fourFour).error.suggestion == "256b");
        assert(parseLength("2000", threeFour).error.suggestion == "1024");
        foreach (sig; SIGS) {
            immutable LengthResult overLong = parseLength("100000b", sig);
            assert(!overLong.ok, formatTimeSignature(sig));
            immutable LengthResult suggested = parseLength(overLong.error.suggestion, sig);
            assert(suggested.ok, overLong.error.suggestion);
            assert(suggested.length.lines == MAX_LINES, overLong.error.suggestion);
        }
        immutable LengthResult hugeNumber = parseLength("99999999999", fourFour);
        assert(!hugeNumber.ok);
        assert(reasonOf(hugeNumber.error) == "the length number is too large");
        assert(hugeNumber.error.suggestion == "256b");

        immutable LengthResult fractionOfLines = parseLength("1/2l", fourFour);
        assert(!fractionOfLines.ok);
        assert(fractionOfLines.error.offset == 0);
        assert(fractionOfLines.error.length == 4);
        assert(reasonOf(fractionOfLines.error) == "a length in lines must be a whole number of lines; write fractions in beats");
        assert(fractionOfLines.error.suggestion == "1/2");

        immutable LengthResult notWholeLines = parseLength("1/3", fourFour);
        assert(!notWholeLines.ok);
        assert(notWholeLines.error.suggestion == "1/4");
        immutable LengthResult beatFractionTooFine = parseLength("1/2", fiveSixteen);
        assert(!beatFractionTooFine.ok);
        assert(beatFractionTooFine.error.suggestion == "1");
        immutable LengthResult barFractionTooFine = parseLength("1/2b", fiveSixteen);
        assert(!barFractionTooFine.ok);
        assert(barFractionTooFine.error.suggestion == "3");
        immutable LengthResult zero = parseLength("0", fourFour);
        assert(!zero.ok);
        assert(reasonOf(zero.error) == "a length is at least one line");
        assert(zero.error.suggestion == "1");

        assert(!parseLength("", fourFour).ok);
        assert(parseLength("", fourFour).error.suggestion == "1");
        assert(!parseLength(" 1", fourFour).ok);
        assert(parseLength(" 1", fourFour).error.offset == 0);
        assert(!parseLength("b", fourFour).ok);
        assert(parseLength("b", fourFour).error.reason == "a length must start with a number");
        assert(!parseLength("1/", fourFour).ok);
        assert(parseLength("1/", fourFour).error.offset == 2);
        assert(parseLength("1/", fourFour).error.suggestion == "1/2");
        assert(!parseLength("1/0", fourFour).ok);
        assert(parseLength("1/0", fourFour).error.offset == 2);
        assert(!parseLength("1/x", fourFour).ok);
        assert(parseLength("1/x", fourFour).error.offset == 2);
        immutable LengthResult unknownUnit = parseLength("2q", fourFour);
        assert(!unknownUnit.ok);
        assert(unknownUnit.error.offset == 1);
        assert(unknownUnit.error.length == 1);
        assert(unknownUnit.error.suggestion == "b");
        immutable LengthResult trailingText = parseLength("2bb", fourFour);
        assert(!trailingText.ok);
        assert(trailingText.error.offset == 2);
        immutable LengthResult tooLong = parseLength("1000b", fourFour);
        assert(!tooLong.ok);
        assert(reasonOf(tooLong.error) == "the length is longer than the longest pattern (4096 lines)");
        assert(tooLong.error.suggestion == "256b");
        immutable LengthResult invalidSignature = parseLength("1", TimeSignature(4, 3));
        assert(!invalidSignature.ok);
        assert(reasonOf(invalidSignature.error) == "the time signature 4/3 is not one this project accepts");
    }

    unittest {
        assert(formatLength(linesToLength(8), TimeSignature(4, 4)) == "2");
        assert(formatLength(linesToLength(2), TimeSignature(4, 4)) == "1/2");
        assert(formatLength(linesToLength(3), TimeSignature(4, 4)) == "3/4");
        assert(formatLength(linesToLength(24), TimeSignature(4, 4)) == "6");
        assert(formatLength(linesToLength(16), TimeSignature(4, 4)) == "1b");
        assert(formatLength(linesToLength(32), TimeSignature(4, 4)) == "2b");
        assert(formatLength(linesToLength(12), TimeSignature(3, 4)) == "1b");
        assert(formatLength(linesToLength(6), TimeSignature(3, 4)) == "3/2");
        assert(formatLength(linesToLength(8), TimeSignature(3, 4)) == "2");
        assert(formatLength(linesToLength(12), TimeSignature(6, 8)) == "1b");
        assert(formatLength(linesToLength(6), TimeSignature(6, 8)) == "3");
        assert(formatLength(linesToLength(3), TimeSignature(6, 8)) == "3/2");
        assert(formatLength(linesToLength(1), TimeSignature(6, 8)) == "1/2");
        assert(formatLength(linesToLength(14), TimeSignature(7, 8)) == "1b");
        assert(formatLength(linesToLength(7), TimeSignature(7, 8)) == "7/2");
        assert(formatLength(linesToLength(5), TimeSignature(5, 16)) == "1b");
        assert(formatLength(linesToLength(3), TimeSignature(5, 16)) == "3");
        assert(formatLength(linesToLength(1), TimeSignature(5, 16)) == "1");
        assert(formatLength(linesToLength(0), TimeSignature(4, 4)) == "0");
        assert(formatLength(linesToLength(5), TimeSignature(4, 3)) == "5");
    }

    unittest {
        assert(beatsOf(linesToLength(8), TimeSignature(4, 4)) == Fraction(2, 1));
        assert(beatsOf(linesToLength(2), TimeSignature(4, 4)) == Fraction(1, 2));
        assert(beatsOf(linesToLength(3), TimeSignature(6, 8)) == Fraction(3, 2));
        assert(beatsOf(linesToLength(6), TimeSignature(6, 8)) == Fraction(3, 1));
        assert(beatsOf(linesToLength(7), TimeSignature(7, 8)) == Fraction(7, 2));
        assert(beatsOf(linesToLength(3), TimeSignature(5, 16)) == Fraction(3, 1));
        assert(beatsOf(linesToLength(5), TimeSignature(4, 3)) == Fraction(5, 1));
    }

    unittest {
        foreach (sig; SIGS) {
            foreach (uint lines; 1 .. 64) {
                immutable string text = formatLength(linesToLength(lines), sig);
                immutable LengthResult parsed = parseLength(text, sig);
                assert(parsed.ok, text ~ " in " ~ formatTimeSignature(sig));
                assert(parsed.length.lines == lines, text ~ " in " ~ formatTimeSignature(sig));
            }
        }
    }

    unittest {
        immutable char[8] ALPHABET = ['0', '1', '9', '.', '/', 'b', 'l', 'x'];
        foreach (sig; SIGS) {
            foreach (a; ALPHABET) {
                foreach (b; ALPHABET) {
                    foreach (c; ALPHABET) {
                        immutable string text = [a, b, c];
                        assert(parseLength(text, sig).ok || reasonOf(parseLength(text, sig).error).length > 0);
                        assert(parsePosition(text, sig).ok || reasonOf(parsePosition(text, sig).error).length > 0);
                        assert(parseTimeSignature(text).ok || reasonOf(parseTimeSignature(text).error).length > 0);
                    }
                }
            }
        }
        foreach (sig; SIGS) {
            foreach (uint bar; 1 .. 300) {
                immutable PositionResult r = parsePosition(formatPosition(BeatPosition(bar, 1, 1)), sig);
                assert(r.ok == (positionToLine(BeatPosition(bar, 1, 1), sig).ok), formatTimeSignature(sig));
            }
        }
    }

    unittest {
        immutable TimeSignature sig = defaultTimeSignature();
        immutable Length len = linesToLength(8);
        immutable BeatPosition pos = BeatPosition(3, 2, 3);
        immutable Fraction beats = beatsOf(len, sig);
        immutable string positionText = formatPosition(pos);
        immutable string lengthText = formatLength(len, sig);
        immutable uint line = positionToLine(pos, sig).lines;
        assert(sig.isValid());
        assert(beats == Fraction(2, 1));
        assert(positionText == "3.2.3");
        assert(lengthText == "2");
        assert(line == 38);
    }
}
