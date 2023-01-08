/**
* This file is part of Prosody Templating Language (Copyright Adrian Cochrane 2017, 2023).
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

/* Lexes, parses, and evaluates template files.
    Includes extension points for adding new data conversion "filters"
        & control flow "tags".
    Exposes rudimentary info on the line number, block structure,
        what token is currently being parsed, and Error information
        for debugging template syntax errors.

    The syntax is roughly Django compatible (https://docs.djangoproject.com/en/1.10/topics/templates/). */
using Gee;
namespace Prosody {
    /* Bytestring utils */
    public Bytes EMPTY() {return new Bytes(new uint8[0]);}
    public string s(Bytes data) {
        var builder = new StringBuilder();
        builder.append_len((string) data.get_data(), data.length);
        return builder.str;
    }
    public Bytes strip(Bytes data) {
        var start = 0;
        while (start < data.length && data[start] in " \t\r\n".data) start++;

        var end = data.length - 1;
        while (end < data.length && data[end] in " \t\r\n".data) end--;

        return data[start:++end];
    }
    public string dequote(Bytes data) {
        return s(data[1:data.length-1]).compress();
    }
    public Bytes[] split(string haystack, string needle) {
        var strings = haystack.split(needle);

        var ret = new Bytes[strings.length];
        for (var i = 0; i < strings.length; i++) ret[i] = new Bytes(strings[i].data);
        return ret;
    }

    public Gee.HashMap<Bytes, V> create_bytes_map<V>() {
        return new Gee.HashMap<Bytes, V>(bytes => bytes.hash(), (a, b) => a.compare(b) == 0);
    }

    /* Scans a templating word (which may include strings)
        that is seperated by the given delimiters. */
    // NOTE I tried to use regular expressions for this,
    //      but found them too heavy weight for what I needed.
    //      -- Adrian Cochrane
    public class WordIter {
        public Bytes text;
        public int index;
        public int line_no;
        public int line_offset;
        public int next_line_no;
        public int next_line_offset;
        public uint8[] delimiters;

        public WordIter() {
            this.index = 0; this.line_no = 0; this.line_offset = 0;
        }

        /* lexing methods */

        public void next_char(int by = 1) throws SyntaxError {
            // Save aside start for error reporting
            line_no = next_line_no; line_offset = next_line_offset;
            // count newlines
            while (by-- > 0) {
                index++;
                if (text[index] == '\n') {
                    next_line_no++; next_line_offset = index;
                }
            }
        }

        // Get the current character with error checking.
        // You can specify an error value (defaults to first delimiter)
        //      so it's the same as the value your checking for.
        public uint8 get_char(uint8? expected = null) {
            if (index < text.length) return text[index];
            else if (expected != null) return expected;
            else return delimiters[0];
        }

        public void scan_word() throws SyntaxError {
            /* Parses an item, which may include strings
                (that's how this is "smart"). */
            uint8 c;
            while (!(get_char() in delimiters)) {
                c = get_char();
                if (c in "\"'".data) {
                    /* parse a string */
                    next_char(); // open quote
                    while (get_char(c) != c) {
                        if (get_char() == '\\') next_char(); // escape
                        if (get_char() == '\n')
                            throw new SyntaxError.UNCLOSED_STRING(
                                    "Multiline strings not allowed.");
                        next_char(); // string char
                    }
                    if (get_char(0) != c)
                        throw new SyntaxError.UNCLOSED_STRING("A string literal wasn't closed!");
                    next_char(); // close quote
                } else {
                    next_char();
                }
            }
        }

        /* Iteration methods */
        public WordIter iterator() {return this;}

        public virtual Bytes? next_value() throws SyntaxError {
            if (index >= text.length) return null;

            while (get_char('"') in delimiters) {next_char();}
            var start = index;
            scan_word();

            if (start == index) return null;
            return text[start:index];
        }

        /* Parsing methods */
        public Bytes next() throws SyntaxError {
            var ret = next_value();
            if (ret == null)
                throw new SyntaxError.INVALID_ARGS("Tag got too few arguments.");
            return ret;
        }

        public void assert_end() throws SyntaxError {
            var arg = next_value();
            if (arg != null)
                throw new SyntaxError.INVALID_ARGS("Tag got too many arguments.");
        }

        public Bytes[] to_array() throws SyntaxError {
            var ret = new Gee.ArrayList<Bytes>();
            foreach (var entry in this) ret.add(entry);
            return ret.to_array();
        }
    }

    public WordIter smart_split(Bytes text, string delims) {
        return new WordIter() {text = text, delimiters = delims.data};
    }

