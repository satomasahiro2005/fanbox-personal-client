# Contributing

Thank you for your interest. **External contributions are not accepted at this time.** Pull requests from outside
the project will be closed without being merged, whatever their size.

## Why

The source code is published for reading only. All rights are reserved and no license is granted (see the notice in
the [README](README.md#copyright-and-license)). Accepting outside code now would create problems that cannot easily be
undone:

- **Unclear ownership.** Without an agreement, the copyright in a contribution stays with its author. The project
  could then no longer say "All rights reserved" for the whole code base.
- **Relicensing.** The project may move to a license such as MIT, Apache-2.0 or MPL later (SPEC §3.5). Every
  contributor whose code is still present would have to agree to that change.
- **Third-party code.** A contribution may contain code copied from elsewhere, including from projects this app must
  not copy from (SPEC §3.6: no code from PixiView-KMP, fankt or unchecked web snippets). Contributions are hard to
  audit for this without a process.

## What has to be decided first

Contributions may be accepted once the following are designed and written down:

1. **Contribution terms.** Either a Contributor License Agreement (CLA) that grants the owner the right to relicense,
   or a Developer Certificate of Origin (DCO) sign-off combined with a project license that makes relicensing
   unnecessary.
2. **Project license.** Whether the code stays All Rights Reserved, becomes source-available, or moves to an
   open-source license, and which one.
3. **Relicensing policy.** How already-merged contributions are treated if the license changes.
4. **Provenance checks.** How a reviewer confirms that a change contains no copied third-party code, and how new
   dependencies are reviewed ([THIRD_PARTY.md](THIRD_PARTY.md#review-procedure-before-adding-a-dependency)).

When these exist, this file will describe the process.

## Reporting problems

If issues are enabled on the repository, you may use them to report a bug or a security concern. A reply is not
guaranteed. **Never include cookies, `FANBOXSESSID`, CSRF tokens, passwords, card data or unredacted Research Mode
logs** in an issue. The export in Research Mode is redacted, but read it before you share it.

## Notes for the maintainer

These rules apply to changes made inside the project:

- Follow [SPEC.md](SPEC.md). `MUST` / `MUST NOT` items are not optional.
- Apple frameworks only. Any new dependency goes through the review in [THIRD_PARTY.md](THIRD_PARTY.md) first.
- Write original code. Read other projects for behavior only; do not copy or translate their code.
- SwiftUI views must not know FANBOX endpoints or JSON. Remote data goes through `RemoteDataSource` and is written by
  `LocalStore`.
- Never log or display secrets. Use `AppLog` and pass request / response text through `SecretRedactor`
  ([docs/SECURITY.md](docs/SECURITY.md)).
- Keep the build green with `scripts/build.sh` and add unit tests under `FANBOXClientTests/<Module>/`.
- Do not add a `LICENSE` file until the license decision above has been made.
