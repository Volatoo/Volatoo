# Release trust and realization signatures

Status: realization-plan signing and the Secure Boot outer anchor are
implemented; the real Portage Engine release Gate remains pending.

## Trust statement

Content addressing detects a mismatch between an object and its name.
dm-verity authenticates root filesystem blocks against root hashes in a
realization plan. Neither mechanism proves that the plan was published by
Volatoo: an attacker able to replace the state filesystem could otherwise
replace the plan, root hash, SquashFS and hash tree together.

Volatoo release mode therefore verifies an Ed25519 signature over the exact
content-addressed realization-plan bytes before parsing any root hashes from
that plan. The trusted public keys are embedded in the initramfs. A private
release key is never stored in the image, initramfs or target state
filesystem.

This creates the following chain:

```text
trusted public key in initramfs
  -> OpenBSD signify signature
  -> exact realization plan
  -> generation + boot plan + target + build context
  -> ordered runtime image records
  -> dm-verity root hashes and geometry
  -> base/layer SquashFS data and hash-tree blocks
```

The release-media builder can authenticate the initramfs with a signed UKI and
Secure Boot. Without selecting and enrolling that outer anchor, an attacker
who can replace both the initramfs and state can also replace the embedded
public key.

## Storage contract

Signatures use the detached OpenBSD `signify` format. For realization
`sha256:R` and the SHA-256 digest `K` of the exact public-key file, the
signature is stored as:

```text
/volatoo/system/signatures/R/K.sig
```

The signed message is the exact object at `/volatoo/system/objects/sha256/R`.
The directory may contain signatures from more than one trusted key so a
release can overlap old and new keys during rotation. A signature filename is
only an index; successful cryptographic verification with the correspondingly
named embedded public key is authoritative.

Signatures are published after the realization object and before activation.
The private updater view provides the same atomic write and locking boundary
used by other generation metadata. Garbage collection retains signature
directories for reachable realization objects and removes unreachable ones.

The recommended production sequence keeps the protected secret key on an
isolated signing host. The builder publishes but does not activate the
realization; the prepared state is attached to the signer, which runs
`volatoo-generation sign-realization` and verifies the result with the public
key before compare-and-swap activation. The Docker realizer also offers a
network-disabled signing step for reproducible CI and lab fixtures, but it is
not a reason to copy a production key onto a build machine.

## Policy and rollback

Release initramfs images use `required`: a generation must have a realized
closure or image stack and at least one valid signature from an embedded key. A missing
verifier, missing key, missing signature, wrong key or changed plan rejects
that generation. Automatic selection may then try `previous`, which must pass
the same policy.

`allow-unsigned` is an explicit development and legacy-recovery policy. It
allows an unsigned realization and legacy layer plan, emits a warning and
does not claim release authenticity. It is a complete security downgrade:
an attacker able to edit state can remove a signature and obtain the same
unsigned behavior.

Signed rollback remains intentional. A user may select any older realization
that still has a valid release signature. Preventing replay of an old but
legitimately signed release requires a separately protected monotonic version
in TPM or authenticated UEFI state and is not part of this contract.

## Validated Gate

The host contract tests cover missing signatures, a wrong key, two-key
rotation, a valid signature over different message bytes, trusted scrub and
signature garbage collection. On the x86_64 QEMU development kernel, the
signed realization-v2 closure booted through dm-verity under BIOS and UEFI.
Changing the detached signature or embedding a different public key rejected
the generation before its root hash was accepted. The explicit
`allow-unsigned` path separately booted the old unsigned fixture.

The signed realization-v3 Gate booted a two-layer FHS stack under BIOS and
UEFI, including a pure deletion and remove-then-replace transaction. Changing
a layer data block or a used base hash-tree block rejected the generation at
the authenticated SquashFS mount.

The release-media Gate builds a UKI containing the kernel, initramfs, command
line and OS identity, signs it with an operator-supplied certificate, and uses
it as the removable-media UEFI entry. The same disk retains BIOS GRUB support.
It booted through OVMF with Secure Boot enabled and the signing certificate
enrolled. Repeating the build with identical inputs produced the same signed
UKI digest. Changing one byte in that UKI caused OVMF to report a security
violation before the Volatoo initramfs started. Debian OVMF snakeoil keys are
used only for this public QEMU fixture; production release keys remain an
operator responsibility.