    public class Lexer : WordIter {
        // To avoid confusing Scratch's naive brace matching algorithm
        //      (Scratch Text Editor is what elementary uses for an IDE)
        private static uint8 open = '{';
        private static uint8 close = '}';

        private static uint8[] tag_chars;

        public int last_start;
        public int last_end {get {return index;}}

        public Lexer(Bytes text) {
            this.text = text;
            this.delimiters = new uint8[1];
            this.index = 0;
            this.line_no = 0; this.line_offset = 0;

            tag_chars = new uint8[] {open, '%', '#'};
        }

        public uint8 find_next(uint8[] needles, ref int index) {
            for (; index < text.length; index++)
                if (text[index] in needles) return text[index];
            return 0;
        }

        private void scan_token() throws SyntaxError {
            last_start = index;

            if (text[index] == open && index + 2 < text.length &&
                    text[index+1] in tag_chars) {
                // It's some sort of substitution.
                delimiters[0] = text[index+1] == open ? close : text[index+1];
                next_char(2);
                scan_word();

                if (index + 2 > text.length)
                    throw new SyntaxError.UNCLOSED_ARG("Unexpected end of file");
                if (text[index + 1] != close)
                    throw new SyntaxError.UNEXPECTED_CHAR(
                            "'%c' cannot be used within tag", text[index]);
                next_char(2);
            } else {
                // It's literal text
                find_next({open, '\n'}, ref index);

                // Also scan any standalone `open` characters.
                while (index < text.length) {
                    if (text[index] == '\n') {
                        // count newlines ourselves.
                        line_no++;
                        line_offset = index;
                    }

                    // Are we starting a tag? If so, stop the text here.
                    if (index + 2 < text.length &&
                            text[index] == open && text[index + 1] in tag_chars)
                        break;

                    next_char();
                    find_next({open, '\n'}, ref index);
                }
            }
        }

        public override Bytes? next_value() throws SyntaxError {
            if (last_end >= text.length) return null;

            scan_token();
            return text[last_start:last_end];
        }

        public Bytes? peek() throws SyntaxError {
            var start = index;
            var ret = next_value();
            index = start;
            return ret;
        }
    }

    public errordomain SyntaxError {
        // Thrown by core parser
        UNCLOSED_STRING, UNCLOSED_ARG, UNEXPECTED_CHAR,
        UNKNOWN_TAG, UNKNOWN_FILTER,
        // Thrown by tags
        INVALID_ARGS, UNBALANCED_TAGS, OTHER
    }

    public enum TokenType {
        TEXT, VAR, TAG, COMMENT
    }

    namespace Token {
        public TokenType get_type(Bytes token) {
            if (token[0] != '{') return TokenType.TEXT;

            switch (token[1]) {
            case '{': return TokenType.VAR;
            case '%': return TokenType.TAG;
            case '#': return TokenType.COMMENT;
            default: return TokenType.TEXT;
            }
        }

        public WordIter get_args(Bytes token) {
            return smart_split(token[2:token.length-2], " \t\r\n");
        }
    }

    public interface TagBuilder : Object {
        public abstract Template? build(Parser parse, WordIter args) throws SyntaxError;
    }
    private Map<Bytes, TagBuilder>? tag_lib;

    public bool register_tag(string name, TagBuilder builder) {
        if (tag_lib == null) tag_lib = create_bytes_map();

        if (name[0] in "\"'".data) {
            warning("Failed to register tag. Name '%s' cannot start with a quote.", name);
            return false;
        }
        var key = new Bytes(name.data);
        if (tag_lib.has_key(key)) {
            warning("Failed to register tag. Tag '%s' already exists.", name);
            return false;
        }

        tag_lib[key] = builder;
        return true;
    }

    public abstract class Filter : Object {
        public virtual bool? should_escape() {return null;}

        public virtual Data.Data filter(Data.Data a, Data.Data b) {return filter0(a);}
        public virtual Data.Data filter0(Data.Data input) {return input;} // Shorthand method
    }
    private Map<Bytes, Filter>? filter_lib;

    public bool register_filter(string name, Filter filter) {
        if (filter_lib == null) filter_lib = create_bytes_map();

        var key = new Bytes(name.data);
        if (filter_lib.has_key(key)) {
            warning("Failed to register filter. Filter '|%s' already exists.", name);
            return false;
        }

        filter_lib[key] = filter;
        return true;
    }

    public bool lib_initialized() {
        return tag_lib != null || filter_lib != null;
    }

