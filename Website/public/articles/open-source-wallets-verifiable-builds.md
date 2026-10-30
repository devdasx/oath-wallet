# The Missing Link Between Open Source and the Wallet on Your Phone

Oath Wallet · October 19, 2026 · 9 min read

https://articles.oathwallet.org/open-source-wallets-verifiable-builds

What connects public source code to the app you install? A practical guide to reproducible builds, signed releases, App Store approval, and Oath’s current evidence.

You find a wallet with a public GitHub repository. The code is there. The license is there. People can inspect it, discuss it, and build it themselves. That is a meaningful reason to pay attention.

Then you open the App Store and tap Download.

One question still needs an answer: **was the app you just installed actually built from the code you were shown?**

For a wallet, that question reaches all the way to your money. The software on your phone helps generate or import credentials, displays the transaction you are about to authorize, and signs it. Being able to inspect the source is valuable. Being able to connect that source to the distributed app adds another layer of assurance.

Here is what that extra layer means, what it can prove, and how Oath describes the relationship between its public source and its App Store release.

## What open source gives you

Open-source software makes its code available under a license that grants rights to use, study, modify, and redistribute it. The Open Source Initiative’s definition includes those freedoms; simply putting some code on a public page does not automatically meet the definition. [Read the Open Source Definition.](https://opensource.org/osd)

For a wallet, public source lets independent developers examine questions that a marketing page cannot settle. How are keys generated? What gets stored? What leaves the device? What must happen before a transaction is signed? Which third-party libraries are involved?

That scrutiny matters even if you never read a line of code yourself. Researchers and other developers can investigate on your behalf and publish findings that everyone can inspect.

But a repository describes a body of code. On its own, it does not establish which code produced a particular download. A developer could publish one version and distribute another. A build system could also introduce an unwanted change after a reviewer has examined the source. Those are the gaps that build verification aims to reduce. [The Reproducible Builds project explains this threat.](https://reproducible-builds.org/docs/which-problems-do-reproducible-builds-solve/)

## What a reproducible build adds

A build turns source code into the software your device runs. A reproducible build makes that transformation repeatable: with the specified source, environment, and instructions, another party can produce identical copies of the defined output files. The comparison is usually made using cryptographic hashes. [See the formal definition.](https://reproducible-builds.org/docs/definition/)

A meaningful verification result therefore connects three things: an exact source revision, a documented build process, and a precisely identified release artifact. The report should show what was compared and whether it matched.

There is an extra step when the claim concerns an app store. Matching an unsigned file hosted on GitHub establishes a result about that file. To establish a result about the app on your phone, the evidence must also connect the comparison to the artifact delivered through that store.

Consider two otherwise comparable wallets. Both publish their source. For one, the connection between source and download rests on the publisher’s assurance. For the other, an independent party can rebuild the stated release and verify the distributed artifact using a documented method. The second offers stronger evidence against an undisclosed difference introduced during building or distribution. That is the specific security advantage.

## The word “verified” needs an object

Several useful checks are often described with the same word. They answer different questions.

**A verified GitHub commit** means GitHub has verified a commit’s cryptographic signature. It says something about the origin and integrity of that commit. It does not compare an App Store download with the repository. [GitHub documents exactly what its badge means.](https://docs.github.com/en/authentication/managing-commit-signature-verification/about-commit-signature-verification)

**A successful build or test run** establishes that the stated build or tests completed in that environment. It does not establish that a store serves the same output.

**A signed release** provides evidence about the signer and the integrity of the signed artifact. A developer’s signature does not, by itself, demonstrate that the artifact was produced from public source.

**A build attestation** records provenance: information such as the source commit, repository, and workflow associated with an artifact. This is valuable evidence, but it still needs verification against the artifact and a sensible trust policy. GitHub explicitly warns that attestations do not guarantee an artifact is secure. [Read GitHub’s explanation of artifact attestations.](https://docs.github.com/en/actions/concepts/security/artifact-attestations)

**An independently reproduced release** adds a rebuild-and-compare result. A claim about the store version must identify how that result reaches the store-delivered app.

Before accepting “verified build,” ask: verified by whom, against what, and for which version?

## Apple’s approval and the source-to-store question

Apple’s review and code-signing system provide real protections. Apple describes developer identity checks, mandatory code signing, and review intended to check that apps generally work as described. These establish a controlled distribution process. They do not constitute a published comparison with a wallet’s GitHub source. [Apple explains its app code-signing process.](https://support.apple.com/en-mide/guide/security/sec7c917bf14/web)

The artifact itself also needs careful treatment. Apple’s app-thinning documentation describes device-specific variants containing different combinations of assets and binaries. A universal archive and a device-specific download can therefore be different files for legitimate reasons. [See Apple’s documentation on app variants.](https://developer.apple.com/documentation/Xcode/reducing-your-app-s-size)

A credible iOS verification method must identify the exact version and build, the source revision, the toolchain and configuration, and the particular artifact or components compared. It must explain how platform packaging and signing are handled. If any parts are excluded from comparison, the report needs to say which parts and why.

A matching version number, an archive checksum, or a successful upload is useful release bookkeeping. None of those facts alone closes the source-to-store gap.

When a wallet says its App Store build is verified, you should be able to follow a method and inspect a result, rather than infer a result from Apple’s approval.

## Google Play needs a precise claim, too

Android has practical tools for reproducible verification, but the distribution route still matters. Google Play can generate and sign optimized APKs from an Android App Bundle for different device configurations. Verifying an APK from a project’s website does not automatically verify every Play-delivered variant. [Google explains how App Bundles are distributed.](https://developer.android.com/guide/app-bundle)

F-Droid documents a concrete approach: reproduce the upstream APK, copy its signing information using the supported method, and check that verification succeeds. Its documentation explains both the required equivalence and common causes of mismatches. That is the kind of inspectable process a reproducibility claim should point to. [Read F-Droid’s reproducible-build documentation.](https://f-droid.org/docs/Reproducible_Builds/)

## How to compare wallets fairly

There are useful examples worth recognizing. Muun’s Android repository includes instructions for reproducible builds and for checking an existing APK: obtain the installed APK, select the corresponding source commit, and run its verification script. That goes beyond a general statement that the source is public. This article reviews the published procedure; it does not report a fresh verification of Muun’s current release, and the Android procedure should not be treated as proof for iOS. [Muun’s Android build and verification instructions.](https://github.com/muun/apollo/blob/master/BUILD.md)

Blockstream’s Android README documents another useful check: verifying release authenticity through certificate fingerprints and signed checksums. Those instructions help authenticate the download. The check described there answers a different question from independently rebuilding it. This is a distinction between the methods, not a claim that those instructions describe all of Blockstream’s security work. [Blockstream’s release-authenticity instructions.](https://github.com/Blockstream/green_android/blob/master/README.md#verifying-release-authenticity)

For any wallet that offers only a repository link, the fair conclusion is limited: public source is available, but that link alone supplies no evidence of a store-binary match. It would be wrong to turn that absence into an accusation of malicious behavior. It would also be wrong to advertise a match without evidence.

Compare the platform, release, method, and result. A brand-wide label hides too much.

## Oath: open source, and a clear statement about the shipped app

Oath publishes its MIT-licensed 4.1.14 (98) source release with build instructions and a release verification record. The app source used for the uploaded archive is commit v4.1.14. Provider configuration and Apple signing are supplied locally and excluded from Git. [Explore Oath’s published source release.](https://github.com/devdasx/oath-wallet/releases/tag/v4.1.14)

**On October 30, 2026, build 86 was uploaded to App Store Connect and submitted for review.** The [release verification record](https://github.com/devdasx/oath-wallet/releases/tag/v4.1.14) records the source, archive and upload evidence. Apple showed Waiting for Review at submission; the public US App Store listing still showed 4.1.2 when checked. Submission is not approval or a new public-store binary comparison.

There is a distinction worth keeping explicit: a publisher’s confirmation is not the same evidence as an independent party reproducing a release and publishing its comparison. This article does not present a new binary comparison, a byte-for-byte reproducibility result, or an independent security audit. The repository’s documented exclusions and configuration requirements still apply.

That distinction is the point of this article. Public source gives people something concrete to inspect. A maintainer’s release statement makes the team’s claim explicit. An independently repeatable comparison provides a further level of evidence. Readers should be able to tell which of those they are looking at.

For Oath, as for every wallet, security language should help people understand the evidence. It should never make them guess what “verified” means.

## Five things to look for before trusting a build claim

- **An exact release.** The platform, version, build number, and distribution channel should be unambiguous.

- **An exact source revision.** A fixed commit is more useful than a moving default branch.

- **A repeatable recipe.** Toolchain versions, dependencies, configuration, and required build inputs should be documented.

- **A transparent comparison.** Look for artifact identifiers, the comparison method, the result, and any exclusions.

- **A named verifier and a date.** Distinguish a publisher’s own checks from independent reproduction, and check whether the result applies to the version you use.

The [Reproducible Builds guidance on build environments](https://reproducible-builds.org/docs/perimeter/) explains why the toolchain and its assumptions need to be documented.

You should never need to share a recovery phrase or private key to investigate a public build-verification claim.

## Better evidence, with honest limits

A reproducible build can faithfully reproduce vulnerable code. It cannot, by itself, establish that the design is sound, that a remote service is trustworthy, or that your phone is uncompromised. Source review, security testing, careful dependency management, and responsible release practices still matter. Reproducibility addresses a particular gap in that larger system. [Read more about its purpose and limits.](https://reproducible-builds.org/docs/which-problems-do-reproducible-builds-solve/)

Open source makes inspection possible. Reproducible builds make a specified source-to-artifact relationship testable. Verification of the distributed app brings that evidence closer to the software you actually use.

For self-custody, those distinctions deserve plain language. A wallet should make it easy to see what has been checked, what the result proves, and what remains unproven. Confidence is more useful when you can trace where it comes from.

*Published October 19, 2026. Oath release evidence updated October 30, 2026. Oath’s source-correspondence statement is supplied by its maintainers. The technical explanations cite public documentation; this article is not an independent wallet audit or a new reproduction of an App Store or Google Play release.*

