/**
* This file is part of Prosody Web Browser (Copyright Adrian Cochrane 2018, 2023).
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
/** Template to use to test all the other tags work as expected.
    This builds on the diff & JSON extensions.

These are used on test.html, and as a nice aside exercies the
    entire parser quite naturally. Leaving just the tags & filters to be tested. */
namespace Prosody.xTestRunner {
    public class TestBuilder : TagBuilder, Object {
        public Template? build(Parser parser, WordIter args) throws SyntaxError {
            var caption = dequote(args.next());
            args.assert_end();

            WordIter? endtoken;
            Bytes test_source;
            Template testcase;
            try {
                testcase = parser.parse("input output", out endtoken, out test_source);
            } catch (SyntaxError e) {
                var lexer = parser.lex;
                var failed_token = lexer.text[lexer.last_start:lexer.last_end];
                var try_again = true;
                while (try_again) {
                    try {
                        parser.parse("endtest", out endtoken);
                        try_again = false;
                    } catch (SyntaxError e) {/* ignore */}
                }
                if (endtoken == null)
                    throw new SyntaxError.UNBALANCED_TAGS(
                        "{%% test %%} must be closed with a {%% endtest %%} tag.");

                return new TestSyntaxError(caption, failed_token, e);
            }
            Bytes endtag = endtoken.next();

            Data.Data input = new Data.Empty();
            Bytes input_text = EMPTY();
            if (s(endtag) == "input") {
                var type = endtoken.next_value();
                endtoken.assert_end();
                if (type == null) type = new Bytes("json".data);

                input_text = parser.scan_until("output", out endtoken);
                endtag = endtoken.next();

                input = read_input(type, input_text.get_data());
            }

            if (endtag == null)
                throw new SyntaxError.UNBALANCED_TAGS(
                        "{%% test %%} expects an {%% output %%} branch");
            endtoken.assert_end();
            Bytes output = parser.scan_until("endtest", out endtoken);

            if (endtoken == null)
                throw new SyntaxError.UNBALANCED_TAGS(
                        "{%% test %%} requires a closing {%% endtest %%} tag");
            endtoken.next(); endtoken.assert_end();
            return new TestTag(caption, testcase, test_source,
                    input, input_text, output);
        }

        private static Data.Data read_input(Bytes type, uint8[] text) throws SyntaxError {
            switch (s(type)) {
            case "json":
                var json_parser = new Json.Parser();
                try {
                    json_parser.load_from_data((string) text, text.length);
                } catch (Error e) {
                    throw new SyntaxError.UNEXPECTED_CHAR(
                            "{%% test %%}: Invalid JSON in {%% input %%} block: %s", e.message);
                }
                return xJSON.build(json_parser.get_root());
            case "xml":
                var doc = Xml.Parser.parse_memory((string) text, text.length);
                if (doc == null) throw new SyntaxError.UNEXPECTED_CHAR(
                        "{%% test %%}: Invalid XML in {%% input %%} block!");
                return new xXML.XML.with_doc(doc, {"en"});
            }
            throw new SyntaxError.INVALID_ARGS(@"Invalid {%% input %%} data type $(s(type))");
        }
    }
    private class TestTag : Template {
        private Bytes caption;
        private Template testcase;
        private Bytes test_source;
        private Data.Data input;
        private Bytes input_text;
        private Bytes output;
        public TestTag(string caption, Template testcase, Bytes test_source,
                Data.Data input, Bytes input_text, Bytes output) {
            this.caption = new Bytes(caption.data);
            this.testcase = testcase;
            this.test_source = test_source;
            this.input = input;
            this.input_text = input_text;
            this.output = output;
        }

        public class TestSuite {
            public int passed = 0;
            public int count = 0;
            public bool success {get {return passed == count;}}

            public weak Object key;
            public TestSuite? next;

            public void record(bool passed) {
                this.count++; if (passed) this.passed++;
            }

            public void clean_tail() {
                var prev = this;
                for (var entry = next; entry != null; prev = entry, entry = entry.next) {
                    if (entry.key == null) prev.next = entry.next;
                }
            }
        }
        public static TestSuite? testsuites = null;
        public static TestSuite testsuite(Object key, out TestSuite? prev = null) {
            var int_id = (int) key;
            prev = null;
            for (var entry = testsuites; entry != null; prev = entry, entry = entry.next) {
                if (((int) entry.key) == int_id) {return entry;}
                if (entry.key == null) {
                    if (prev == null) testsuites = entry.next;
                    else prev.next = entry.next;
                }
            }

            testsuites = new TestSuite() {key = key, next = testsuites};
            return testsuites;
        }