    public class Parser : Object {
        public Lexer lex;
        public Map<uint8,string> escapes;
        public Map<Bytes, TagBuilder> local_tag_lib;
        public string path;

        public Parser(Bytes source, string? filepath = null) {
            this.lex = new Lexer(source);
            this.escapes = Writer.html();
            this.path = filepath;
            this.local_tag_lib = create_bytes_map();
        }

        public Bytes get_current_token(out int line_no = null,
                out int line_offset = null,
                out int start = null, out int end = null) {
            line_no = lex.line_no;
            line_offset = lex.line_offset;
            start = lex.last_start;
            end = lex.last_end;
            return lex.text[lex.last_start:lex.last_end];
        }

        public Template parse(string endtags_str = "", out WordIter? ended_on = null,
                out Bytes? source_text = null) throws SyntaxError {
            var endtags = split(endtags_str, " ");
            ended_on = null; // default out value
            source_text = null; // default out value
            var start = lex.last_end;
            var startline = lex.line_no;

            Gee.List<Template> template_nodes = new ArrayList<Template>();
            foreach (var token in lex) {
                Template node = null;
                switch (Token.get_type(token)) {
                case TokenType.TEXT:
                    node = new Echo(token);
                    break;
                case TokenType.VAR:
                    node = new Variable.from_args(Token.get_args(token), escapes);
                    break;
                case TokenType.TAG:
                    var args = Token.get_args(token);
                    var name = args.next();

                    // Some tags contain all other tags, etc until some close tag.
                    // This supports that use case of the method.
                    // ALSO NOTE: The lexer keeps it's state between
                    //        iterators for this reason.
                    foreach (var endtag in endtags) {
                        if (endtag.compare(name) != 0) continue;

                        ended_on = Token.get_args(token);
                        source_text = lex.text[start:lex.last_start];
                        return new Block(template_nodes.to_array(), startline);
                    }

                    if (tag_lib != null && !local_tag_lib.has_key(name) &&
                            tag_lib.has_key(name))
                        local_tag_lib[name] = tag_lib[name];
                    if (!local_tag_lib.has_key(name))
                        throw new SyntaxError.UNKNOWN_TAG(@"Unknown tag '$(s(name))'");
                    node = local_tag_lib[name].build(this, args);
                    if (node == null) continue;
                    break;
                case TokenType.COMMENT:
                    continue;
                }

                template_nodes.add(node);
            }

            return new Block(template_nodes.to_array(), startline);
        }

        public Bytes scan_until(string endtags_str, out WordIter? ended_on)
                throws SyntaxError {
            var endtags = split(endtags_str, " ");
            var start = lex.last_end;
            ended_on = null; // Default out value

            foreach (var token in lex) {
                if (Token.get_type(token) == TokenType.TAG) {
                    var name = Token.get_args(token).next();

                    foreach (var endtag in endtags) {
                        if (endtag.compare(name) != 0) continue;

                        ended_on = Token.get_args(token);
                        return lex.text[start:lex.last_start];
                    }
                }
            }

            return lex.text[start:lex.last_start];
        }
    }

    public interface Writer : Object {
        public abstract async void write(Bytes text);
        public virtual async void writes(string text) {
            yield write(new Bytes(text.data));
        }
        // Utility methods predominatly for variable nodes to use.
        public static Gee.Map<uint8,string>? _html = null;
        public static Gee.Map<uint8,string> html() {
            if (_html == null) _html = build_escapes("<>&'\"",
                    "&lt;", "&gt;", "&amp;", "&apos;", "&quot;");
            return _html;
        }
        public virtual async void escaped(Bytes text, Gee.Map<uint8,string>? subs = html()) {
            if (text == null) return;
            if (subs == null || subs.size == 0) {yield write(text); return;}

            var needles = subs.keys.to_array();
            subs['\0'] = "\0";
            var lex = new Lexer(text);

            int start = 0; int end = 0;
            while (end < text.length) {
                var sub = subs[lex.find_next(needles, ref end)];
                yield write(text[start:end]); yield writes(sub);
                start = ++end;
            }
        }
        public static Gee.Map<uint8,string> build_escapes(string needles, ...) {
            var subs = va_list();
            var escapes = new Gee.HashMap<uint8, string>();
            foreach (var needle in needles.data) escapes[needle] = subs.arg();
            return escapes;
        }
    }
    public abstract class Template : Object {
        // main method
        public abstract async void exec(Data.Data data, Writer output);
    }

