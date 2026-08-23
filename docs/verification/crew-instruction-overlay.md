# Crew instruction overlay verification

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
The same script demonstrates the carrier that replaced it by calling the shipped library, so the ref names below are the ones the code actually composes rather than a hand-written guess at them.

The exact script run from this repository root was:

```bash
set -eu
git --version
. "$PWD/bin/fm-crew-worktree-instructions-lib.sh"
PROBE="$PWD/tmp/.crew-carrier-probe"
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
git checkout -q HEAD -- AGENTS.md; git stash clear

printf '\n### the shipped per-task namespace, composed by the library itself\n'
save() {  # <owner> <content>
  local owner=$1 blob
  blob=$(printf '%s\n' "$2" | git hash-object -w --stdin)
  fm_crew_store_wip_entry "$PWD" "$owner" "saved for $owner" "AGENTS.md=$blob" | sed 's/^/  saved /'
}
save task-alpha 'ALPHA EDIT 1'
save task-alpha 'ALPHA EDIT 2'
printf 'base for task-alpha:      %s\n' "$(fm_crew_wip_ref_base "$PWD" task-alpha)"
printf 'base for task-beta:       %s\n' "$(fm_crew_wip_ref_base "$PWD" task-beta)"
printf 'both alpha entries stay distinct: %s | %s\n' \
  "$(git show "$(fm_crew_wip_ref_base "$PWD" task-alpha)/1:AGENTS.md")" \
  "$(git show "$(fm_crew_wip_ref_base "$PWD" task-alpha)/2:AGENTS.md")"
printf 'entries task-beta owns:   [%s]\n' "$(fm_crew_list_wip_refs "$PWD" task-beta | tr -d '\n')"
printf 'two ids that fold alike stay apart: %s\n' \
  "$([ "$(fm_crew_wip_ref_base "$PWD" 'probe..v2.lock')" != "$(fm_crew_wip_ref_base "$PWD" 'probe.v2')" ] && echo yes || echo no)"

printf '\n### the refs live in the common git dir and outlive the worktree\n'
printf 'read from the primary:\n'; git -C ../primary for-each-ref --format='  %(refname)' refs/fm-crew/
cd ../primary
git worktree remove --force ../slot
printf 'after the pooled worktree is removed:\n'; git for-each-ref --format='  %(refname)' refs/fm-crew/
printf 'ALPHA EDIT 1 still readable: %s\n' \
  "$(git show "$(git for-each-ref --format='%(refname)' refs/fm-crew/ | head -1):AGENTS.md")"
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

### the shipped per-task namespace, composed by the library itself
  saved refs/fm-crew/task-alpha-a72eff0d82c2/instruction-wip/1
  saved refs/fm-crew/task-alpha-a72eff0d82c2/instruction-wip/2
base for task-alpha:      refs/fm-crew/task-alpha-a72eff0d82c2/instruction-wip
base for task-beta:       refs/fm-crew/task-beta-b3794eb2fa60/instruction-wip
both alpha entries stay distinct: ALPHA EDIT 1 | ALPHA EDIT 2
entries task-beta owns:   []
two ids that fold alike stay apart: yes

### the refs live in the common git dir and outlive the worktree
read from the primary:
  refs/fm-crew/task-alpha-a72eff0d82c2/instruction-wip/1
  refs/fm-crew/task-alpha-a72eff0d82c2/instruction-wip/2
after the pooled worktree is removed:
  refs/fm-crew/task-alpha-a72eff0d82c2/instruction-wip/1
  refs/fm-crew/task-alpha-a72eff0d82c2/instruction-wip/2
ALPHA EDIT 1 still readable: ALPHA EDIT 1
```

The pooled slot's `git stash pop` applied the primary checkout's unrelated work onto the task branch and left the crew's own entry behind, which is the cross-contamination a shared position-addressed stack cannot avoid.
The per-task refs hold the properties the stash cannot: two saves for one task stay distinct instead of overwriting each other, a later occupant of the same slot owns no entries at all so it has nothing to take, and both entries remain readable from the primary after the worktree is gone.
The component is `<task-id>-<digest>` because the readable part has to be folded to satisfy git's ref grammar and folding is lossy; the digest of the exact task id is what keeps two ids that fold alike apart, as the `probe..v2.lock` versus `probe.v2` line shows.
A worker should not spell that component out by hand: `bin/fm-crew-instructions.sh saved` resolves it through the same function this script calls.

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

## An unmerged path has no staged version to save

