# Gentoo and FHS compatibility

Status: `org.volatoo.gentoo-fhs/v1` is enforced before realization.

## Decision

Volatoo adopts NixOS-style immutable closures, generations, atomic selection
and rollback at the **whole-system boundary**. It does not adopt a package
runtime layout such as `/nix/store/<hash>-package`.

Portage installs ordinary ebuilds into an isolated root with `EROOT=/`.
Packages therefore retain the paths expected by Gentoo and upstream software:
`/usr`, `/etc`, `/var`, `/bin`, `/sbin` and the normal dynamic loader paths.
The resulting complete FHS tree is the immutable object. The
content-addressed Volatoo store is a publication mechanism and is never a
runtime prefix.

This boundary avoids patching every ebuild, rewriting shebangs, manufacturing
wrappers, or changing plugin and service discovery merely to gain atomic
updates.

## Runtime layout

```text
verified binpkgs
    └─ binary-only Portage install into a private FHS root
         └─ complete Gentoo FHS closure (read-only SquashFS)
              ├─ tmpfs OverlayFS upper for disposable writes
              └─ explicit persistence policies for selected mutable paths
```

`/etc`, `/var` and other conventional paths remain visible to applications.
Their runtime writability comes from the disposable upper or an explicit
persistence policy, not from relocating package payloads.

## Version 1 gate

`update/layer-container/validate-fhs.sh` validates a complete materialized tree
for compaction and release images. The extracted final SquashFS must then have
the same complete tree digest, including contents, inode types, links,
permissions, ownership, ACLs and xattrs. Ordinary exact incremental
descendants instead validate their authenticated parent index plus new-layer
delta and bind the result in receipt-v3 compositional tree state. A closure
must:

- contain the core `/etc`, `/usr` and `/var` hierarchy, Portage configuration
  and VDB, `/bin/sh`, and the init implementation selected by the hard target;
- keep executable shebang interpreters inside the closure;
- keep ELF interpreters inside the closure and reject a musl interpreter for a
  glibc target;
- resolve every ELF `DT_NEEDED` edge to an ABI-compatible provider inside the
  closure without executing target binaries. Public entry points and libraries
  must resolve through their RPATH/RUNPATH or the target dynamic-loader search
  paths; private toolchain objects may use a package wrapper environment, but
  their matching provider must still be present in the same closure;
- reject RPATH, RUNPATH, symlink and runtime-metadata references to
  `/nix/store`, the Volatoo CAS, or private build mountpoints;
- reject files or links left below reserved staging paths such as `/work`,
  `/store`, `/inputs` and `/workspace`.

Empty reserved directory skeletons are harmless and accepted. Catalyst clears
`/work` before release packaging so newly built images do not retain even its
cache directory structure.

Gentoo packages commonly install dormant OpenRC scripts on a systemd target.
Version 1 permits `/etc/init.d/*` and `/etc/user/init.d/*` to retain the
`/sbin/openrc-run` shebang when OpenRC is not installed; systemd never executes
those files. No general missing-interpreter exception exists.

Successful realization records `org.volatoo.gentoo-fhs/v1` in its immutable
realization plan and exposes it at `/.volatoo/fhs-contract` after boot. Older
realization plans remain readable but do not claim this contract.

The dependency check constructs one index from `scanelf` metadata and the
target-root symlink graph. It understands ELF class, machine, endianness,
OSABI, `$ORIGIN`, `$LIB`, `$PLATFORM`, `/etc/ld.so.conf`, and standard
multilib directories. It does not call `ldd` or run any target executable.

## Non-goals

- Package-specific hashed runtime prefixes.
- Per-package wrapper generation or global RPATH rewriting.
- Pretending all of FHS is persistent or writable storage.
- Treating the mutable live root as a Portage build input.

Future contract revisions may add wider desktop/plugin discovery checks.
Those checks must validate ordinary Gentoo semantics rather than create a
parallel package layout.
