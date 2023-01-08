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

/** Cached loading for templates. */
namespace Prosody {
    private Gee.Map<string, Template>? template_cache = null;
    private Gee.ArrayList<string>? cached_keys; // Decides what template to free
    private const int CACHE_SIZE = 8;

    public Template get_for_resource(string resource, ref ErrorData? error_data)
            throws SyntaxError, Error {
        if (template_cache == null) template_cache = new Gee.HashMap<string, Template>();
        if (cached_keys == null) {
            var array = new string[CACHE_SIZE];
            cached_keys = new Gee.ArrayList<string>.wrap(array);
        }

        if (!template_cache.has_key(resource)) {
            if (cached_keys.size >= CACHE_SIZE) {
                // cap number of templates
                template_cache.unset(cached_keys[CACHE_SIZE - 1]);
                cached_keys.remove_at(CACHE_SIZE - 1);
            }

            if (!lib_initialized()) Std.register_standard_library();
            var bytes = resources_lookup_data(resource, 0);
            var parser = new Parser(bytes, resource);
            // Override {% include %} to operate on cache resources, recursing into this function.
            parser.local_tag_lib[new Bytes("include".data)] = new ResourceIncludeBuilder();

            try {
                template_cache[resource] = parser.parse();
                cached_keys.insert(0, resource);
            } catch (SyntaxError err) {
                int line_number; int line_offset; int err_start; int err_end;
                parser.get_current_token(out line_number, out line_offset,
                                        out err_start, out err_end);
                error_data = new ErrorData(err, line_number, line_offset, 
                                        err_start, err_end, bytes);
                throw err;
            }
        } else {
            // Move recently used items to the front so they don't get culled.
            cached_keys.remove(resource);
            cached_keys.insert(0, resource);
        }

        return template_cache[resource];
    }

    public class ErrorData : Data.Mapping {
        public TagBuilder tag;
        public string[] error_types = {"Unclosed String",
                "Unexpected End Of File", "Unexpected Character",
                "Unknown Tag", "Unknown Filter",
                "Invalid Arguments for Tag", "Unclosed Block Tag"};
        public ErrorData(SyntaxError err, int line_number, int line_offset,
                int error_start, int error_end, Bytes source) throws SyntaxError {
            data[new Bytes("err-code".data)] = new Data.Literal(error_types[err.code]);
            data[new Bytes("err-text".data)] = new Data.Literal(err.message);

            var err_token = source[error_start:error_end];
            if (Token.get_type(err_token) == TokenType.TAG) {
                var err_tag = new Data.Substr(Token.get_args(err_token).next());
                data[new Bytes("err-tag".data)] = err_tag;
            }

            data[new Bytes("line-number".data)] = new Data.Literal(line_number);

            var tag = new ErrorTag(line_offset, error_start, error_end, source);
            this.tag = new ErrorTagBuilder(tag);
        }
    }

    private class ErrorTagBuilder : Object, TagBuilder {
        private ErrorTag tag;
        public ErrorTagBuilder(ErrorTag tag) {this.tag = tag;}
        public Template? build(Parser parser, WordIter args) throws SyntaxError {
            args.assert_end();
            return tag;
        }
    }

    private class ErrorTag : Template {
        private int line_start;
        private int line_end;
        private int err_start;
        private int err_end;
        private Bytes source;

        public ErrorTag(int line_offset, int error_start, int error_end, Bytes source) {
            this.line_start = line_offset;
            this.line_end = line_offset + 1;
            var str = s(source);
            this.line_end = str.index_of("\n", this.line_end);
            while (this.line_end <= error_start) {
                this.line_start = line_end;
                this.line_end = this.line_start + 1;
                this.line_end = str.index_of("\n", this.line_end);
            }
            this.err_start = error_start - line_start;
            this.err_end = int.min(error_end, line_end) - line_start;
            this.source = source;
        }

        public override async void exec(Data.Data ctx, Writer stream) {
            // Utilize diff rendering for this. 
            var err_ranges = new Gee.ArrayList<xDiff.Duo>();
            err_ranges.add(new xDiff.Duo(err_start, err_end));
            yield xDiff.render_ranges(source[line_start:line_end], err_ranges, "strong", stream);
        }
    }

    private class ResourceIncludeBuilder : TagBuilder, Object {
        public Template? build(Parser parser, WordIter args) throws SyntaxError {
            var variables = new Gee.ArrayList<Variable>();
            foreach (var arg in args) variables.add(new Variable(arg));

            return new ResourceIncludeTag(variables.to_array(), parser.path);
        }
    }
    private class ResourceIncludeTag : Template {
        private Variable[] vars;
        private string @base;
        public ResourceIncludeTag(Variable[] vars, string @base) {
            this.vars = vars; this.@base = @base;
        }

        public override async void exec(Data.Data ctx, Writer output) {
            // 1. Resolve path
            var relative = new StringBuilder();
            foreach (var variable in vars) relative.append(variable.eval(ctx).to_string());
            var basepath = File.new_for_path(this.@base).get_parent();
            var absolute = basepath.resolve_relative_path(relative.str);

            // 2. Render that template. This benefits heavily from caching.
            ErrorData? error_data = null;
            try {
                yield get_for_resource(absolute.get_path(), ref error_data)
                        .exec(ctx, output);
            } catch (Error err) {
                yield output.writes(@"<p style='color: red;'>$(err.message)</p>");
            }
        }
    }
}