This check ran on 2026-08-23 with git 2.50.1 (Apple Git-155) in a disposable scratch repository.
It exists because the save reads the index with `git ls-files -s`, and that command answers a different shape during an unresolved merge or rebase.
The route is the one this whole mechanism exists to unblock: remove the overlay, rebase onto `origin/main` after an `AGENTS.md` change, hit a genuine conflict.

The exact script run from this repository root was:

```bash
set -eu
git --version
PROBE="$PWD/tmp/.crew-unmerged-probe"
rm -rf "$PROBE"; mkdir -p "$PROBE"; cd "$PROBE"
git init -q -b main .
git config user.email probe@example.invalid; git config user.name probe
printf 'base\n' > AGENTS.md; git add -A; git commit -qm base
git checkout -q -b other; printf 'theirs\n' > AGENTS.md; git commit -qam theirs
git checkout -q main; printf 'ours\n' > AGENTS.md; git commit -qam ours
git merge other >/dev/null 2>&1 || true

printf '\n### an unmerged path has three index entries and no merged one\n'
git ls-files -s -- AGENTS.md | sed 's/^/  /'
printf 'unfiltered `awk {print $2}` yields: %s value(s)\n' \
  "$(git ls-files -s -- AGENTS.md | awk '{print $2}' | grep -c .)"
printf 'stage-0 only yields:               [%s]\n' \
  "$(git ls-files -s -- AGENTS.md | awk '$3 == "0" {print $2}')"
printf 'ls-files -u reports it unmerged:    %s line(s)\n' \
  "$(git ls-files -u -- AGENTS.md | grep -c .)"

printf '\n### what the unfiltered value does when word-split into cacheinfo pairs\n'
idx="$PROBE/.probe-index"; rm -f "$idx"
GIT_INDEX_FILE=$idx git read-tree HEAD
pairs="AGENTS.md=$(git ls-files -s -- AGENTS.md | awk '{print $2}')"
for pair in $pairs; do
  rel=${pair%%=*}; blob=${pair#*=}
  GIT_INDEX_FILE=$idx git update-index --add --cacheinfo "100644,$blob,$rel" \
    && printf 'accepted path %s\n' "$rel"
done
tree=$(GIT_INDEX_FILE=$idx git write-tree); rm -f "$idx"
printf 'resulting tree records:\n'; git ls-tree --name-only "$tree" | sed 's/^/  /'
printf 'its AGENTS.md is the merge base: %s\n' \
  "$([ "$(git rev-parse "$tree:AGENTS.md")" = "$(git rev-parse "$(git merge-base main other):AGENTS.md")" ] && echo yes || echo no)"
cd ..; rm -rf "$PROBE"
```

Its exact output was:

```
git version 2.50.1 (Apple Git-155)

### an unmerged path has three index entries and no merged one
  100644 df967b96a579e45a18b8251732d16804b2e56a55 1	AGENTS.md
  100644 b19a1e93bec1317dc6097229e12afaffbfa74dc2 2	AGENTS.md
  100644 950b81b7eee953d050aa05a641f8e056c85dd1bd 3	AGENTS.md
unfiltered `awk {print $2}` yields: 3 value(s)
stage-0 only yields:               []
ls-files -u reports it unmerged:    3 line(s)

### what the unfiltered value does when word-split into cacheinfo pairs
accepted path AGENTS.md
accepted path b19a1e93bec1317dc6097229e12afaffbfa74dc2
accepted path 950b81b7eee953d050aa05a641f8e056c85dd1bd
resulting tree records:
  950b81b7eee953d050aa05a641f8e056c85dd1bd
  AGENTS.md
  b19a1e93bec1317dc6097229e12afaffbfa74dc2
its AGENTS.md is the merge base: yes
```

A conflicted path has stages 1, 2 and 3 and no stage 0, so "the blob the index holds" has no answer for it.
Reading every stage and word-splitting the result is quietly accepted end to end: `update-index --cacheinfo` took all three, recording the MERGE BASE as `AGENTS.md` and inventing two paths literally named after the stage-2 and stage-3 hashes, with no command failing.
The index read therefore selects stage 0 only, and a path git reports through `ls-files -u` refuses the save outright, because there is no version to record and the `git checkout HEAD --` that follows a save would collapse the worker's conflict without saying so.

## Refreshing these facts

[`tests/fm-crew-worktree-instructions.test.sh`](../../tests/fm-crew-worktree-instructions.test.sh) enforces the resulting behavior on every CI run through the real library and real git.
Re-run the scripts above after a git major-version upgrade if the concealment or stash semantics they pin are ever in question.
