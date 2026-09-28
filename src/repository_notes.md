
<details>
<summary>Generator & documentation</summary>

### Generate this profile

The sole production generator is Zig on the default branch `refactor/zig`.
`feat/python` preserves the retired implementation for historical reference only.
Edit `profile.yaml` for profile content; this README is generated in full.
The instructions and index below come from `src/repository_notes.md`.

Use the CI toolchain, Zig `0.17.0-dev.2307+392b17125`:

```sh
zig build
zig build test
zig build test-cli
zig build run -- --config tests/fixtures/application/profile.yaml --fixtures tests/fixtures/application/success --dry-run
```

The fixture command runs without credentials or external data access after the
compiler and locked dependencies are available. For real generation, provide
`PROFILE_PAT` or `GITHUB_TOKEN` in the environment and run:

```sh
zig build run -- --config profile.yaml
```

GitHub Actions runs daily, on relevant pushes to `refactor/zig`, or by manual
dispatch. Use a separate test branch for fixture dispatch because it writes
demo data to that branch's README.

### Documentation

- [AI collaboration entry point](AGENTS.md)
- [Task workflow](docs/governance/workflow.md)
- [Engineering standards](docs/governance/engineering.md)
- [Repository rules](docs/governance/repository.md)
- [Zig implementation scope and workflow operation](docs/zig_rewrite.md)
- [Verified Zig practices](docs/zig_practices.md)

</details>
