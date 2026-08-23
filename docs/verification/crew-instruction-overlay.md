# Crew instruction overlay hiding verification

Audience: maintainer verification.

This record supports the active guarantee that the crew instruction overlay stays escapable by the worker it is installed for.
[`bin/fm-crew-worktree-instructions-lib.sh`](../../bin/fm-crew-worktree-instructions-lib.sh) owns the mechanism, and [`docs/architecture.md`](../architecture.md) owns its place in the spawn path.

The overlay replaces `AGENTS.md` and `CLAUDE.md` in a linked firstmate-repo task worktree.
Because those paths are tracked, the overlay is a divergence between the worktree and the index, and the only open question is whether git is told about it.
The checks below are why it is told, and where the edits the overlay would otherwise overwrite are kept: concealing the divergence wedges the worker with no working escape, and git's shared stash stack cannot say which task an entry belongs to.

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

## Saved instruction edits belong to a task, so the stash is the wrong carrier

This check ran on 2026-08-23 with git 2.50.1 (Apple Git-155) in a disposable scratch repository.
It exists because git's own stash was proposed as the place to keep in-progress instruction edits the overlay would otherwise overwrite.
It is the wrong place: a stash entry carries no owner identity, `git stash pop` takes whatever sits at `stash@{0}`, and `refs/stash` is one stack shared by every worktree of the repository including the primary checkout.
The same script demonstrates the carrier that replaced it, a commit under `refs/fm-crew/<task-id>/instruction-wip/<n>`.

The exact script run from this repository root was:

```bash
set -eu
git --version
PROBE="$PWD/.crew-carrier-probe"
rm -rf "$PROBE"; mkdir -p "$PROBE"; cd "$PROBE"
git init -q -b main primary
cd primary
git config user.email probe@example.invalid; git config user.name probe
printf 'committed\n' > AGENTS.md; git add -A; git commit -qm base
git worktree add -q ../slot -b task

printf '\n### refs/stash is one shared stack, and pop is position-addressed\n'
cd ../slot
printf 'TASK A EDIT\n' > AGENTS.md; git stash push -q -m 'fm-crew' -- AGENTS.md
cd ../primary
printf 'PRIMARY CHECKOUT EDIT\n' > AGENTS.md; git stash push -q -m 'unrelated primary work' -- AGENTS.md
cd ../slot
printf 'list read from the pooled slot:\n'; git stash list | sed 's/^/  /'
git stash pop -q
printf 'the slot popped stash@{0} onto its branch: %s\n' "$(head -1 AGENTS.md)"
printf 'entries left after that pop: %s\n' "$(git stash list | grep -c . || true)"
git checkout -q HEAD -- AGENTS.md; git stash clear

printf '\n### a per-task ref is addressed by owner and sequence, never by position\n'
save() {  # <owner> <content>
  owner=$1; content=$2
  blob=$(printf '%s\n' "$content" | git hash-object -w --stdin)
  idx="$PWD/.probe-index"; rm -f "$idx"
  GIT_INDEX_FILE=$idx git read-tree HEAD
  GIT_INDEX_FILE=$idx git update-index --add --cacheinfo "100644,$blob,AGENTS.md"
  tree=$(GIT_INDEX_FILE=$idx git write-tree); rm -f "$idx"
  n=1; while git rev-parse --verify --quiet "refs/fm-crew/$owner/instruction-wip/$n" >/dev/null; do n=$((n+1)); done
  git update-ref "refs/fm-crew/$owner/instruction-wip/$n" \
    "$(git commit-tree "$tree" -p HEAD -m "saved for $owner")"
  printf 'saved refs/fm-crew/%s/instruction-wip/%s\n' "$owner" "$n"
}
save task-alpha 'ALPHA EDIT 1'
save task-alpha 'ALPHA EDIT 2'
printf 'both alpha entries survive and stay distinct: %s | %s\n' \
  "$(git show refs/fm-crew/task-alpha/instruction-wip/1:AGENTS.md)" \
  "$(git show refs/fm-crew/task-alpha/instruction-wip/2:AGENTS.md)"
printf 'the slot is reused by task-beta; entries task-beta owns: [%s]\n' \
  "$(git for-each-ref --format='%(refname)' 'refs/fm-crew/task-beta/instruction-wip/*' | tr -d '\n')"

printf '\n### the refs live in the common git dir and outlive the worktree\n'
printf 'read from the primary:\n'; git -C ../primary for-each-ref --format='  %(refname)' refs/fm-crew/
cd ../primary
git worktree remove --force ../slot
printf 'after the pooled worktree is removed:\n'; git for-each-ref --format='  %(refname)' refs/fm-crew/
printf 'ALPHA EDIT 1 still readable: %s\n' "$(git show refs/fm-crew/task-alpha/instruction-wip/1:AGENTS.md)"
cd ../..; rm -rf "$PROBE"
```

Its exact output was:

