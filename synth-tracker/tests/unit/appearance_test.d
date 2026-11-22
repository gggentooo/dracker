/**
 * File:         tests/unit/appearance_test.d
 * Module:       tests.unit.appearance_test
 * Phase:        Phase 8.5.6 — Appearance Model Verification
 *
 * Purpose:
 *   Gates every built-in palette in both contrast modes: every text/background pair from usedTextPairs() meets
 *   7:1 (High) / 4.5:1 (Low), every graphics pair meets 4.5:1 / 3:1, and every categorical set keeps CIEDE2000
 *   ΔE ≥ 10 under normal vision and simulated protanopia, deuteranopia and tritanopia. Also checks that the
 *   default theme is the light high-contrast Okabe–Ito palette, metrics never change, emphasize() direction,
 *   reference values of the WCAG, Machado and CIEDE2000 math, the settings and .stpalette codecs (round trip,
 *   strict rejection), and custom palette editing.
 *
 * Real-Time & Safety Contract:
 *   Headless value-type tests; no platform window or global state.
 *
 * Dependencies:
 *   Internal: gui.appearance, gui.theme, gui.renderer (ColorRGBA)
 *   External: std.format, std.math
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites for gui.appearance
 *
 * See_Also:
 *   architecture.md, dev_plan.md (Phase 8.5)
 */
module tests.unit.appearance_test;

