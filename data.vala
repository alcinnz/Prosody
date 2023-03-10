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

/* Data model for the templating language,
        predominantly accessed via Odysseus.Templating.Variable.

    Can currently work with JSON, and Vala literals. */
namespace Prosody.Data {
    public class Data : Object {
        /* These methods are used in core language syntax */
        public virtual new Data get(Bytes property) {
            Data ret = new Empty();
            foreach_map((key, val) => {
                if (key.compare(property) == 0) {
                    ret = val;
                    return true;
                }
                return false;
            });
            return ret;
        }

        public virtual string to_string() {
            var builder = new StringBuilder();
            builder.append("{");
            @foreach_map((key, val) => {
                var indented = @"$val".replace("\n", "\n\t");
                builder.append(@"\n\t$(s(key)) => $indented");
                return false;
            });
            builder.append("}");
            return builder.str;
        }
        public virtual Bytes to_bytes() {
            return new Bytes(this.to_string().data);
        }
        public virtual bool show(string arg, out Bytes text) {
            text = to_bytes();
            return false; // UNSAFE!
        }

        /* These methods/properties are used by important tags,
            as well as filters. */
        public virtual bool exists {
            get {return to_int() != 0;}
        }

        public delegate bool ForeachMap(Bytes key, Data val);
        public virtual void foreach_map(ForeachMap cb) {
            @foreach((key) => cb(key, this[key]));
        }
        // Possibly easier way to implement foreach_map
        public delegate bool Foreach(Bytes key);
        protected virtual void @foreach(Foreach cb) {
            @foreach_map((key, val) => cb(key));
        }
        // Easier way for template tags to call foreach_map, within their async methods.
        public class KeyValue {
            public Bytes key; public Data val;
            public KeyValue(Bytes key, Data val) {this.key = key; this.val = val;}
        }
        public KeyValue[] to_array() {
            var ret = new Gee.ArrayList<KeyValue>();
            foreach_map((key, val) => {ret.add(new KeyValue(key, val)); return false;});
            return ret.to_array();
        }

        public virtual Gee.SortedSet<string> items() {
            var ret = new Gee.TreeSet<string>();
            ret.add(to_string());
            return ret;
        }

        /* These methods are used by a variety of filters */
        public virtual double to_double() {return (double) to_int(); }
        public virtual int to_int(out bool is_length = null) {
            is_length = false;
            return (int) to_double();
        }
        // Exposes (through a filter) traversal-based query languages
        //        for the particular data format.
        // Defaults to using our Variable syntax.
        public delegate void LookupCallback(Data d);
        public virtual void lookup(string query, LookupCallback cb) {
            foreach_map((key, val) => {
                if (s(key) == query) cb(val);
                val.lookup(query, cb);
                return false;
            });
        }
    }

    // Utility callback-iterator for numeric ranges
    public bool range(Data.Foreach cb, uint end, uint start = 0) {
        for (var index = start; index < end; index++) {
            if (cb(new Bytes("$%u".printf(index).data))) return true;
        }
        return false;
    }

    public class Empty : Data {
        public override Data get(Bytes _) {return this;}
        public override string to_string() {return "";}
        public override void foreach_map(Data.ForeachMap cb) {}
        public override int to_int(out bool is_length = null) {
            is_length = false; return 0;
        }
        public override Gee.SortedSet<string> items() {return new Gee.TreeSet<string>();}
    }

    public class Literal : Data {
        public Value data;
        public Literal(Value v) {this.data = v;}

        public override void foreach_map(Data.ForeachMap cb) {
            if (data.holds(typeof(int)) || data.holds(typeof(double))) {
                var to = to_int();
                for (var i = 0; i < to; i++) if (cb(EMPTY(), new Literal(i))) break;
                return;
            }
            var text = to_string();

            int index = 0;
            uint unichar_count = 0;
            unichar c;
            while (text.get_next_char(ref index, out c)) {
                var key = "$%u".printf(unichar_count++);
                if (cb(new Bytes(key.data), new Literal(c))) break;
            }
        }

        public override string to_string() {
            if (data.holds(typeof(double))) {
                // Obtain better formatter
                char[] buf = new char[double.DTOSTR_BUF_SIZE];
                return ((double) data).to_str(buf);
            } else if (data.holds(typeof(unichar))) {
                return ((unichar) data).to_string();
            } else if (data.holds(typeof(char))) {
                return ((char) data).to_string();
            }

            Value ret = Value(typeof(string));
            if (data.transform(ref ret)) return ret.dup_string();
            else return "";
        }

        public override int to_int(out bool is_length = null) {
            is_length = false;
            if (data.holds(typeof(string))) return int.parse((string) data);

            Value ret = Value(typeof(int));
            if (data.transform(ref ret)) return ret.get_int();
            else return 0;
        }

        public override double to_double() {
            if (data.holds(typeof(string))) return double.parse((string) data);

            Value ret = Value(typeof(double));
            if (data.transform(ref ret)) return (double) ret;
            else return 0.0;
        }

        public override bool exists {
            get {
                if (data.holds(typeof(string))) {
                    return ((string) data).length > 0;
                } if (data.holds(typeof(double)) || data.holds(typeof(int))) {
                    return to_double() != 0;
                } else {
                    Value ret = Value(typeof(bool));
                    if (data.transform(ref ret)) return (bool) ret;
                    else return true; // Exists simply by being there
                }
            }
        }

        public override void lookup(string query, Data.LookupCallback cb) {/* pass */}
    }

    public class Substr : Data {
        Bytes data;
        bool safe;
        public Substr(Bytes b, bool safe = false) {this.data = b; this.safe = safe;}

