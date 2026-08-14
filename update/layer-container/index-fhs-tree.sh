#!/bin/sh

set -eu

test "$#" -eq 3
root=$1
target=$2
output=$3

forbidden_runtime_reference()
{
	candidate=$1
	case $candidate in
		*nix/store* | \
			*/.volatoo/state/volatoo/system/objects/sha256* | \
			*/state/volatoo/system/objects/sha256* | \
			*/volatoo/system/objects/sha256* | \
			*/parent/root/* | \
			*/workspace/* | \
			*/inputs/* | \
			*/output/* | \
			*/store/* | \
			*/work/update/*)
			return 0
			;;
	esac
	return 1
}

case $target in
	*[!abcdefghijklmnopqrstuvwxyz0123456789._+/-]* | *//* | /* | */)
		echo "error: invalid Volatoo target ID: $target" >&2
		exit 1
		;;
esac
if [ -L "$root" ] || [ ! -d "$root" ]; then
	echo "error: FHS index root is missing or unsafe: $root" >&2
	exit 1
fi
case $output in
	/*) ;;
	*) echo "error: FHS index output must be absolute" >&2; exit 1 ;;
esac
if [ -e "$output" ] || [ -L "$output" ]; then
	echo "error: FHS index output already exists: $output" >&2
	exit 1
fi
root=$(cd "$root" && pwd -P)
temporary=$(mktemp -d)
cleanup()
{
	rm -rf "$temporary"
}
trap cleanup EXIT HUP INT TERM

unsafe_path=$(find "$root" \( -name '*|*' -o -name '*
*' \) -print -quit)
if [ -n "$unsafe_path" ]; then
	echo "error: FHS index path cannot be represented safely: ${unsafe_path#"$root"}" >&2
	exit 1
fi

records=$temporary/records
: >"$records"
find "$root" -printf '%P|%y|%m\n' |
	awk -F '|' '
		NF != 3 { exit 1 }
		{
			path = $1 == "" ? "/" : "/" $1
			print "P|" path "|" $2 "|" $3
		}
	' >>"$records"

links=$temporary/links
find "$root" -type l -printf '%P|%l\n' >"$links"
while IFS='|' read -r path link_target; do
	case $link_target in
		*'|'* | *'
'*)
			echo "error: FHS closure symlink cannot be represented safely: /$path" >&2
			exit 1
			;;
	esac
	if forbidden_runtime_reference "$link_target"; then
		echo "error: FHS closure symlink leaks a build/store path: /$path -> $link_target" >&2
		exit 1
	fi
	printf 'L|/%s|%s\n' "$path" "$link_target" >>"$records"
done <"$links"

shebangs=$temporary/shebangs
find "$root" -type f -perm /111 \
	-exec awk '
		FNR == 1 {
			if (substr($0, 1, 2) == "#!")
				print FILENAME
			nextfile
		}
	' {} + >"$shebangs"
while IFS= read -r file; do
	IFS= read -r line <"$file" || true
	shebang=${line#\#!}
	set -f
	# Intentional splitting follows the kernel shebang token grammar.
	# shellcheck disable=SC2086
	set -- $shebang
	set +f
	if [ "$#" -lt 1 ]; then
		echo "error: empty shebang in FHS closure: ${file#"$root"}" >&2
		exit 1
	fi
	interpreter=$1
	case $interpreter in
		/*) ;;
		*)
			echo "error: non-absolute shebang in FHS closure: ${file#"$root"}" >&2
			exit 1
			;;
	esac
	case $interpreter in
		*'|'* | *'
'*)
			echo "error: FHS shebang cannot be represented safely: ${file#"$root"}" >&2
			exit 1
			;;
	esac
	if forbidden_runtime_reference "$interpreter"; then
		echo "error: FHS closure shebang leaks a build/store path: ${file#"$root"}" >&2
		exit 1
	fi
	printf 'S|%s|%s\n' "${file#"$root"}" "$interpreter" >>"$records"
done <"$shebangs"

forbidden_file=$temporary/forbidden-references
printf '%s\n' \
	/nix/store/ \
	/.volatoo/state/volatoo/system/objects/sha256/ \
	/state/volatoo/system/objects/sha256/ \
	/volatoo/system/objects/sha256/ \
	/parent/root/ \
	/workspace/ \
	/inputs/ \
	/output/ \
	/store/ \
	/work/update/ >"$forbidden_file"
for scan_path in \
	/etc \
	/usr/lib/systemd \
	/usr/lib/tmpfiles.d \
	/usr/lib/sysusers.d \
	/usr/share/applications \
	/usr/share/dbus-1
do
	if [ ! -d "$root$scan_path" ]; then
		continue
	fi
	match=$(
		find "$root$scan_path" -type f \
			-exec grep -l -F -f "$forbidden_file" {} + 2>/dev/null |
			sed -n '1p'
	)
	if [ -n "$match" ]; then
		echo "error: FHS runtime metadata leaks a build/store path: ${match#"$root"}" >&2
		exit 1
	fi
done

elf_report=$temporary/elf
scanelf -RBC -F '%F|%M|%a|%D|%I|%S|%n|%r|%i' "$root" >"$elf_report"
while IFS='|' read -r \
	file _class _machine _endian _osabi _soname _needed rpath interpreter
do
	interpreter=$(printf '%s' "$interpreter" | tr -d '[:space:]')
	rpath=$(printf '%s' "$rpath" | tr -d '[:space:]')
	if [ "$interpreter" = - ]; then interpreter=; fi
	if [ "$rpath" = - ]; then rpath=; fi
	if [ -n "$interpreter" ]; then
		case $interpreter in
			/*) ;;
			*) echo "error: ELF interpreter is not absolute: ${file#"$root"}" >&2; exit 1 ;;
		esac
		if forbidden_runtime_reference "$interpreter"; then
			echo "error: ELF interpreter leaks a build/store path: ${file#"$root"}" >&2
			exit 1
		fi
		case $target:$interpreter in
			*/glibc/*:*ld-musl*)
				echo "error: glibc target contains a musl ELF interpreter: ${file#"$root"}" >&2
				exit 1
				;;
		esac
	fi
	if [ -n "$rpath" ] && forbidden_runtime_reference "$rpath"; then
		echo "error: ELF RPATH/RUNPATH leaks a build/store path: ${file#"$root"}" >&2
		exit 1
	fi
done <"$elf_report"
awk -F '|' -v root="$root" '
	BEGIN { OFS = "|" }
	NF != 9 { exit 1 }
	{
		$1 = substr($1, length(root) + 1)
		print "E|" $0
	}
' "$elf_report" >>"$records"

for loader_configuration in \
	"$root/etc/ld.so.conf" \
	"$root"/etc/ld.so.conf.d/*.conf
do
	if [ ! -f "$loader_configuration" ] || [ -L "$loader_configuration" ]; then
		continue
	fi
	loader_relative=${loader_configuration#"$root"}
	awk -v path="$loader_relative" '
		{
			sub(/[[:space:]]*#.*/, "")
			gsub(/^[[:space:]]+|[[:space:]]+$/, "")
		}
		$0 == "" || $1 == "include" { next }
		substr($0, 1, 1) != "/" {
			print "error: relative directory in dynamic loader config: " $0 >"/dev/stderr"
			failed = 1
			next
		}
		index($0, "|") != 0 {
			print "error: loader directory cannot be represented safely: " $0 >"/dev/stderr"
			failed = 1
			next
		}
		{ print "C|" path "|" $0 }
		END { exit failed ? 1 : 0 }
	' "$loader_configuration" >>"$records"
done

{
	printf 'VOLATOO_FHS_ELF_INDEX_V1\n'
	printf 'target %s\n' "$target"
	LC_ALL=C sort -u "$records"
	printf 'end\n'
} >"$output.tmp"
mv "$output.tmp" "$output"
