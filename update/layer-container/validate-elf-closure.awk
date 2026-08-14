# Validate that every direct ELF DT_NEEDED edge resolves inside the target root.
#
# Input 1 contains one absolute runtime library directory per line. Input 2 is
# the scanelf report for regular ELF files. Input 3 contains virtual symlink
# path/target pairs. The provider index is keyed by virtual path and ELF ABI so
# no target binary has to be executed.

BEGIN {
	FS = "|"
}

function trim(value)
{
	gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
	return value
}

function normalize_osabi(value)
{
	value = trim(value)
	if (value == "GNU" || value == "LINUX" || value == "SYSV")
		return "NONE"
	return value
}

function normalize_path(path, count, parts, stack, depth, position, result)
{
	gsub(/\/+/, "/", path)
	if (substr(path, 1, 1) != "/")
		return path

	count = split(path, parts, "/")
	depth = 0
	for (position = 1; position <= count; position++) {
		if (parts[position] == "" || parts[position] == ".")
			continue
		if (parts[position] == "..") {
			if (depth > 0)
				depth--
			continue
		}
		stack[++depth] = parts[position]
	}
	result = "/"
	for (position = 1; position <= depth; position++)
		result = result (position == 1 ? "" : "/") stack[position]
	return result
}

function parent_directory(path)
{
	sub(/\/[^\/]*$/, "", path)
	return path == "" ? "/" : path
}

function resolve_virtual_path(path, iteration, count, parts, position, prefix, rest)
{
	path = normalize_path(path)
	for (iteration = 1; iteration <= 40; iteration++) {
		count = split(path, parts, "/")
		prefix = ""
		for (position = 2; position <= count; position++) {
			prefix = prefix "/" parts[position]
			if (!(prefix in link_target))
				continue
			rest = substr(path, length(prefix) + 1)
			path = normalize_path(link_target[prefix] rest)
			break
		}
		if (position > count)
			return path
	}
	return ""
}

function platform_for(machine)
{
	if (machine == "EM_X86_64")
		return "x86_64"
	if (machine == "EM_386")
		return "i686"
	if (machine == "EM_AARCH64")
		return "aarch64"
	return ""
}

function expand_dynamic_tokens(path, origin, class, machine, library, platform)
{
	library = class == "ELFCLASS64" ? "lib64" : "lib"
	platform = platform_for(machine)
	gsub(/\$\{ORIGIN\}|\$ORIGIN/, origin, path)
	gsub(/\$\{LIB\}|\$LIB/, library, path)
	gsub(/\$\{PLATFORM\}|\$PLATFORM/, platform, path)
	return path
}

function compatible_provider(path, specification, resolved)
{
	resolved = resolve_virtual_path(path)
	return resolved != "" && ((resolved SUBSEP specification) in provider)
}

function basename(path)
{
	sub(/^.*\//, "", path)
	return path
}

function is_public_runtime_elf(path, directory, position)
{
	if (path ~ "^/(bin|sbin|usr/bin|usr/sbin|usr/libexec)/")
		return 1
	directory = parent_directory(path)
	for (position = 1; position <= global_directory_count; position++)
		if (directory == global_directories[position])
			return 1
	return 0
}

function add_search_directory(directory)
{
	directory = normalize_path(directory)
	if (directory == "" || directory in current_directory_seen)
		return
	current_directory_seen[directory] = 1
	current_directories[++current_directory_count] = directory
}

function dependency_resolves(file, dependency, rpath, specification,
	class, machine, origin, count, entries, position, directory, candidate)
{
	delete current_directory_seen
	delete current_directories
	current_directory_count = 0

	if (index(dependency, "/") != 0) {
		if (substr(dependency, 1, 1) != "/")
			return -1
		return compatible_provider(normalize_path(dependency), specification)
	}

	origin = parent_directory(file)
	rpath = trim(rpath)
	if (rpath != "" && rpath != "-") {
		count = split(rpath, entries, ":")
		for (position = 1; position <= count; position++) {
			directory = expand_dynamic_tokens(entries[position],
				origin, class, machine)
			if (directory == "" ||
				substr(directory, 1, 1) != "/")
				return -1
			if (index(directory, "$") != 0)
				return -1
			add_search_directory(directory)
		}
	}
	for (position = 1; position <= global_directory_count; position++)
		add_search_directory(global_directories[position])

	for (position = 1; position <= current_directory_count; position++) {
		candidate = normalize_path(current_directories[position] \
			"/" dependency)
		if (compatible_provider(candidate, specification))
			return 1
	}
	return 0
}

FILENAME == directory_file {
	directory = trim($0)
	if (directory != "")
		global_directories[++global_directory_count] = \
			normalize_path(directory)
	next
}

FILENAME == link_file {
	if (NF != 2) {
		if (!failed)
			print "error: malformed FHS symlink report" \
				>"/dev/stderr"
		failed = 1
		next
	}
	path = $1
	target = $2
	if (substr(path, 1, length(root)) == root)
		path = substr(path, length(root) + 1)
	path = normalize_path(path)
	if (substr(target, 1, 1) == "/")
		link_target[path] = normalize_path(target)
	else
		link_target[path] = normalize_path(parent_directory(path) \
			"/" target)
	next
}

{
	if (NF != 9) {
		if (!failed)
			print "error: malformed scanelf report" >"/dev/stderr"
		failed = 1
		next
	}
	path = $1
	if (substr(path, 1, length(root)) == root)
		path = substr(path, length(root) + 1)
	path = normalize_path(path)
	class = trim($2)
	machine = trim($3)
	endian = trim($4)
	osabi = normalize_osabi($5)
	specification = class "/" machine "/" endian "/" osabi

	provider[path SUBSEP specification] = 1
	provider_name[basename(path) SUBSEP specification] = 1
	soname = trim($6)
	if (soname != "")
		provider_name[soname SUBSEP specification] = 1
	elf_count++
	elf_path[elf_count] = path
	elf_class[elf_count] = class
	elf_machine[elf_count] = machine
	elf_specification[elf_count] = specification
	elf_needed[elf_count] = trim($7)
	elf_rpath[elf_count] = trim($8)
}

END {
	for (record = 1; record <= elf_count; record++) {
		if (elf_needed[record] == "")
			continue
		needed_count = split(elf_needed[record], dependencies, ",")
		for (needed_index = 1;
			needed_index <= needed_count;
			needed_index++) {
			dependency = trim(dependencies[needed_index])
			if (dependency == "")
				continue
			result = dependency_resolves(elf_path[record],
				dependency,
				elf_rpath[record],
				elf_specification[record],
				elf_class[record],
				elf_machine[record])
			if (result == 1)
				continue
			if (result == 0 &&
				!is_public_runtime_elf(elf_path[record]) &&
				((dependency SUBSEP \
					elf_specification[record]) in provider_name))
				continue
			failed = 1
			missing_count++
			if (missing_count > 100)
				continue
			if (result == -1) {
				print "error: ELF dependency uses a non-deterministic " \
					"path: " elf_path[record] " -> " dependency \
					>"/dev/stderr"
			} else {
				print "error: ELF dependency is missing from the " \
					"FHS closure: " elf_path[record] " -> " \
					dependency " [" \
					elf_specification[record] "]" \
					>"/dev/stderr"
			}
		}
	}
	if (missing_count > 100)
		print "error: additional unresolved ELF dependencies: " \
			missing_count - 100 >"/dev/stderr"
	exit failed ? 1 : 0
}
