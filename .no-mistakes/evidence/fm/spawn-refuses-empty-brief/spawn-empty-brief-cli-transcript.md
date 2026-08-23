# fm-spawn.sh: an empty brief can no longer launch an agent

Operator-level transcript. `bin/fm-spawn.sh` is driven exactly as a captain drives it,
against a real git project and a fake terminal (fake `tmux` + no-op `treehouse`) so no
real pane or worktree pool is touched. Paths are masked to `~/.firstmate` and `~/code/app`
for readability; nothing else is edited.

## Before the fix (bin/fm-spawn.sh at base commit f170ced)

The 0-byte brief clears the `[ -f ]` gate and the spawn keeps going: it warns about the
brief's contract line, then gets all the way into terminal/worktree allocation and names
the agent window it already created. In the real fleet this is where the six agents came
up at idle prompts with nothing to read while the task recorded as spawned.

```
$ wc -c ~/.firstmate/data/api-retry-fix/brief.md
       0 ~/.firstmate/data/api-retry-fix/brief.md

$ fm-spawn.sh api-retry-fix ~/code/app --mode no-mistakes --yolo off
warning: ~/.firstmate/data/api-retry-fix/brief.md records no delivery contract line (scaffolded before ship briefs recorded one); launching on the explicit --mode no-mistakes - confirm its definition of done matches
error: treehouse get did not enter a worktree within 60s; inspect window firstmate:fm-api-retry-fix
$ echo $?
1
$ ls ~/.firstmate/state/api-retry-fix.meta
ls: ~/.firstmate/state/api-retry-fix.meta: No such file or directory
```

The only reason this stops at all is the fixture's no-op `treehouse`. The brief gate
itself let it through.

## After the fix (target commit c9a922d)

### 1. Empty brief - refused up front, named as EMPTY

```
$ wc -c ~/.firstmate/data/api-retry-fix/brief.md
       0 ~/.firstmate/data/api-retry-fix/brief.md

$ fm-spawn.sh api-retry-fix ~/code/app --mode no-mistakes --yolo off
error: the brief at ~/.firstmate/data/api-retry-fix/brief.md is empty; a worker launched on it would have no instructions to read - restore its contents before spawning
$ echo $?
1
$ ls ~/.firstmate/state/api-retry-fix.meta
ls: ~/.firstmate/state/api-retry-fix.meta: No such file or directory
```

No warning, no window, no worktree, no task endpoint - the launch never starts.

### 2. Missing brief - still its own, byte-identical message

```
$ fm-spawn.sh api-retry-typo ~/code/app --mode no-mistakes --yolo off
error: no brief at ~/.firstmate/data/api-retry-typo/brief.md
$ echo $?
1
```

An operator reading this goes looking for a file that is genuinely absent; the empty case
never borrows this wording.

### 3. Ordinary brief - still launches

```
$ wc -c ~/.firstmate/data/api-retry-real/brief.md
      50 ~/.firstmate/data/api-retry-real/brief.md

$ fm-spawn.sh api-retry-real ~/code/app --mode no-mistakes --yolo off
warning: ~/.firstmate/data/api-retry-real/brief.md records no delivery contract line (scaffolded before ship briefs recorded one); launching on the explicit --mode no-mistakes - confirm its definition of done matches
spawned api-retry-real harness=codex kind=ship mode=no-mistakes yolo=off window=firstmate:fm-api-retry-real worktree=~/.firstmate/pool/w1
$ echo $?
0
$ ls ~/.firstmate/state/api-retry-real.meta
~/.firstmate/state/api-retry-real.meta
```

The gate costs a legitimate dispatch nothing: `spawned <id>` is reported and the task
endpoint is recorded.
