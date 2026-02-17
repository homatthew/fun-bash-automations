"""Ralph Wiggum CLI — typer app with subcommands.

Bare `ralph` invokes interactive plan picker.
`ralph somefile.md` is a shortcut for `ralph run somefile.md`.
"""

import typer
from typer.core import TyperGroup

from ralph.init_cmd import init
from ralph.inject import inject
from ralph.logs import logs
from ralph.run import run
from ralph.status import status


class DefaultRunGroup(TyperGroup):
    """Typer group that routes unknown subcommands to 'run'."""

    def parse_args(self, ctx, args):
        # If first arg is not a known subcommand, prepend "run"
        if args and args[0] not in self.commands and not args[0].startswith("-"):
            args = ["run"] + args
        return super().parse_args(ctx, args)


app = typer.Typer(
    cls=DefaultRunGroup,
    help="Ralph Wiggum — Autonomous Claude Code Loop",
    invoke_without_command=True,
    no_args_is_help=False,
)

app.command()(run)
app.command()(init)
app.command()(inject)
app.command()(status)
app.command()(logs)


@app.callback()
def main(ctx: typer.Context) -> None:
    """Ralph Wiggum — Autonomous Claude Code Loop."""
    if ctx.invoked_subcommand is None:
        # Bare `ralph` with no args → invoke run (interactive picker)
        ctx.invoke(run, plan=None, max_iter=10, tools=None, no_tui=False, no_sandbox=False)