version (unittest) {
    import std.format : format;
    import std.math : fabs;
    import std.string : indexOf;

    import gui.appearance;
    import gui.renderer : ColorRGBA;
    import gui.theme;

    private StudioTheme[] allBuiltinThemes() {
        StudioTheme[] list;
        foreach (p; builtinPalettes()) {
            list ~= makeTheme(p, ContrastMode.high);
            list ~= makeTheme(p, ContrastMode.low);
        }
        return list;
    }

    unittest {
        foreach (t; allBuiltinThemes()) {
            ContrastPair[] bad = contrastFailures(t);
            string msg;
            foreach (ref p; bad) {
                msg ~= format("\n  %s: %s on %s = %.2f (needs %.1f)", t.paletteName, p.fg, p.bg,
                    contrastRatio(p.fgColor, p.bgColor), p.isText ? textFloor(t.contrast) : graphicFloor(t.contrast));
            }
            assert(bad.length == 0, "contrast gate failed:" ~ msg);
            assert(usedTextPairs(t).length > 150 && usedGraphicPairs(t).length > 40);
        }
    }

    unittest {
        foreach (t; allBuiltinThemes()) {
            foreach (set; categoricalSets()) {
                string a, b;
                CvdType k;
                immutable float d = minCategoricalDeltaE(t, set, a, b, k);
                assert(d >= 10.0f, format("%s / %s: %s vs %s ΔE %.2f under %s", t.paletteName, set.name, a, b, d, k));
                assert(set.cue.length > 0);
            }
        }
    }

    unittest {
        immutable StudioTheme d = StudioTheme.init;
        assert(d.isLight && d.contrast == ContrastMode.high && d.paletteName == "Light · High Contrast · Okabe–Ito");
        assert(d.background == ColorRGBA.fromHex(0xFFFFFFFF) && d.text == ColorRGBA.fromHex(0x000000FF));
        PaletteSpec def = builtinPalettes()[0];
        assert(def.name == DEFAULT_PALETTE && def.builtin);
        assert(makeTheme(def, ContrastMode.high) == d);
        AppearanceSettings s;
        assert(s.uiFont == "Atkinson Hyperlegible Next" && s.monoFont == "Fira Code");
        assert(s.contrast == ContrastMode.high && s.palette == DEFAULT_PALETTE);
        assert(themeFor(s) == d);
        assert(builtinPalettes().length == 3 && !builtinPalettes()[2].colors.isLight);
        string[] names;
        foreach (t; allBuiltinThemes()) {
            names ~= t.paletteName;
        }
        assert(names == ["Light · High Contrast · Okabe–Ito", "Light · Low Contrast · Okabe–Ito",
            "Light · High Contrast · Tol Bright", "Light · Low Contrast · Tol Bright",
            "Dark · High Contrast · Okabe–Ito", "Dark · Low Contrast · Okabe–Ito"]);
    }

    unittest {
        immutable StudioTheme ref8 = StudioTheme.init;
        foreach (t; allBuiltinThemes()) {
            static foreach (m; THEME_METRIC_FIELDS) {
                assert(__traits(getMember, t, m) == __traits(getMember, ref8, m), m);
            }
            assert(t.fontSizeSmall == 11.0f && t.fontSizeBody == 13.0f && t.fontSizeTitle == 15.0f
                && t.fontSizeMono == 12.0f && t.controlHeight == 22.0f);
            assert(t.textGamma > 0.5f && t.textGamma <= 1.0f);
            assert(t.isLight == (relativeLuminance(t.background) > 0.5f));
        }
        StudioTheme low = makeTheme(builtinPalettes()[0], ContrastMode.low);
        assert(low.background != StudioTheme.init.background && low.text != StudioTheme.init.text);
        assert(contrastRatio(low.text, low.background) < contrastRatio(StudioTheme.init.text, StudioTheme.init.background));
        assert(low.trackerNote == StudioTheme.init.trackerNote && low.wireAudio == StudioTheme.init.wireAudio);
        assert(low.textGamma > StudioTheme.init.textGamma);
    }

    unittest {
        immutable StudioTheme light = StudioTheme.init;
        immutable StudioTheme dark = makeTheme(builtinPalettes()[2], ContrastMode.high);
        immutable ColorRGBA mid = ColorRGBA(0.5f, 0.5f, 0.5f, 0.7f);
        immutable ColorRGBA l = light.emphasize(mid, 0.2f);
        immutable ColorRGBA k = dark.emphasize(mid, 0.2f);
        assert(l.r < mid.r && l.g < mid.g && l.b < mid.b && l.a == mid.a);
        assert(k.r > mid.r && k.g > mid.g && k.b > mid.b && k.a == mid.a);
        assert(light.emphasize(mid, 0.0f) == mid && light.emphasize(mid, -1.0f) == mid);
        assert(light.emphasize(mid, 5.0f).r == 0.0f && dark.emphasize(mid, 5.0f).r == 1.0f);
        assert(StudioTheme.wireDash(WireKind.audio) == WireDash.solid);
        assert(StudioTheme.wireDash(WireKind.sidechain) == WireDash.doubled);
        assert(StudioTheme.wireDash(WireKind.event) == WireDash.dashed);
        assert(StudioTheme.wireDash(WireKind.cv) == WireDash.dotted);
        assert(light.clipColor(0) == light.clip0 && light.clipColor(9) == light.clip1);
        assert(light.categoryTint(true) > light.categoryTint(false) && dark.categoryTint(false) < light.categoryTint(false));
    }

    unittest {
        immutable ColorRGBA white = ColorRGBA(1, 1, 1, 1);
        immutable ColorRGBA black = ColorRGBA(0, 0, 0, 1);
        assert(fabs(contrastRatio(black, white) - 21.0f) < 1e-3f && fabs(contrastRatio(white, black) - 21.0f) < 1e-3f);
        assert(fabs(contrastRatio(white, white) - 1.0f) < 1e-6f);
        assert(fabs(contrastRatio(ColorRGBA.fromHex(0x767676FF), white) - 4.54f) < 0.01f);
        assert(fabs(contrastRatio(ColorRGBA.fromHex(0x595959FF), white) - 7.0f) < 0.01f);
        assert(fabs(relativeLuminance(white) - 1.0f) < 1e-5f && relativeLuminance(black) == 0.0f);
        immutable ColorRGBA half = compositeOver(ColorRGBA(0, 0, 0, 0.5f), white);
        assert(fabs(half.r - 0.5f) < 1e-6f && half.a == 1.0f);
        assert(fabs(contrastRatio(ColorRGBA(0, 0, 0, 0.5f), white) - contrastRatio(half, white)) < 1e-5f);

        assert(deltaE2000(white, white) == 0.0f);
        assert(fabs(deltaE2000(white, black) - 100.0f) < 0.01f);
        immutable ColorRGBA red = ColorRGBA(1, 0, 0, 1);
        immutable ColorRGBA green = ColorRGBA(0, 1, 0, 1);
        assert(deltaE2000(red, green) > 70.0f);
        assert(fabs(deltaE2000(red, green) - deltaE2000(green, red)) < 1e-3f);
        assert(simulateCvd(red, CvdType.none) == red);
        immutable ColorRGBA pr = simulateCvd(red, CvdType.protanopia);
        immutable ColorRGBA pg = simulateCvd(green, CvdType.protanopia);
        assert(deltaE2000(pr, pg) < deltaE2000(red, green));
        immutable ColorRGBA dr = simulateCvd(red, CvdType.deuteranopia);
        immutable ColorRGBA dg = simulateCvd(green, CvdType.deuteranopia);
        assert(deltaE2000(dr, dg) < 40.0f);
        foreach (k; [CvdType.protanopia, CvdType.deuteranopia, CvdType.tritanopia]) {
            immutable ColorRGBA gw = simulateCvd(white, k);
            assert(fabs(gw.r - 1.0f) < 0.02f && fabs(gw.g - 1.0f) < 0.02f && fabs(gw.b - 1.0f) < 0.02f);
            immutable ColorRGBA gray = simulateCvd(ColorRGBA(0.5f, 0.5f, 0.5f, 0.3f), k);
            assert(fabs(gray.r - 0.5f) < 0.02f && gray.a == 0.3f);
        }
        immutable ColorRGBA tb = simulateCvd(ColorRGBA.fromHex(0x0072B2FF), CvdType.tritanopia);
        immutable ColorRGBA tg = simulateCvd(ColorRGBA.fromHex(0x009E73FF), CvdType.tritanopia);
        assert(deltaE2000(tb, tg) < deltaE2000(ColorRGBA.fromHex(0x0072B2FF), ColorRGBA.fromHex(0x009E73FF)));
    }

    unittest {
        bool[string] seen;
        foreach (ref g; tokenGroups()) {
            assert(g.name.length > 0 && g.tokens.length > 0);
            foreach (t; g.tokens) {
                assert(colorTokenIndex(t) >= 0, t);
                assert((t in seen) is null, t);
                seen[t] = true;
            }
        }
        assert(seen.length == THEME_COLOR_TOKENS.length);
        foreach (ref set; categoricalSets()) {
            foreach (t; set.tokens) {
                assert(colorTokenIndex(t) >= 0);
            }
        }
        immutable StudioTheme base = StudioTheme.init;
        foreach (ref p; usedTextPairs(base)) {
            assert(colorTokenIndex(p.fg) >= 0 && p.isText && p.bgColor.a == 1.0f);
        }
        foreach (ref p; usedGraphicPairs(base)) {
            assert(colorTokenIndex(p.fg) >= 0 && !p.isText);
        }
        StudioTheme t = StudioTheme.init;
        assert(colorTokenIndex("nope") == -1 && !setColorToken(t, 9999, ColorRGBA(1, 0, 0, 1)));
        assert(colorToken(t, 9999) == ColorRGBA(0, 0, 0, 0));
        assert(setColorToken(t, cast(size_t) colorTokenIndex("text"), ColorRGBA(1, 0, 0, 1)) && t.text == ColorRGBA(1, 0, 0, 1));
    }

    unittest {
        StudioTheme t = StudioTheme.init;
        ContrastReading[] rd = contrastReadout(t, "textDim");
        assert(rd.length > 10);
        foreach (i, ref m; rd) {
            assert(m.passes() && m.required == 7.0f);
            if (i > 0) assert(rd[i - 1].ratio / rd[i - 1].required <= m.ratio / m.required + 1e-6f);
        }
        assert(contrastReadout(t, "panelSunken").length > 5);
        assert(contrastReadout(t, "trackerRowBar").length > 0);
        assert(contrastReadout(t, "shadow").length == 0);
        t.textDim = ColorRGBA.fromHex(0x9A9A9AFF);
        rd = contrastReadout(t, "textDim");
        assert(!rd[0].passes() && rd[0].ratio < 3.0f);
        assert(contrastFailures(t).length > 0);
    }

    unittest {
        AppearanceSettings s;
        s.uiFont = "Helvetica Neue";
        s.monoFont = "Menlo";
        s.contrast = ContrastMode.low;
        immutable string c1 = duplicateAsCustom(s, "Dark · Okabe–Ito");
        assert(c1 == "Custom 1" && s.palette == c1 && s.customPalettes.length == 1);
        assert(s.customPalettes[0].origin == "Dark · Okabe–Ito" && !s.customPalettes[0].colors.isLight);
        assert(setCustomToken(s, c1, cast(size_t) colorTokenIndex("accent"), ColorRGBA.fromHex(0x123456FF)));
        immutable string c2 = duplicateAsCustom(s, c1);
        assert(c2 == "Custom 2" && s.customPalettes[1].colors.accent == ColorRGBA.fromHex(0x123456FF));
        assert(s.customPalettes[1].origin == "Dark · Okabe–Ito");
        s.palette = DEFAULT_PALETTE;
        immutable string text = encodeAppearance(s);
        AppearanceSettings back;
        string err;
        assert(decodeAppearance(text, back, err), err);
        assert(back == s && encodeAppearance(back) == text);
        assert(themeFor(back) == themeFor(s));

        PaletteSpec spec;
        assert(findPalette(s, c2, spec) && !spec.builtin);
        immutable string pal = encodePalette(spec);
        PaletteSpec p2;
        assert(decodePalette(pal, p2, err), err);
        assert(p2.name == spec.name && p2.origin == spec.origin && p2.colors.accent == spec.colors.accent);
        assert(makeTheme(p2, ContrastMode.high) == makeTheme(spec, ContrastMode.high));
        assert(addImportedPalette(s, p2) == "Custom 3" && s.palette == "Custom 3");

        immutable string renamed = renameCustomNext(s, c1);
        assert(renamed == "Custom 4" && s.customPalettes[0].name == "Custom 4");
        s.palette = renamed;
        assert(renameCustomNext(s, renamed) == "Custom 5" && s.palette == "Custom 5");
        assert(renameCustomNext(s, DEFAULT_PALETTE) is null);
        assert(resetCustom(s, "Custom 5"));
        assert(s.customPalettes[0].colors.accent == builtinPalettes()[2].colors.accent);
        assert(!resetCustom(s, DEFAULT_PALETTE) && !deleteCustom(s, DEFAULT_PALETTE));
        assert(deleteCustom(s, "Custom 5") && s.palette == DEFAULT_PALETTE && s.customPalettes.length == 2);
        assert(!setCustomToken(s, "Custom 5", 0, ColorRGBA(0, 0, 0, 1)));
        assert(!setCustomToken(s, c2, THEME_COLOR_TOKENS.length, ColorRGBA(0, 0, 0, 1)));
        assert(setCustomToken(s, c2, cast(size_t) colorTokenIndex("background"), ColorRGBA(1, 1, 1, 1)));
        assert(s.customPalettes[0].colors.isLight);
        assert(duplicateAsCustom(s, "Missing Palette") is null);
        while (s.customPalettes.length < MAX_CUSTOM_PALETTES) {
            assert(duplicateAsCustom(s, DEFAULT_PALETTE) !is null);
        }
        assert(duplicateAsCustom(s, DEFAULT_PALETTE) is null && addImportedPalette(s, p2) is null);
        assert(decodeAppearance(encodeAppearance(s), back, err) && back.customPalettes.length == MAX_CUSTOM_PALETTES);
    }

    unittest {
        AppearanceSettings def;
        immutable string good = encodeAppearance(def);
        AppearanceSettings s;
        string err;
        assert(decodeAppearance(good, s, err) && s == def);
        assert(decodeAppearance(good ~ "\n\n", s, err));
        string crlf;
        foreach (ch; good) {
            if (ch == '\n') crlf ~= "\r\n";
            else crlf ~= ch;
        }
        assert(decodeAppearance(crlf, s, err) && s == def);
        void reject(string text, string why) {
            AppearanceSettings r;
            r.uiFont = "sentinel";
            string e;
            assert(!decodeAppearance(text, r, e), why);
            assert(r == AppearanceSettings.init && e.length > 0, why);
        }
        reject("", "empty");
        reject("synthtracker-appearance 2\nui_font=A\nmono_font=B\ncontrast=high\npalette=" ~ DEFAULT_PALETTE ~ "\n",
            "future version");
        reject("synthtracker-appearanc 1\n", "bad magic");
        reject(good ~ "extra=1\n", "unknown key");
        reject(good ~ "ui_font=Other\n", "duplicate key");
        reject("synthtracker-appearance 1\nui_font=A\nmono_font=B\ncontrast=medium\npalette=" ~ DEFAULT_PALETTE ~ "\n",
            "bad contrast");
        reject("synthtracker-appearance 1\nui_font=A\nmono_font=B\ncontrast=high\n", "missing palette");
        reject("synthtracker-appearance 1\nui_font=A\nmono_font=B\ncontrast=high\npalette=Nope\n", "unknown palette");
        reject("synthtracker-appearance 1\nui_font=\nmono_font=B\ncontrast=high\npalette=" ~ DEFAULT_PALETTE ~ "\n",
            "empty font");
        reject("synthtracker-appearance 1\nui_font=A\x01\nmono_font=B\ncontrast=high\npalette=" ~ DEFAULT_PALETTE ~ "\n",
            "control char");
        reject("synthtracker-appearance 1\nui_font=A\xFF\nmono_font=B\ncontrast=high\npalette=" ~ DEFAULT_PALETTE ~ "\n",
            "bad utf8");
        char[] big;
        big.length = MAX_FONT_NAME + 1;
        big[] = 'a';
        reject("synthtracker-appearance 1\nui_font=" ~ big.idup ~ "\nmono_font=B\ncontrast=high\npalette="
            ~ DEFAULT_PALETTE ~ "\n", "long font");
        char[] huge;
        huge.length = MAX_APPEARANCE_BYTES + 1;
        huge[] = ' ';
        reject("synthtracker-appearance 1\n" ~ huge.idup, "oversized");

        AppearanceSettings withCustom;
        duplicateAsCustom(withCustom, DEFAULT_PALETTE);
        immutable string ct = encodeAppearance(withCustom);
        assert(decodeAppearance(ct, s, err), err);
        import std.array : replace;

        reject(ct.replace("accent=004A73FF\n", ""), "missing token");
        reject(ct.replace("accent=004A73FF", "accent=004A73F"), "short hex");
        reject(ct.replace("accent=004A73FF", "accent=004A73FG"), "bad hex");
        reject(ct.replace("[end]\n", ""), "unterminated block is incomplete");
        reject(ct.replace("name=Custom 1", "name=" ~ DEFAULT_PALETTE), "shadows built-in");
        reject(ct.replace("origin=" ~ DEFAULT_PALETTE, "origin=Custom 9"), "bad origin");
        reject(ct.replace("light=1", "light=2"), "bad light flag");
        reject(ct.replace("accent=004A73FF\n", "accent=004A73FF\naccent=004A73FF\n"), "duplicate token");
        reject(ct.replace("accent=004A73FF\n", "bogus=004A73FF\n"), "unknown token");
        immutable size_t at = ct.indexOf("[palette]");
        reject(ct ~ ct[at .. $], "duplicate custom name");

        PaletteSpec p;
        assert(!decodePalette("synthtracker-palette 2\n", p, err) && err.length > 0);
        assert(!decodePalette("", p, err));
        PaletteSpec def0 = builtinPalettes()[0];
        immutable string pt = encodePalette(def0);
        assert(decodePalette(pt, p, err) && !p.builtin && p.name == DEFAULT_PALETTE);
        assert(!decodePalette(pt ~ "[end]\n", p, err));
        assert(!decodePalette(pt.replace("name=" ~ DEFAULT_PALETTE ~ "\n", ""), p, err));
    }

    unittest {
        import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir, write;
        import std.path : buildPath;

        immutable string dir = buildPath(tempDir(), "synthtracker_appearance_store_test");
        if (exists(dir)) rmdirRecurse(dir);
        scope (exit) if (exists(dir)) rmdirRecurse(dir);
        FileAppearanceStore store = new FileAppearanceStore(buildPath(dir, "nested", "appearance.cfg"));
        string text;
        assert(!store.load(text));
        string err;
        assert(store.save("synthtracker-appearance 1\n", err), err);
        assert(store.load(text) && text == "synthtracker-appearance 1\n");
        assert(!exists(store.path() ~ ".tmp"));
        assert(store.save("second", err) && readText(store.path()) == "second");
        char[] huge;
        huge.length = MAX_APPEARANCE_BYTES + 10;
        huge[] = 'x';
        write(store.path(), huge);
        assert(!store.load(text));
        FileAppearanceStore blocked = new FileAppearanceStore(buildPath(store.path(), "child.cfg"));
        assert(!blocked.save("x", err) && err.length > 0);
        assert(defaultAppearancePath().length == 0
            || defaultAppearancePath()[$ - "SynthTracker/appearance.cfg".length .. $] == "SynthTracker/appearance.cfg");
    }
}