    public class Echo : Template {
        public Bytes text;
        public Echo(Bytes source = EMPTY()) {this.text = source;}
        public override async void exec(Data.Data data, Writer output) {
            yield output.write(text);
        }
    }

    public class Block : Template {
        // Fields are public to help with debugging unbalanced tags.
        public Template[] children;
        public int linenumber;
        public string name; // externally debugging label

        public Block(Template[] children, int line) {
            this.children = children;
            this.linenumber = line;
        }

        public override async void exec(Data.Data data, Writer output) {
            foreach (var child in children) yield child.exec(data, output);
        }
    }

    public class Variable : Template {
        protected Bytes[] path;
        protected Data.Data? literal;
        public Map<uint8,string> escapes; // public so firstOf can apply it.
        private bool force_escapes = false;

        /* Useful global constants to be lazily compiled */
        // Placeholder filter argument when non's specified.
        private static Variable? _nilvar = null;
        private static Variable nilvar {
            get {
                if (_nilvar == null) {
                    _nilvar = new Variable.with(new Data.Empty());
                }
                return _nilvar;
            }
        }
        /* end lazily compiled global constants */

        protected class FilterCall {
            public Filter cb;
            public Variable arg;
            public FilterCall(Filter cb, Variable arg) {
                this.cb = cb; this.arg = arg;
            }
        }
        protected FilterCall[] filters;

        public Variable.from_args(WordIter args, Map<uint8,string> escapes) throws SyntaxError {
            this(args.next(), escapes);
        }

        public Variable.with(Data.Data? d) {
            this.literal = d;
            this.path = new Bytes[0];
            this.escapes = new Gee.HashMap<uint8,string>();
            filters = new FilterCall[0];
        }

        public Variable(Bytes text, Map<uint8,string>? escapes = null) throws SyntaxError {
            var filters = smart_split(text, "|");
            var base_text = filters.next_value();

            switch (base_text[0]) {
            case '"':
            case '\'':
                if (base_text[base_text.length-1] != base_text[0])
                    throw new SyntaxError.UNEXPECTED_CHAR(
                        @"String ($(s(base_text))) has extraneous suffix characters." +
                        @"Starts with $((char) base_text[base_text.length-1]), ends with $((char) base_text[0])");

                this.literal = new Data.Literal(dequote(base_text));
                break;
            case '-': case '0': case '1': case '2': case '3': case '4':
            case '5': case '6': case '7': case '8': case '9':
                double number;
                if (!double.try_parse(s(base_text), out number))
                    throw new SyntaxError.UNEXPECTED_CHAR(
                        @"Number ($(s(base_text))) has extraneous suffix characters");

                this.literal = new Data.Literal(number);
                break;
            default:
                this.path = smart_split(base_text, ".").to_array();
                this.literal = null;
                break;
            }

            var compiled_filters = new ArrayList<FilterCall>();
            var should_escape = true;
            foreach (var filter in filters) {
                var parts = smart_split(filter, ":");
                var name = parts.next();
                var arg_text = parts.next_value();
                parts.assert_end();

                if (filter_lib == null || !filter_lib.has_key(name))
                    throw new SyntaxError.UNKNOWN_FILTER(@"Unknown filter '$(s(name))'");

                Filter cb = filter_lib[name];
                if (cb.should_escape() != null) should_escape = cb.should_escape();
                this.force_escapes = force_escapes || cb.should_escape() != null;

                Variable filter_arg = nilvar;
                if (arg_text != null) filter_arg = new Variable(arg_text, escapes);

                compiled_filters.add(new FilterCall(cb, filter_arg));
            }

            if (should_escape && escapes != null) {
                if (escapes.has_key(0) &&
                        filter_lib.has_key(new Bytes(escapes[0].data))) {
                    var escapeFilter = filter_lib[new Bytes(escapes[0].data)];
                    compiled_filters.add(new FilterCall(escapeFilter, nilvar));
                    this.escapes = new Gee.HashMap<char,string>();
                } else this.escapes = escapes;
            }
            else this.escapes = new Gee.HashMap<char,string>();

            this.filters = compiled_filters.to_array();
        }

        public override async void exec(Data.Data ctx, Writer output) {
            Bytes text;
            if (eval(ctx).show("", out text) && !force_escapes) yield output.write(text);
            else yield output.escaped(text, escapes);
        }

        public Data.Data eval(Data.Data context) {
            var data = context;
            if (literal == null)
                foreach (var property in path) data = data[property];
            else data = literal;

            foreach (var filter in filters)
                data = filter.cb.filter(data, filter.arg.eval(context));

            return data;
        }
    }
}
