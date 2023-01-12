/**
* This file is part of Prosody Web Browser (Copyright Adrian Cochrane 2017-2018, 2023).
*
* Prosody is free software: you can redistribute it and/or modify
* it under the terms of the GNU General Public License as published by
* the Free Software Foundation, either version 3 of the License, or
* (at your option) any later version.
*
* Prosody is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU General Public License for more details.

* You should have received a copy of the GNU General Public License
* along with Prosody.  If not, see <http://www.gnu.org/licenses/>.
*/

/** Custom Natural Language Support routines.

This module sacrifices the availability of pretty tools to solicit contributions,
in order to gain better performance and fewer SEGFAULTs.

Essentially it parses the translation catalogs as a template with a custom tag
called "{% msg %}". This data can then be incorporated into other templates via
the "{% trans %}" tag. */
namespace Prosody.xI18n {
    using Std;

    public string[] get_locales() {
        var locales = Intl.get_language_names();
        var ret = new Gee.ArrayList<string>.wrap(locales);
        var added = new Gee.HashSet<string>();

        for (var i = locales.length - 1; i >= 0; i--) {
            var sep = locales[i].index_of_char('_');
            if (sep == -1) {added.add(locales[i]); continue;}

            var fallback = locales[i][0:sep];
            if (fallback in added) continue;

            added.add(fallback);
            ret.insert(i, fallback);
        }
        return ret.to_array();
    }

// Try having each translation perform a database scan. However the problem
// with that is that it would reparse the translated templates each time. 
// So maintain a weak map to the translated templates from their source language.

// Combine with the {% with %} tag, and that should get us everything we need.
	private File? locales_dir = null;
	public void set_i18n_dir(File src) {locales_dir = src; catalogue = null;}
	private Bytes? catalogue = null;
    private Bytes load_catalogue() throws Error {
        if (catalogue != null) return catalogue;
        if (locales_dir == null) throw new SyntaxError.OTHER("No catalogue directory found!");

        foreach (var lang in get_locales()) {
            var file = locales_dir.get_child(lang);
            if (!file.query_exists()) continue;
            catalogue = file.load_bytes();
        }

        // If control flow reaches here, bail out!
        throw new SyntaxError.OTHER("No catalogue file found for specified languages");
    }

    private Bytes locate_message(Parser cat, Bytes key) throws SyntaxError {
        WordIter msg;
        cat.scan_until("msg", out msg);
        while (msg != null) {
            // {% msg %} can contain translator notes (format not defined here).

            WordIter trans;
            var message = cat.scan_until("trans", out trans);
            if (trans == null)
                throw new SyntaxError.UNBALANCED_TAGS("Missing {%% trans %%} in {%% msg %%} body");
            trans.next(); trans.assert_end();

            if (strip(message).compare(key) == 0)
                // Output so the cache doesn't need to hold external templates in memory.
                return strip(message);

            cat.scan_until("endmsg", out trans);
            if (trans == null)
                throw new SyntaxError.UNBALANCED_TAGS("Missing {%% endtrans %%}!");
            trans.next(); trans.assert_end();

            cat.scan_until("msg", out msg);
        }

        throw new SyntaxError.UNCLOSED_ARG(@"Failed to find translation for string '$(s(key))'!");
    }

    private Template parse_translations(Parser cat, out Bytes text = null)
            throws SyntaxError {
        // Essentially this is just a cat.parse call with extra verification.

        WordIter endtrans;
        var ret = cat.parse("endmsg", out endtrans, out text);
        if (endtrans == null)
            throw new SyntaxError.UNBALANCED_TAGS("Missing {%% endtrans %%}!");
        endtrans.next(); endtrans.assert_end();

        return ret;
    }

    // cache used to avoid keeping multiple copies of a translation in memory.
    private class CacheEntry {
        public Bytes key;
        public weak Template translation;
        public CacheEntry? next;

        public static CacheEntry translation_cache = new CacheEntry();
    }

    private void lookup_translation(Bytes key, ref Template body) {
        // Look it up in the cache of translations already in memory…
        CacheEntry? prev = null;
        CacheEntry? entry = CacheEntry.translation_cache;
        for (; entry != null; prev = entry, entry = entry.next) {
            if (entry.translation == null) {
                // Do a bit of cleanup
                if (prev == null) CacheEntry.translation_cache = entry.next;
                else prev.next = entry.next;
                continue;
            }

            if (key.compare(entry.key) != 0) continue;

            body = entry.translation;
            return;
        }

        // Failing that, scan the catalog file.
        try {
            var cat = new Parser(load_catalogue());
            var key2 = locate_message(cat, key);
            body = parse_translations(cat);

            entry = new CacheEntry();
            // Matching key from catalogue,
            //      So the calling template needn't be kept in memory.
            entry.key = key2;
            entry.translation = body;
            entry.next = CacheEntry.translation_cache;
            CacheEntry.translation_cache = entry;
        } catch (Error e) {/* Fail silently */}
    }


    public class TransBuilder : TagBuilder, Object {
        public Template? build(Parser parser, WordIter args) throws SyntaxError {
            var parameters = parse_params(args);

            WordIter? endtoken;
            Bytes key;
            var body = parser.parse("endtrans", out endtoken, out key);
            if (endtoken == null)
                throw new SyntaxError.UNBALANCED_TAGS("Missing {%% endtrans %%} tag.");
            endtoken.next(); endtoken.assert_end();

            lookup_translation(strip(key), ref body);
            return new WithTag(parameters, body);
        }
    }

    public class TransFilter : Filter {
        // Cache where we read up to last time,
        // in the hopes that the next message is shortly after it.
        private Parser cat = new Parser(EMPTY());

        public override Data.Data filter0(Data.Data text) {
            var key = text.to_bytes();
            var trans = key;
            try {
                locate_message(cat, key);
                parse_translations(cat, out trans);
            } catch (Error e) {
                /* Try again from the start */
                try {
                    cat = new Parser(load_catalogue());
                    locate_message(cat, key);
                    parse_translations(cat, out trans);
                } catch (Error e) {/* Fail silently */}
            }

            return new Data.Substr(trans);
        }
    }
}
