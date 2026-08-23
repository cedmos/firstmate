# Crew instruction overlay hiding verification

Audience: maintainer verification.

This record supports the active guarantee that the crew instruction overlay stays escapable by the worker it is installed for.
[`bin/fm-crew-worktree-instructions-lib.sh`](../../bin/fm-crew-worktree-instructions-lib.sh) owns the mechanism, and [`docs/architecture.md`](../architecture.md) owns its place in the spawn path.

The overlay replaces `AGENTS.md` and `CLAUDE.md` in a linked firstmate-repo task worktree.
Because those paths are tracked, the overlay is a divergence between the worktree and the index, and the only open question is whether git is told about it.
The two checks below are why it is told: concealing the divergence wedges the worker with no working escape, and git's own stash is a safe place for the edits the overlay would otherwise overwrite.

## Concealing the overlay wedges every branch move, and both concealment bits do it

This check ran on 2026-08-23 with git 2.50.1 (Apple Git-155) in a disposable scratch repository.
It exists because `--assume-unchanged` was proposed as a wedge-free replacement for `--skip-worktree`.
It is not one: both bits produce the identical refusal, and under both, the remedy git names in that refusal saves nothing.

The exact script run from this repository root was:

```bash
set -eu
git --version
PROBE="$PWD/.crew-hiding-probe"
rm -rf "$PROBE"; mkdir -p "$PROBE"; cd "$PROBE"
git init -q -b main .
git config user.email probe@example.invalid; git config user.name probe
printf 'committed\n' > AGENTS.md; git add -A; git commit -qm base
git branch -q target
printf 'moved on\n' > AGENTS.md; git add -A; git commit -qm 'main moves AGENTS.md'
git checkout -q target
for mech in skip-worktree assume-unchanged none; do
  git checkout -q -f target; git clean -qfd
  printf 'OVERLAY\n' > AGENTS.md
  [ "$mech" = none ] || git update-index "--$mech" -- AGENTS.md
  printf '\n### %s\n' "$mech"
  printf 'status:   [%s]\n' "$(git status --porcelain | tr -d '\n')"
  printf 'merge:    %s\n' "$(git merge main -m x 2>&1 | head -1)"
  printf 'stash:    %s\n' "$(git stash push -- AGENTS.md 2>&1 | head -1)"
  printf 'stashed:  %s entry(ies)\n' "$(git stash list | grep -c . || true)"
  git stash clear
  git update-index --no-skip-worktree -- AGENTS.md 2>/dev/null || true
  git update-index --no-assume-unchanged -- AGENTS.md 2>/dev/null || true
done
cd ..; rm -rf "$PROBE"
```

Its exact output was:

```
git version 2.50.1 (Apple Git-155)

### skip-worktree
status:   []
merge:    error: Your local changes to the following files would be overwritten by merge:
stash:    No local changes to save
stashed:  0 entry(ies)

### assume-unchanged
status:   []
merge:    error: Your local changes to the following files would be overwritten by merge:
stash:    No local changes to save
stashed:  0 entry(ies)

### none
status:   [ M AGENTS.md]
merge:    error: Your local changes to the following files would be overwritten by merge:
stash:    Saved working directory and index state WIP on target: e38d4a7 base
stashed:  1 entry(ies)
```

All three refuse the branch move, so the refusal is not what the concealment bits change.
What they change is whether the refusal can be acted on: under both bits `git status` reports nothing to explain the refusal and `git stash` saves nothing, so the worker is left with advice that cannot be followed.
Without them the same refusal is accompanied by a visible modification and a stash that works, which is why the overlay is installed as an ordinary modification and filtered by content where a cleanliness check must ignore it.

A separate observation from the same session, not reproduced by the script above: with `--assume-unchanged`, `git merge` printed that refusal and still replaced the overlay with the committed file, so the role protection disappeared while the command reported failure.

## `git update-index` applies only the last concealment flag per invocation

Clearing both bits in one call leaves the first one set:

```
$ git update-index --skip-worktree -- AGENTS.md
$ git update-index --no-skip-worktree --no-assume-unchanged -- AGENTS.md
$ git ls-files -v -- AGENTS.md
S AGENTS.md
```

A restore attempted against that still-concealed entry fails with `error: pathspec 'AGENTS.md' did not match any file(s) known to git`.
Removal therefore issues the two clears as separate invocations, which reports `H AGENTS.md` and lets `git checkout HEAD -- AGENTS.md` succeed.

## The stash stacks, and its entries outlive the disposable worktree

This check ran on 2026-08-23 with git 2.50.1 (Apple Git-155).
It supports storing in-progress instruction edits in the stash rather than a private sidecar: a second relaunch must not destroy the first relaunch's saved edits, and an entry must remain reachable after the task worktree is removed.

The exact script run from this repository root was:

```bash
set -eu
PROBE="$PWD/.crew-stash-probe"
rm -rf "$PROBE"; mkdir -p "$PROBE"; cd "$PROBE"
git init -q -b main primary
cd primary
git config user.email probe@example.invalid; git config user.name probe
printf 'committed\n' > AGENTS.md; git add -A; git commit -qm base
git worktree add -q ../linked -b task
cd ../linked
printf 'EDIT E1\n' > AGENTS.md; git stash push -q -m 'fm-crew' -- AGENTS.md
printf 'EDIT E2\n' > AGENTS.md; git stash push -q -m 'fm-crew' -- AGENTS.md
printf 'stash list in the linked worktree:\n'; git stash list | sed 's/^/  /'
printf 'E1 still present at stash@{1}: %s\n' "$(git stash show -p 'stash@{1}' | grep -c 'EDIT E1')"
printf 'E2 present at stash@{0}:       %s\n' "$(git stash show -p 'stash@{0}' | grep -c 'EDIT E2')"
printf 'same list read from the primary worktree:\n'; git -C ../primary stash list | sed 's/^/  /'
cd ../..; rm -rf "$PROBE"
```

Its exact output was:

```
stash list in the linked worktree:
  stash@{0}: On task: fm-crew
  stash@{1}: On task: fm-crew
E1 still present at stash@{1}: 1
E2 present at stash@{0}:       1
same list read from the primary worktree:
  stash@{0}: On task: fm-crew
  stash@{1}: On task: fm-crew
```

The second push added an entry instead of replacing the first, and both entries are readable from the primary worktree, so `refs/stash` is shared rather than per-worktree state.

## Refreshing these facts

[`tests/fm-crew-worktree-instructions.test.sh`](../../tests/fm-crew-worktree-instructions.test.sh) enforces the resulting behavior on every CI run through the real library and real git.
Re-run the scripts above after a git major-version upgrade if the concealment or stash semantics they pin are ever in question.
