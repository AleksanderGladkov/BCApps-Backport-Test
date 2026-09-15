# Copilot authentication smoke test

Run **Copilot authentication smoke test** manually from the fork's `main`
branch as AleksanderGladkov. It makes one tiny Copilot prompt and requires the
exact response `COPILOT_ACTIONS_AUTH_OK`.

The standalone workflow uses PowerShell on an Ubuntu GitHub-hosted runner,
Node.js 24, and pinned `@github/copilot@1.0.83`. It does not check out repository
code, allow agent tools, load repository instructions, or enable built-in MCP
servers. It has a five-minute timeout and permits only the fork owner to
dispatch or rerun it from `main`.

Authentication uses the built-in Actions `GITHUB_TOKEN`, with `contents: read`
and `copilot-requests: write`. No App installation, private key, PAT, environment
secret, or repository-write permission is required. In this personally owned
fork, usage is billed to the owner's Copilot seat. For a future organization
deployment, an organization owner must enable **Allow use of Copilot CLI billed
to the organization**.

Use the successful run's log and summary as authentication evidence. A rejected
request or unexpected response fails the job; do not substitute a PAT or weaken
policy to make it pass. Follow the reported authentication, entitlement, model,
or budget error before authorizing another run.

This is independent of the Python-to-PowerShell backport migration. It does not
change the executor, its existing workflows, or demonstration Issues/PRs, and
does not enable any inherited workflow. Success proves authentication and a
minimal model response, not conflict resolution, AL correctness, or publishing.

References:

- [Using Copilot CLI in GitHub Actions](https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli-in-actions)
- [Authentication and billing](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/copilot-cli-in-github-actions)
