# Public provenance declaration

- Repository: https://github.com/Nico77600/M365GroupsReporting
- Default branch: `main`
- Correction source baseline: `780e7a64d03da35d83419deab3e794946f7ab68d`
- Publication-standard reference: public `Nico77600/PurviewDlpReport` at `8f7c89414c398892c48450cc2e0fd6399f733e11`
- Local correction date: 2026-10-14

This declaration records the source and reference of this local correction. It is not a cryptographic signature, a complete history audit, an owner approval or a claim about authorship mechanisms.

The PowerShell scripts and source integrity manifest carry timestamped owner Authenticode signatures. The owner must verify the exact signed raw Git blobs and publish through the approved pull-request process; this declaration does not replace native signature verification.

The runtime package and its separate integrity manifest are rebuilt and finalized from the intended commit already merged into public `main`. Source signing does not claim that hosted CI has completed or that a runtime ZIP or release has been published.

`.github/workflows/attest-release.yml` attests the **actual published ZIP bytes** without building or executing repository code. A missing ZIP fails; no source archive is substituted. An attestation does not prove the original build process or replace runtime Authenticode verification.
