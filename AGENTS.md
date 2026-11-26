# Working on AshCache

## Merging to main is a release

Every merge to `main` that changes the version in `mix.exs` is published to
hex.pm at once by `.github/workflows/release.yml`. There is no separate
release step and no waiting room.

So every pull request that changes behaviour, in the same pull request:

- bumps `@version` in `mix.exs` (and the `~> x.y` in `README.md` and
  `usage-rules.md` when the minor or major number changes);
- adds its `CHANGELOG.md` entry under that version and today's date.

Never write an `## Unreleased` heading: nothing here stays unreleased.

## Checks before a push

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test --warnings-as-errors --include multi_server
mix docs --warnings-as-errors
```
