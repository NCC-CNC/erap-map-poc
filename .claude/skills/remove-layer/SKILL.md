---
name: remove-layer
description: Remove a map layer - delete its configs in pipeline/layers/, its .pmtiles archive and its manifest.json entry, regenerate style.json, and open a draft PR. Always confirms with the user first. Use when asked to remove, delete, drop or retire a layer, or to clean up an orphaned build.
---

# Remove a layer

Destructive: always confirm before deleting anything. Commands run from
the repo root in Git Bash. A layer is two configs in git
(`pipeline/layers/<name>.env` and `<name>.style.json`) plus its build in
`data/tiles/` (`<name>.pmtiles` and an entry in `manifest.json`, from
which `style.json` is made). The source data in `data/raw/` is left
alone; say so, and that the user can delete it by hand.

## 1. Check and confirm

```sh
docker compose run --rm --build pipeline --status <name>
git log --oneline -3 -- pipeline/layers/<name>.env
```

Tell the user exactly what will go: the two config files (if present),
the archive and its size, and the manifest entry, and that the layer
disappears from the map on the next reload. Ask for an explicit yes. Do
not continue without one. An `orphan` (config already gone) needs only
step 3.

## 2. Remove the configs

Branch from `main` (`chore/remove-layer-<name>`), then:

```sh
git rm pipeline/layers/<name>.env pipeline/layers/<name>.style.json
```

Search for other mentions of the layer (`git grep -n <name>`, for example
in docs) and update them.

## 3. Remove the build

```sh
docker compose run --rm --build pipeline --remove <name>
```

It drops the manifest entry (atomically), deletes the archive and
rewrites `style.json`; the other layers are untouched. Exit 2 means
nothing was built for that name. Then check:

```sh
docker compose run --rm --build pipeline --status
```

The layer is no longer listed; the others keep their state.

## 4. Draft PR

If configs were removed, commit only those deletions (and any doc
updates), for example `chore(layers): remove <name>`, push, and open a
DRAFT PR saying why the layer goes and that its local build was removed.
Others with a local build run the same `--remove` command after pulling
(or `--status` shows it as `orphan`). Never mark the PR ready: ready PRs
merge themselves. Check `git status` first: nothing under `data/` or
`tmp/` is staged.
