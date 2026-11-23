# Area Tasks Menu Guard (`PZAreaTasksMenuGuard`)

An additive Project Zomboid Build 42 client patch for
[Area Tasks](https://steamcommunity.com/sharedfiles/filedetails/?id=3793163745)
(`AreaTasks`). It stops one broken task from removing the rest of the Area Tasks
context menu.

## The failure it fixes

Area Tasks builds its submenu in one event handler, walking the registry in
`order`:

```
OnFillWorldObjectContextMenu
  -> ContextMenu.onFill
      -> addCategory            (one per category; `animals` is order 220)
          -> addTaskOption
              -> Registry.getChoices(task, playerObj)        <- unprotected
              -> Registry.getAvailability(task, playerObj)   <- unprotected
```

Nothing is protected, so a task that throws while building its choices aborts
the handler and every category after it is never added. `moveItems` has order
310, so the casualty is the whole **Items** branch — Move Items, Move Items →
Containers (Area), and every other item route — which reads to the player as
"Area Tasks has no item options any more".

The trap-baiting task is a real trigger: its `getChoices` enumerates the
inventory through a Lua predicate passed to Java
(`getAllEvalRecurse(usableBait, ArrayList.new())`). When that predicate raises,
the exception crosses the Java boundary and the log shows only Kahlua's
interop `NullPointerException: Cannot assign field "callFrame" ... at
ReturnValues.put` — the actual Lua message is lost.

## What it changes

| Seam | On error |
| --- | --- |
| `AreaTasks.Registry.getChoices(task, player)` | returns no choices plus a reason, so `addTaskOption` adds a disabled option whose tooltip carries the reason |
| `AreaTasks.Registry.getAvailability(task, player)` | returns `false` plus a reason, same effect for the per-choice loop |

The real Lua error is printed once per task id and message:

```
[PZAreaTasksMenuGuard] task 'moveItems...' (Trap Baiting) getChoices failed: attempt to call ...
```

Nothing else changes: a healthy task takes exactly its original code path and
the wrappers pass its values through. No Area Tasks file is overridden, no
option, target, path or timing is touched, and the guard does nothing if
`AreaTasks`, its API version 1, or either registry function is absent.

Installation is idempotent and re-runs on `OnGameStart`, because Area Tasks (and
this file, after a Lua reload) can be rebuilt between sessions.

Requires Area Tasks (`require=AreaTasks`, `loadModAfter=AreaTasks`).
