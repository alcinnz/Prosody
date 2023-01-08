/**
* This file is part of Prosody Web Browser (Copyright Adrian Cochrane 2017, 2023).
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

/** A datasource to expose JSON data to templates.

This is particularly vital for running the test suite. */
namespace Prosody.xJSON {
    using Data;

    public Data.Data parse_file(string filepath) throws Error {
        var parser = new Json.Parser();
        parser.load_from_file(filepath);
        return build(parser.get_root());
    }
    public Data.Data parse(string data) throws Error {
        var parser = new Json.Parser();
        parser.load_from_data(data);
        return build(parser.get_root());
    }

    public Data.Data build(Json.Node? node) {
        if (node == null) return new Empty();
        switch (node.get_node_type()) {
        case Json.NodeType.OBJECT:
            return new Object(node.dup_object());
        case Json.NodeType.ARRAY:
            return new Array(node.dup_array());
        case Json.NodeType.VALUE:
            return new Literal(node.get_value());
        case Json.NodeType.NULL:
            return new Empty();
        default:
            return new Empty();
        }
    }

    private class Array : Data.Data {
        Json.Array inner;
        public Array(Json.Array a) {this.inner = a;}

        public override Data.Data get(Bytes property_bytes) {
            var property = s(property_bytes);
            uint64 index = 0;
            if (property[0] == '$' &&
                    uint64.try_parse(property[1:property.length], out index) &&
                    index < inner.get_length()) {
                return build(inner.get_element((uint) index));
            }
            return new Empty();
        }

        public override void @foreach(Data.Data.Foreach cb) {
            range(cb, inner.get_length());
        }

        public override Gee.SortedSet<string> items() {
            var ret = new Gee.TreeSet<string>();
            for (uint i = 0; i < inner.get_length(); i++) {
                if (inner.get_string_element(i) != null)
                    ret.add(inner.get_string_element(i));
            }
            return ret;
        }

        public override int to_int(out bool is_length = null) {
            is_length = true;
            return (int) inner.get_length();
        }
    }

    private class Object : Data.Data {
        Json.Object inner;
        public Object(Json.Object o) {this.inner = o;}

        public override Data.Data get(Bytes property) {
            return build(inner.dup_member(s(property)));
        }

        public override void @foreach(Data.Data.Foreach cb) {
            foreach (var key in inner.get_members())
                if (cb(new Bytes(key.data))) break;
        }

        public override int to_int(out bool is_length = null) {
            is_length = true;
            return (int) inner.get_size();
        }
    }
}
