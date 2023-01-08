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

/* Defines a number of "Writer" implementations,
        which is our version of a GLib.OutputStream.

    Essentially it works with Bytes instead of arrays
        & does not report IOErrors. */
namespace Prosody {
    /* "Captures" input and later writes it out to a new Bytes object.
        This is useful in templating,
        and when interfacing to APIs that require a Bytes object or similar. */
    public class CaptureWriter : Object, Writer {
        private List<Bytes> data = new List<Bytes>();
        private int length = 0;

        public async void write(Bytes text) {
            data.append(text);
            length += text.length;
        }

        public uint8[] grab(int extra_bytes = 0) {
            var ret = new uint8[length + extra_bytes];
            var builder = ArrayBuilder(ret);
            foreach (var block in data) {
                builder.append(block.get_data());
            }
            return ret;
        }

        public Bytes grab_data() {
            return new Bytes(grab());
        }

        public string grab_string() {
            var ret = grab(1);
            ret[ret.length - 1] = '\0';
            return (string) ret;
        }
    }

    public class StdOutWriter : Object, Writer {
        public async void write(Bytes text) {
            stdout.puts(s(text));
        }
    }
    /* Used when we're calling the template for it's side effects. */
    public class VoidWriter : Object, Writer {
        public async void write(Bytes text) {}
    }

    /* Copies bytes from a Writer into an uint8 array.
        Mainly serves to abstract away the unsafe casts necessary for
            calling Posix.memcpy(). */
    private struct ArrayBuilder {
        unowned uint8[] write_head;
        public ArrayBuilder(uint8[] target) {write_head = target;}

        // NOTE caller should ensure we don't write past the end of the array.
        //      or the program may segfault.
        public void append(uint8[] source) {
            for (int i = 0; i < source.length; i++) write_head[i] = source[i];
            write_head = write_head[source.length:write_head.length];
        }
    }
}
