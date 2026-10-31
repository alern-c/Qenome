# Auto-merge

A pull request into `main` can squash-merge itself when it has the `automerge` label and every required check below is green. Two of those checks are the gates added for this: `review-gate` and `automerge-guard`. GitHub's own auto-merge waits for the rest. The workflow uses the default `GITHUB_TOKEN`. It does not use a personal access token, and it does not change repository settings. A maintainer turns those settings on by hand, in [Settings on main](#settings-on-main).

## How it works

`.github/workflows/automerge.yml` runs on `pull_request_target` when a pull request is opened, reopened, synchronized, marked ready, edited, labeled, unlabeled, or when auto-merge is enabled from the pull request page. The workflow file and `scripts/automerge_guard.py` come from the pull request's base commit. The job checks out that commit and nothing from the pull request head. It does not run the pull request's code. It reads the changed-file list, and the text of `build.zig.zon`, `CHANGELOG.md`, and any `package.json` that is not already excluded by its path, through the API.

`automerge-guard` fails when the pull request is excluded. It posts or updates one comment that lists the reasons, and a later run deletes that comment if the pull request is no longer excluded. The label does not change the result: an excluded pull request fails the check with or without it. `disable-automerge` then turns GitHub auto-merge off if it was on.

When the guard passes, `enable-automerge` turns GitHub auto-merge on with squash only if all of these are true: the pull request has the `automerge` label, it is not a draft, and its head repository is this repository. Otherwise it turns auto-merge off. `enable-automerge` and `disable-automerge` are not required checks. If the repository setting Allow auto-merge is off, `enable-automerge` fails and nothing merges.

GitHub completes the squash merge only when the required checks are green and the branch is up to date. The workflow does not update the branch. An update made by this token would not start the pull request workflows, so a person updates the branch and the checks run again.

A person who can edit the pull request can also press Enable auto-merge. On that event the workflow turns it back off when the label is absent. A press made while every required check is already green can merge before that run starts. Someone with permission to press the button can merge by hand as well. An excluded pull request still cannot complete that merge, because `automerge-guard` is red.

## The review gate

The OpenCode review in `.github/workflows/opencode-review.yml` is still a comment and an inline review. Neither of those blocks a merge. The agent also writes two files under the runner temp directory:

- findings: a JSON array of `path`, `line`, `severity`, and `body`. `severity` is exactly `blocker`, `major`, `minor`, or `nit`. An empty array means there is no finding.
- verification: a JSON object with exactly two keys, `verification` and `head_sha`. `verification` is `matches`, `does_not_match`, or `could_not_verify`. `head_sha` is the pull request head.

`review-gate` is a separate job in that workflow. It checks out the base commit and runs that commit's `scripts/review_gate.py`. It passes when all of the following are true for the current head:

- Zig setup, the head build (including `qenome --version`), and the merge-base build all finished with outcome `success`. Those outcomes come from the steps, not from a file the agent can rewrite.
- The OpenCode step finished with outcome `success`.
- The verification file is strict JSON of at most 4096 bytes, with exactly those two keys, `verification` equal to `matches`, and `head_sha` equal to the pull request head.
- The findings file is a strict JSON array of at most 256 KiB, every item is an object, every `severity` is one of the four words above, and none is `blocker` or `major`.

`minor` and `nit` stay on the pull request and do not fail the gate. A fence around the JSON, a duplicate key, a missing file, a byte-order mark, a stale SHA, `does_not_match`, `could_not_verify`, an unknown severity, a failed or skipped build, or a failed OpenCode step fails the gate. The script exits non-zero on each of those. It does not treat a missing file as an empty review.

A pull request that changes no qenome behaviour still has to build both trees and run `qenome --version` on the head. The agent skips the comparison and records `matches` only when that run succeeded.

The review does not run for a draft or for a fork. `review-gate` still runs, and it fails closed. A fork cannot auto-merge. Merging a fork means a maintainer bypasses `review-gate`, or the branch is pushed to this repository so the review runs. Do not mark the `review` or `mention` jobs as required: both are skipped on ordinary events (`mention` unless someone comments `/oc` or `/opencode`, `review` on a draft or a fork), and a skipped required check never goes green.

The review job checks out the pull request head, as it did before, and only for a pull request whose head is in this repository. `review-gate` does not. A pull request that edits the workflow can upload a passing verification file. `automerge-guard` still fails, because any file under `.github/workflows/` is excluded and that guard runs the workflow from the base commit. Both checks have to be required. A pull request that edits `scripts/review_gate.py` does not change the copy the gate runs until that edit is on the base commit, and the guard excludes that path so the edit cannot merge itself.

## What is excluded

Any of the following excludes the pull request. The comment names each one. A rename is judged on both the old path and the new path. The guard fails closed when the changed-file list does not end within 3000 files, when a path is not a normal relative path, or when the text it needs cannot be read.

Workflows, the whole directory:

