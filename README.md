# Neves-Labs-Infra

Infrastructure for Neves Labs.

## Project automations

The workflow `.github/workflows/project-status.yml` keeps the **Status** field of the org project
"Neves Labs infrastructure" (Neves-Labs-Inc project #6) in sync with issue activity in this repo.

### `blocked` label

- Adding the `blocked` label (any case) to an issue sets its Status to **Blocked**.
- Removing the label sets Status to **In Progress**, but only when the current Status is Blocked.
  If someone has already moved the card elsewhere, it is left alone.
- Closed issues and items whose Status is **Done** are never changed.
- Issues that aren't in project #6 are skipped. Other labels are ignored, and the run makes no changes.

### Work started

- Creating a branch whose name starts with an issue number sets that issue's Status to **In Progress**.
  Name branches `<N>-slug` or `<prefix>/<N>-slug`, for example `6-billing-split` or `feat/6-billing`.
  `main`, `feat/billing`, and a bare `6` link to no issue. Tags are ignored.
- Opening or reopening a pull request (draft or ready) does the same for every issue it links: those named by a
  closing keyword in the description (`close`, `fix`, `resolve` and their variants, followed by `#N`) and the one
  in the head branch name. References to other repos (`other/repo#N`) are ignored.
- Any Status except **Done** moves to In Progress, including **Blocked** even if the `blocked` label is still on.
- Closed issues, items already In Progress, and issues that aren't in project #6 are skipped.
- A branch event and a label change on the same issue can race; the later write wins.

### Setup

1. **Label**

   ```sh
   gh label create blocked -R Neves-Labs-Inc/Neves-Labs-Infra --color B60205 --description "Work is blocked"
   ```

2. **Token**: the workflow uses the org-wide secret `PROJECT_TOKEN`. The token behind it needs:
   - Resource owner: `Neves-Labs-Inc`
   - Repository access that includes `Neves-Labs-Infra`
   - Repository permissions: Issues (read), Pull requests (read), Metadata (read)
   - Organization permissions: Projects (read & write)

   The org secret's repository access must include `Neves-Labs-Infra`. To override it for this repo only, set a repository secret with the same name:

   ```sh
   gh secret set PROJECT_TOKEN -R Neves-Labs-Inc/Neves-Labs-Infra
   ```

   If the secret is missing, the run fails with `PROJECT_TOKEN secret is not set`.

### Reading the run log

Open the **Actions** tab, then the **Project status** workflow, then a run. Each run writes one notice per issue in the
run summary's **Annotations**, for example:

- `#3: set Blocked`
- `#3: skip (closed)`
- `#3: skip (already In Progress)`
- `#3: skip (no blocked label and Status is Todo, not Blocked)`

A run with no notices ignored the event (for example, a label other than `blocked`). A failed run means a GraphQL
or API error, usually a token that lacks access to the project.
