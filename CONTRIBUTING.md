## Legal

By submitting a pull request, you represent that you have the right to license
your contribution to Apple and the community, and agree by submitting the patch
that your contributions are licensed under the Apache 2.0 license (see
`LICENSE.txt`).


## How to submit a bug report

Please ensure to specify the following:

* SwiftServiceLifecycle commit hash
* Contextual information (e.g. what you were trying to achieve with SwiftServiceLifecycle)
* Simplest possible steps to reproduce
  * More complex the steps are, lower the priority will be.
  * A pull request with failing test case is preferred, but it's just fine to paste the test case into the issue description.
* Anything that might be relevant in your opinion, such as:
  * Swift version or the output of `swift --version`
  * OS version and the output of `uname -a`
  * Network configuration


### Example

```
SwiftServiceLifecycle commit hash: 22ec043dc9d24bb011b47ece4f9ee97ee5be2757

Context:
While load testing my HTTP web server written with SwiftServiceLifecycle, I noticed
that one file descriptor is leaked per request.

Steps to reproduce:
1. ...
2. ...
3. ...
4. ...

$ swift --version
Swift version 4.0.2 (swift-4.0.2-RELEASE)
Target: x86_64-unknown-linux-gnu

Operating system: Ubuntu Linux 16.04 64-bit

$ uname -a
Linux beefy.machine 4.4.0-101-generic #124-Ubuntu SMP Fri Nov 10 18:29:59 UTC 2017 x86_64 x86_64 x86_64 GNU/Linux

My system has IPv6 disabled.
```

## How to contribute your work

For non-trivial changes that affect the public API, it is good practice to have a discussion phase before writing code. Please follow the [proposal process](Sources/ServiceLifecycle/Docs.docc/Proposals/Proposals.md) to gather feedback and align on the approach with other contributors.

1. Prepare your change, keeping in mind that a good patch is:
  - Concise, and contains as few changes as needed to achieve the end result.
  - Tested, ensuring that any tests provided failed before the patch and pass after it.
  - Documented, adding API documentation as needed to cover new functions and properties.
  - Accompanied by a great commit message.
2. Open a pull request at https://github.com/swift-server/swift-service-lifecycle and wait for code review by the maintainers.

## Automated release process

This repository uses automated releases based on semantic versioning labels. See the [Auto Release Workflow documentation](https://github.com/apple/swift-temporal-sdk/blob/main/.github/workflows/README.md) for details.