- `.github/workflows/`

Release and npm packaging:

- `npm/`
- `scripts/changelog-section.sh`
- `scripts/publish_npm.py`
- `scripts/require_npm_release.py`
- `scripts/smoke_npm.py`
- `scripts/stage_npm.py`
- `scripts/verify_published_npm.py`
- a `package.json` anywhere whose `version` string changes, or that is added or removed. A `package.json` under `npm/` is already excluded by the directory. An edit that keeps `version` and lives outside `npm/` is not excluded for this rule.

The gate itself:

- `scripts/automerge_guard.py`
- `scripts/review_gate.py`

Verdict rules and accuracy answers:

- `src/cli/comparison.zig`, which holds `decide`, `judgeRows`, `judgeRowsWith`, `judgeMigrationWrite`, and `RowVerdict`. There is no separate numeric verdict threshold: any increase in rows read or rows written is `needs-check`, or `regressed` when the caller asks for that. The 1000-row `data_too_small` warning in `src/db.zig` does not change the verdict and is not in this list.
- `testdata/accuracy/**/case.json`, the expected-answer file for each accuracy case. Other files in a case directory, such as `select.sql`, are not on this list. `src/cli/pair.zig`, `src/cli/batch.zig` (`candidateJudgement`), and `src/cli/batch_writes.zig` call the verdict functions and are not excluded as a whole. A change there that also changes an expected answer touches `case.json` and is excluded. A change that does not update `case.json` still has to pass `verify`, which runs the accuracy corpus.

Version:

- the `.version` field in `build.zig.zon`. A change to `minimum_zig_version`, the fingerprint, or another field in that file does not exclude the pull request. Adding or removing the file does. If the `.version` line cannot be read, the pull request is excluded.
- `CHANGELOG.md`, except edits inside the body of `## [Unreleased]` (after that heading and before the next `## [` heading). Adding a `## [x.y.z]` heading, editing text under a released heading, or editing the preamble excludes the pull request. The heading must be the exact line `## [Unreleased]`.

## How to use the label

Create the label `automerge` once, in the repository's label list. The workflow does not create it. Someone who can apply labels adds it to a pull request when the change is safe to merge without another review.

1. Open the pull request from this repository, not from a fork, and mark it ready for review.
2. Wait until `review-gate` and the other required checks are green.
3. Add the `automerge` label. `enable-automerge` asks GitHub to squash-merge when the required checks pass.
4. If the branch is behind `main`, update the branch. The checks run on the new head. GitHub merges when they are green and the branch is up to date.
5. Remove the label to turn auto-merge off.

Do not add the label to an excluded pull request. The guard fails, the comment says why, and auto-merge is turned off. This includes a pull request that changes `.github/workflows/automerge.yml`, `.github/workflows/opencode-review.yml`, or either gate script.

## Settings on main

These are repository settings. A pull request cannot change them. After this workflow is on `main`, set them. Until `automerge-guard` has run once on a pull request, the check name does not appear in the list, so add it after the first run.

Pull request settings, under the repository's general settings:

- Allow auto-merge.
- Allow squash merging. The workflow requests squash and does not request a merge commit or a rebase.

Branch protection rule or ruleset for `main`:

- Require a pull request before merging.
- Require status checks to pass before merging.
- Require branches to be up to date before merging.
- Required status checks, using these names as they appear on a pull request (`verify`, not `quality / verify`; the longer name is the reusable-workflow call on a tag or a publish run):
  - `verify` runs `python3 scripts/check_all.py`: the Zig version, formatting, the build, the accuracy corpus, the tests, the architecture and line-count checks, and the other stages in that script.
  - `skill-examples`
  - `pr-format`
  - `pack`
  - `smoke (ubuntu-latest, linux-x64)`
  - `smoke (ubuntu-24.04-arm, linux-arm64)`
  - `smoke (macos-latest, darwin-arm64)`
  - `smoke (macos-15-intel, darwin-x64)`
  - `review-gate`
  - `automerge-guard`
- Do not require `review`, `mention`, `enable-automerge`, or `disable-automerge`.
- Leave "Require conversation resolution" off. `minor` and `nit` findings are review comments, and the gate already fails on `blocker` and `major`.
- Leave required approving reviews off if the label is the human decision. The workflow does not submit a review. Turn approving reviews on only when a person must approve as well as label; auto-merge then waits for that approval.
- Let repository admins bypass the rule, and use that bypass only to merge an excluded pull request, such as a version bump. Do not put GitHub Actions on the bypass list. The workflow token cannot skip a required check.

## What the merge does not start

A squash merge made by the default `GITHUB_TOKEN` does not start workflows that listen for the resulting push. `quality.yml` and `npm.yml` therefore do not run again on `main`. The merge does not create a tag, so `release.yml` does not run, and `publish-npm.yml` does not start from its `workflow_run` trigger on that release. Release and npm publish stay on the tag and the manual run. That is intentional.