```
git version 2.50.1 (Apple Git-155)

### refs/stash is one shared stack, and pop is position-addressed
list read from the pooled slot:
  stash@{0}: On main: unrelated primary work
  stash@{1}: On task: fm-crew
the slot popped stash@{0} onto its branch: PRIMARY CHECKOUT EDIT
entries left after that pop: 1

### a per-task ref is addressed by owner and sequence, never by position
saved refs/fm-crew/task-alpha/instruction-wip/1
saved refs/fm-crew/task-alpha/instruction-wip/2
both alpha entries survive and stay distinct: ALPHA EDIT 1 | ALPHA EDIT 2
the slot is reused by task-beta; entries task-beta owns: []

### the refs live in the common git dir and outlive the worktree
read from the primary:
  refs/fm-crew/task-alpha/instruction-wip/1
  refs/fm-crew/task-alpha/instruction-wip/2
after the pooled worktree is removed:
  refs/fm-crew/task-alpha/instruction-wip/1
  refs/fm-crew/task-alpha/instruction-wip/2
ALPHA EDIT 1 still readable: ALPHA EDIT 1
```

The pooled slot's `git stash pop` applied the primary checkout's unrelated work onto the task branch and left the crew's own entry behind, which is the cross-contamination a shared position-addressed stack cannot avoid.
The per-task refs hold the properties the stash cannot: two saves for one task stay distinct instead of overwriting each other, a later occupant of the same slot owns no entries at all so it has nothing to take, and both entries remain readable from the primary after the worktree is gone.

`refs/stash` being shared rather than per-worktree state is visible in the first block, where the entry pushed from the primary is listed and then consumed from the linked worktree.

Two properties here are asserted rather than shown by this script.
Refusing loudly when a task owns no entry is a decision in `bin/fm-crew-instructions.sh`, not a git behavior, and it is covered by the colocated tests instead.
Nothing prunes these refs, so a task's saved edits persist until someone deletes them deliberately; that is the intended trade, because the failure this replaces was work disappearing.

## A save has two sides, because the index carries a version of its own

This check ran on 2026-08-23 with git 2.50.1 (Apple Git-155) in a disposable scratch repository.
It exists because the per-task carrier hashes a path's blob rather than calling `git stash`, and that swap silently narrowed what a save captures.
A worker who stages one version and then edits further holds two distinct versions of their own work, and the restore that follows a save rewrites the index as well as the file.

The exact script run from this repository root was:

```bash
set -eu
git --version
PROBE="$PWD/.crew-index-probe"
rm -rf "$PROBE"; mkdir -p "$PROBE"; cd "$PROBE"
git init -q -b main .
git config user.email probe@example.invalid; git config user.name probe
printf 'committed\n' > AGENTS.md; git add -A; git commit -qm base
printf 'VERSION S\n' > AGENTS.md; git add AGENTS.md
printf 'VERSION W\n' > AGENTS.md
printf 'index holds:    %s\n' "$(git cat-file blob "$(git ls-files -s -- AGENTS.md | awk '{print $2}')")"
printf 'worktree holds: %s\n' "$(cat AGENTS.md)"

printf '\n### the superseded stash carrier kept both sides\n'
git stash push -q -- AGENTS.md
printf 'stash^2 (the index tree):  %s\n' "$(git show 'stash@{0}^2:AGENTS.md')"
printf 'stash    (the worktree):   %s\n' "$(git show 'stash@{0}:AGENTS.md')"
git stash pop -q --index

printf '\n### a worktree-only blob capture keeps one side and drops the other\n'
disk=$(git hash-object -w --no-filters -- AGENTS.md)
printf 'captured:                  %s\n' "$(git cat-file blob "$disk")"
git checkout HEAD -- AGENTS.md
printf 'index after the restore:    %s\n' "$(git cat-file blob "$(git ls-files -s -- AGENTS.md | awk '{print $2}')")"
printf 'VERSION S reachable from any captured object: %s\n' \
  "$(git cat-file blob "$disk" | grep -c 'VERSION S' || true)"

printf '\n### capturing the index blob as well keeps both recoverable\n'
printf 'VERSION S\n' > AGENTS.md; git add AGENTS.md
printf 'VERSION W\n' > AGENTS.md
staged=$(git ls-files -s -- AGENTS.md | awk '{print $2}')
disk=$(git hash-object -w --no-filters -- AGENTS.md)
git checkout HEAD -- AGENTS.md
printf 'staged entry restores:     %s\n' "$(git cat-file blob "$staged")"
printf 'worktree entry restores:   %s\n' "$(git cat-file blob "$disk")"
cd ..; rm -rf "$PROBE"
```

Its exact output was:

```
git version 2.50.1 (Apple Git-155)
index holds:    VERSION S
worktree holds: VERSION W

### the superseded stash carrier kept both sides
stash^2 (the index tree):  VERSION S
stash    (the worktree):   VERSION W

### a worktree-only blob capture keeps one side and drops the other
captured:                  VERSION W
index after the restore:    committed
VERSION S reachable from any captured object: 0

### capturing the index blob as well keeps both recoverable
staged entry restores:     VERSION S
worktree entry restores:   VERSION W
```

`git stash push` records the index as a second parent, so the superseded carrier kept both sides without being asked.
A per-path blob capture has no such second side: `git checkout HEAD --` then reset the index to the committed content, and the staged version was reachable from nothing.
That is the same "an edit disappears with no error" failure this whole mechanism exists to remove, so the index blob is captured explicitly, as its own entry, whenever it differs from both the committed blob and the file on disk.

## Refreshing these facts

[`tests/fm-crew-worktree-instructions.test.sh`](../../tests/fm-crew-worktree-instructions.test.sh) enforces the resulting behavior on every CI run through the real library and real git.
Re-run the scripts above after a git major-version upgrade if the concealment or stash semantics they pin are ever in question.
