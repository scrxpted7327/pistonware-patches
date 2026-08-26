# Private checkout layout

`~/Developer/pistonware` is the one persistent working directory. Its `.git` directory is the
private repository history at `scrxpted7327/pistonware-private.git`.

## Filesystem boundary

```text
~/Developer/
└── pistonware/
    ├── .git/                    private Git metadata only
    ├── .public-allowlist        exact public projection rules
    ├── .public-gitignore        generated public checkout ignore file
    ├── scripts/
    │   ├── check-public-export
    │   ├── publish-public
    │   ├── import-public-upstream
    │   └── public_export.py
    ├── dev/                     private files inside the canonical scope
    ├── games/
    ├── loaderdev.lua            private files inside the canonical scope
    └── ...
```

There is no persistent `pistonware-private/` or public checkout. The public repository is created
only in a temporary directory by `scripts/publish-public`. That temporary directory has its own
public `.git`; the private `.git` is never copied into it.

The arrangement is one ordinary Git repository, not a nested repository, submodule, shared
worktree, symlink, or public/private branch pair. Files are addressed by the same relative path
inside the canonical directory; only the Git metadata and publication scope differ.

## Tracking and publication boundaries

Private Git tracking is governed by the root `.gitignore` and the existing private index. A file
can therefore be tracked privately even when it is ignored by the public checkout's historical
rules. The private working tree remains the superset and is never reconstructed by copying the
public export back over it.

Public publication is default-deny. Only paths listed in `.public-allowlist` are copied. The
allowlist is the publication boundary; `.gitignore` is not used as an access-control mechanism.
`.public-gitignore` supplies the public checkout's convenience ignore rules and is not itself
published.

## Normal private workflow

```sh
cd ~/Developer/pistonware
git pull
# edit public or private files
git add -A
git commit -m "Development changes"
git push
```

## Public projection workflow

```sh
./scripts/publish-public --dry-run
./scripts/publish-public
```

The publisher requires a clean private tree, builds an exact temporary projection, rejects files
outside the allowlist and known secret/private paths, shows the public diff, and pushes only to
`scrxpted7327/pistonware-patches`. It removes public files that are no longer present in the
allowlisted projection.

The standalone validator can check a generated tree with:

```sh
./scripts/check-public-export --tree /path/to/temporary-export
```

With no `--tree`, it validates a temporary projection of the current private files.

## Public upstream workflow

```sh
./scripts/import-public-upstream --check
./scripts/import-public-upstream --apply
```

The importer clones `themagicpiston/pistonware` temporarily, compares only allowlisted paths,
and reports readable differences. `--apply` copies reviewed public changes into the canonical
tree without merging Git histories, deleting private-only files, or committing automatically.