        public override void foreach_map(Data.ForeachMap cb) {
            var text = to_string();

            int index = 0;
            uint char_count = 0;
            unichar c;
            while (text.get_next_char(ref index, out c)) {
                if (index > data.length) {
                    warning("Unicode validation error!");
                    return;
                }
                var key = "$%u".printf(char_count++);
                if (cb(new Bytes(key.data), new Literal(c))) break;
            }
        }

        public override string to_string() {return s(data);}
        public override Bytes to_bytes() {return data;}
        public override bool show(string _, out Bytes output) {
            output = data; return safe;
        }
        public override bool exists {get {return data.length > 0;}}

        public override int to_int(out bool is_length = null) {
            is_length = false;
            return int.parse(to_string());
        }

        public override double to_double() {return double.parse(to_string());}
    }

    public class Mapping : Data {
        public Gee.Map<Bytes, Data> data;
        public string? text;
        public Mapping(Gee.Map<Bytes, Data>? m = null, string? s = "") {
            if (m != null) this.data = m;
            else this.data = create_bytes_map();
            this.text = s;
        }

        public override Data get(Bytes property) {
            if (data.has_key(property)) return data[property];
            else return new Empty();
        }
        public new void set(string property, Data val) {
            data[new Bytes(property.data)] = val;
        }
        public override void foreach_map(Data.ForeachMap cb) {
            data.map_iterator().@foreach((k, v) => !cb(k, v));
        }

        public override string to_string() {return text == null ? "" : text;}
        public override int to_int(out bool is_length = null) {
            is_length = true; return data.size;
        }
    }

    public class List : Data {
        private Data[] inner;
        public List(Gee.List<Data> inner) {this.inner = inner.to_array();}
        public List.from_array(Data[] inner) {this.inner = inner;}

        public override string to_string() {
            // This semantic is mostly useful for query parameters, as it nicely coerces between lists and arrays.
            return inner[0].to_string();
        }
        public override Gee.SortedSet<string> items() {
            var ret = new Gee.TreeSet<string>();
            foreach (var item in inner) ret.add(item.to_string());
            return ret;
        }
        public override void foreach_map(Data.ForeachMap cb) {
            var index = 0;
            foreach (var item in inner)
                if (cb(new Bytes("$%i".printf(index++).data), item)) break;
        }
        public override Data get(Bytes property_bytes) {
            var property = s(property_bytes);
            uint64 index = 0;
            if (property[0] == '$' &&
                    uint64.try_parse(property[1:property.length], out index) &&
                    index < inner.length) {
                return inner[index];
            }
            return new Empty();
        }
        public override int to_int(out bool is_length = null) {
            is_length = true;
            return inner.length;
        }
    }

    public class Stack : Data {
        Data first;
        Data last;
        public Stack(Data first, Data last) {
            this.first = first; this.last = last;
        }

        public Stack.with_map(Data fallback, Gee.Map<Bytes, Data> top) {
            this(new Mapping(top), fallback);
        }

        public override Data get(Bytes property) {
            var val = first[property];
            if (val is Empty) return last[property];
            else return val;
        }

        public override string to_string() {return "";}
        public override bool exists {get {return first.exists || last.exists;}}

        public override void foreach_map(Data.ForeachMap cb) {
            var exit = false;
            first.foreach_map((key, val) => {
                return exit = cb(key, val);
            });
            if (exit) return;
            last.foreach_map(cb);
        }

        public override int to_int(out bool is_length = null) {
            warning("Trying to convert a stack to an int. " +
                    "This may not give the results you expect.");
            is_length = true; // Won't get a better answer???
            return 0;
        }
    }

    public class Lazy : Data {
        Data ctx;
        Gee.Map<Bytes,Variable> vars;
        Gee.Map<Bytes,Data> evaluated;
        public Lazy(Gee.Map<Bytes,Variable> variables, Data context) {
            this.ctx = context;
            this.vars = variables;
            this.evaluated = new Gee.HashMap<Bytes, Data>();
        }

        public override Data get(Bytes property) {
            if (evaluated.has_key(property)) return evaluated[property];
            if (vars.has_key(property)) {
                evaluated[property] = vars[property].eval(ctx);
                return evaluated[property];
            }
            return ctx[property];
        }

        public override string to_string() {return "";}
        public override bool exists {get {return true;}}
        public override int to_int(out bool is_length = null) {
            is_length = true; // Won't get a better answer???
            return 0;
        }

        public override void @foreach(Data.Foreach cb) {
            var lazy_keys = vars.keys;
            lazy_keys.add_all(evaluated.keys);

            var exit = false;
            ctx.@foreach((key) => {
                if (key in lazy_keys) return false;
                return exit = cb(key);
            });
            if (exit) return;

            foreach (var key in lazy_keys)
                if (cb(key)) break;
        }
    }

    public class Let : Data {
        private Bytes key;
        private Data val;
        private Data fallback;

        private Let() {}
        public static Data build(Bytes? key, Data val, Data fallback = new Empty()) {
            if (key == null || key.length == 0) return fallback;

            var self = new Let();
            self.key = key; self.val = val; self.fallback = fallback;
            return self;
        }
        public static Data builds(string key, Data val, Data fallback = new Empty()) {
            return build(new Bytes(key.data), val, fallback);
        }

        public override Data get(Bytes index) {
            if (index.compare(key) == 0) return val;
            else return fallback[index];
        }

        public override string to_string() {return @"$fallback";}
        public override bool exists {get {return true;}}
        public override int to_int(out bool is_length = null) {
            return fallback.to_int(out is_length);
        }
        public override void @foreach(Data.Foreach cb) {
            if (!cb(key)) fallback.@foreach(cb);
        }
    }
}
