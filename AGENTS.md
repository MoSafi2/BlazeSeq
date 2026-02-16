# Agent instructions for BlazeSeq

## Running Mojo code

**Always run Mojo files using pixi:**

```bash
pixi run mojo run [file]
```

Examples:

- Run a script: `pixi run mojo run test_file.mojo`
- Run an example: `pixi run mojo run examples/example_parser.mojo`
- Run tests: `pixi run test`

Use this command every time you need to execute a `.mojo` file in this project; do not use a bare `mojo run` or `mojo test` unless the user explicitly asks otherwise.
