# Security policy

Report suspected vulnerabilities through [GitHub private vulnerability reporting](https://github.com/arpit-it/ASG/security/advisories/new). Private reporting is enabled for this repository. Do not include live credentials or personal data in public issues, PRs, logs or screenshots. If a credential was exposed, revoke/rotate it at its provider; removing a file does not remove published history or invalidate the credential.

This project is under active development. The maintained branch is main; experimental generated-code execution is not a complete isolation boundary. Read [application security](asg/docs/SECURITY.md), [runtime setup](asg/docs/RUNTIME_SETUP.md) and [storage limits](asg/docs/STORAGE.md) before using local runtime or storage features.

## Repository controls

Main is protected: PRs, current branches, Flutter/Python CI and resolved conversations are required, including for administrators. Force pushes and branch deletion are disabled. All external fork workflow runs require approval. Default workflow tokens are read-only; Actions cannot create/approve PRs using the default repository setting. Third-party Actions are restricted to the reviewed pinned Flutter action, alongside GitHub-created and owner actions.

CODEOWNERS routes all paths to @arpit-it. The repository currently has no invited collaborators. Add write access only for trusted maintainers and revisit access regularly. These rules reduce accidental changes; they cannot guarantee that all malicious or incorrect code is detected.

The reviewer agent operates through the owner's account. Independent agent review is recorded in PR comments, but GitHub required approvals remain off to avoid blocking owner-authored PRs. Requiring a genuine second-person approval needs another trusted GitHub account and an updated rule. Mandatory signed commits, secret push protection and comprehensive vulnerability scanning are not claimed as configured controls.

Visibility remains public. Choose public for openly developed source and community contributions; choose private when code or product plans must remain confidential. On the current GitHub Free plan, branch-protection enforcement is available for this public repository; private enforcement requires an eligible paid plan. Changing visibility does not retract already published clones or copies. No visibility or plan change is performed by this policy.

References: [protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches), [fork workflow approvals](https://docs.github.com/en/actions/managing-workflow-runs/approving-workflow-runs-from-public-forks).
