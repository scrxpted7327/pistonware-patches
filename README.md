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

There is no persistent `pistonware-private/` or public checkout. The private repository has one
branch, `main`. A public repository is created only in a temporary directory by
`scripts/publish-public`; that temporary directory has its own public `.git`, and the private
`.git` is never copied into it.

The private repository is not a public/private branch pair. Public release branches are separate
projection branches named `main`, `beta`, and `nightly`. Files are addressed by the same relative
path inside the canonical directory; only the Git metadata, publication scope, and public channel
branch differ.

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
./scripts/publish-public --channel main --dry-run
./scripts/publish-public --channel main
./scripts/publish-public --channel beta
./scripts/publish-public --channel nightly
```

The publisher requires a clean private tree, builds an exact temporary projection, rejects files
outside the allowlist and known secret/private paths, shows the public diff, and pushes only to
the matching branch in `scrxpted7327/pistonware-patches`. `main` is the default. If `beta` or
`nightly` does not exist there yet, it is created from the public `main` projection before the
validated files are pushed. It removes public files that are no longer present in the allowlisted
projection.

The loader consumes the release branches from `themagicpiston/pistonware`. The patches repository
is the writable staging projection; each channel must be reviewed and promoted to the corresponding
upstream branch before that channel is available from the public loader.

The standalone validator can check a generated tree with:

```sh
./scripts/check-public-export --tree /path/to/temporary-export
```

With no `--tree`, it validates a temporary projection of the current private files.

## Public upstream workflow

```sh
./scripts/import-public-upstream --channel main --check
./scripts/import-public-upstream --channel main --apply
```

The importer accepts `--channel main`, `--channel beta`, or `--channel nightly`, clones the
selected branch of `themagicpiston/pistonware` temporarily, compares only allowlisted paths, and
reports readable differences. `--apply` copies reviewed public changes into the canonical tree
without merging Git histories, deleting private-only files, or committing automatically. It fails
closed when the selected upstream release branch does not exist yet.