        public override async void exec(Data.Data ctx, Writer stream) {
            var capture = new CaptureWriter();
            yield testcase.exec(input, capture);
            Bytes computed = capture.grab_data();

            xDiff.Ranges diff;
            bool passed;
            if (output.compare(computed) == 0) {
                // Fast & thankfully common case
                passed = true;
                diff = xDiff.Ranges();
            } else {
                diff = xDiff.diff(output, computed);
                passed = diff.a_ranges.size == 0 && diff.b_ranges.size == 0;
                assert(!passed); // Do the fast & slow checks agree?
            }

            testsuite(stream).record(passed);
            yield format_results(passed, stream, computed, diff);
        }

        private async void format_results(bool passed, Writer stream,
            Bytes computed, xDiff.Ranges diff)  {
            yield stream.writes("<details");
            yield stream.writes(">\n\t<summary style='background: ");
            yield stream.writes((passed ? "green" : "red"));
            yield stream.writes(";' title='");
            yield stream.writes(passed ? "PASS" : "FAILURE");
            yield stream.writes("'>");
            yield stream.escaped(caption);
            yield stream.writes("</summary>\n\t");

            yield stream.writes("<table>\n\t\t");
            yield stream.writes("<tr><th>Test Code</th>");
            yield stream.writes("<th>Test Input</th></tr>\n\t\t");
            yield stream.writes("<tr><td><pre>");
            yield stream.escaped(test_source);
            yield stream.writes("</pre></td><td><pre>");
            yield stream.escaped(input_text);
            yield stream.writes("</pre></td></tr>\n\t\t");

            yield stream.writes("<tr><th>Computed</th>");
            yield stream.writes("<th>Expected</th></tr>\n\t\t");
            yield stream.writes("<tr><td><pre>");
            yield xDiff.render_ranges(computed, diff.b_ranges, "ins", stream);
            yield stream.writes("</pre></td><td><pre>");
            yield xDiff.render_ranges(output, diff.a_ranges, "del", stream);
            yield stream.writes("</pre></td></tr>\n\t");
            yield stream.writes("</table>\n</details>");
        }
    }
    private class TestSyntaxError : Template {
        private SyntaxError error;
        private Bytes caption;
        private Bytes failed_tag;
        public TestSyntaxError(string caption, Bytes failed_tag, SyntaxError e) {
            this.error = e;
            this.caption = new Bytes(caption.data);
            this.failed_tag = failed_tag;
        }

        public override async void exec(Data.Data ctx, Writer stream) {
            yield stream.writes("<details");
            yield stream.writes(">\n\t<summary style='background: yellow' title='");
            yield stream.writes("ERROR'>");
            yield stream.escaped(caption);
            yield stream.writes("</summary>\n\t<h3>");
            yield stream.writes(error.domain.to_string());
            yield stream.writes(" thrown :: While Parsing <code>");
            yield stream.write(failed_tag);
            yield stream.writes("</code></h3>\n\t<p>");
            yield stream.escaped(new Bytes(error.message.data));
            yield stream.writes("</p>\n</details>");

            TestTag.testsuite(stream).record(false);
        }
    }

    public class TestReportBuilder : TagBuilder, Object {
        public Template? build(Parser parser, WordIter args) throws SyntaxError {
            args.assert_end();
            return new TestReportTag();
        }
    }
    private class TestReportTag : Template {
        public override async void exec(Data.Data ctx, Writer output) {
            TestTag.TestSuite? prev_link;
            var t = TestTag.testsuite(output, out prev_link);
            yield output.writes("<aside style='background: ");
            yield output.writes(t.success ? "green" : "red");
            yield output.writes("; position: fixed; top: 10px; right: 10px; ");
            yield output.writes("padding: 10px;'>");
            yield output.writes(@"$(t.passed)/$(t.count)");
            yield output.writes(" passed</aside>\n<script>document.title = '");
            yield output.writes(t.success ? "Tests PASSED" : "Tests FAILED");
            yield output.writes("';</script>");

            // And clear away the test data.
            t.clean_tail();
            if (prev_link != null) prev_link.next = t.next;
            else TestTag.testsuites = t.next;
        }
    }

    public class DiffFilter : Filter {
        public override Data.Data filter(Data.Data a, Data.Data b) {
            var A = a.to_bytes(); var B = b.to_bytes();

            var loop = new MainLoop();
            AsyncResult? result = null;
            diff_to_str.begin(A, B, xDiff.diff(A, B), (obj, res) => {
                result = res;
                loop.quit();
            });
            loop.run();
            return new Data.Substr(diff_to_str.end(result));
        }

        private async Bytes diff_to_str(Bytes a, Bytes b, xDiff.Ranges diff) {
            var output = new CaptureWriter();
            yield xDiff.render_ranges(a, diff.a_ranges, "-", output);
            yield output.writes("\t");
            yield xDiff.render_ranges(b, diff.b_ranges, "+", output);
            return output.grab_data();
        }
    }
}
