/**
 * File:         tests/unit/compose_catalog_test.d
 * Module:       tests.unit.compose_catalog_test
 * Phase:        Composition helper (dracker-compose) — T85 (Catalog tests)
 *
 * Purpose:
 *   Unit tests for compose.catalog: verifies that every registered module type, every script command
 *   from the command table, bundled presets, chord qualities, preset progressions, and all 24 keys
 *   appear in text and parsed JSON output, single-module queries report ports/parameters/options, and
 *   unknown topics return the nearest valid choice.
 *
 * Real-Time & Safety Contract:
 *   Off-RT unit tests; no filesystem writes.
 *
 * Dependencies:
 *   Internal: compose.catalog, compose.script.commands (createDefaultInterpreter), graph.registry
 *             (ModuleRegistry)
 *   External: std.algorithm (canFind), std.json (parseJSON, JSONValue)
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) tests covering all T85 requirements
 *
 * See_Also:
 *   docs/todo.md (T66, T85), source/compose/catalog.d
 */
module tests.unit.compose_catalog_test;

version (unittest) {
    import std.algorithm : canFind;
    import std.json : JSONValue, parseJSON;

    import compose.catalog : CatalogResult, runCatalog;
    import compose.script.commands : createDefaultInterpreter;
    import graph.registry : ModuleRegistry;

    unittest {
        CatalogResult all = runCatalog();
        assert(all.ok, all.error);
        JSONValue jAll = parseJSON(all.json);
        assert(jAll["ok"].boolean);

        auto descs = ModuleRegistry.descriptors();
        assert(jAll["modules"].array.length == descs.length);
        foreach (ref d; descs) {
            assert(all.text.canFind(d.typeId), d.typeId);
        }

        auto cmdTable = createDefaultInterpreter(true).commandTable();
        assert(jAll["commands"].array.length == cmdTable.length);
        foreach (ref c; cmdTable) {
            assert(all.text.canFind(c.name), c.name);
        }

        assert(jAll["chords"]["qualities"].array.length == 11);
        assert(jAll["progressions"].array.length == 11);
        assert(jAll["keys"].array.length == 24);
        assert(jAll["presets"].array.length >= 1);

        CatalogResult modById = runCatalog("synth.analog_gen");
        assert(modById.ok, modById.error);
        JSONValue jMod = parseJSON(modById.json);
        assert(jMod["module"]["typeId"].str == "synth.analog_gen");
        assert(jMod["module"]["ports"].array.length >= 2);
        assert(jMod["module"]["params"].array.length >= 3);
        assert(modById.text.canFind("Waveform") && modById.text.canFind("Saw"));

        CatalogResult modByName = runCatalog("Compressor");
        assert(modByName.ok);
        assert(parseJSON(modByName.json)["module"]["typeId"].str == "fx.compressor");
        assert(modByName.text.canFind("Sidechain") && modByName.text.canFind("Threshold"));

        CatalogResult badTopic = runCatalog("modles");
        assert(!badTopic.ok && badTopic.suggestion == "modules");

        CatalogResult badMod = runCatalog("synth.analog_ge");
        assert(!badMod.ok && badMod.suggestion == "synth.analog_gen");
    }
}
