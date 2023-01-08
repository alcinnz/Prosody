using Prosody;

int main(string[] args) {
	if (args.length > 3 || args.length < 2) {
		stderr.printf("USAGE: %s TEMPLATEFILE [JSONFILE]\n", args[0]);
		return 1;
	}

	Std.register_standard_library();
	try {
		var parser = new Parser(File.new_for_commandline_arg(args[1]).load_bytes());
		parser.path = args[1];
		var template = parser.parse();
		var data = args.length == 3 ? xJSON.parse_file(args[2]) : new Data.Empty();

		var loop = new MainLoop();
		template.exec.begin(data, new StdOutWriter(), (obj, res) => loop.quit());
		loop.run();
	} catch (Error e) {error(e.message);}

	return 0;
}
