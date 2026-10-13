# Neves-Labs-Infra

Infrastructure for Neves Labs.

## Infrastructure

Terraform for the Neves Labs AWS organization.

### Layout

- `organization/`: management account (211125623243). Member accounts, the `Clients` OU, SSO access, and budgets.
- `bootstrap/`: the Terraform state bucket, in the Neves-Labs account.

### Before the first apply

- Confirm the plus-addresses you plan to use aren't already used by any AWS account.
- Set `sso_user_name = "<your Identity Center user name>"` in `organization/terraform.tfvars`.
- The plan must show the existing `Clients` OU (`ou-3bja-eq1u7cmv`) as an **import**, never a create or replace.

### Not managed here

- OU `Sandbox`
- The suspended `mhh-prod` account
- The pre-existing budgets "Max Monthly Spendeture" and "My Zero-Spend Budget"

### First-time order

1. `aws login` / SSO into the management account.
2. Copy `organization/terraform.tfvars.example` to `organization/terraform.tfvars` and fill it in.
   The file is gitignored; never commit real emails or the SSO user name, the repo is public.
3. In `organization/`, run `terraform init && terraform plan && terraform apply` (local state).
4. Read `terraform output account_ids`.
5. In `bootstrap/`, run `terraform init && terraform apply -var state_account_id=<Neves-Labs account id>`.
6. Migrate both states to the bucket. TODO: documented by ticket 05 (state migration); replace this line when it lands.

### Changing an account email

Terraform ignores `email`, so editing tfvars alone changes nothing in AWS.

1. Enable trusted access for AWS Account Management once. It is currently not enabled:

   ```sh
   aws organizations enable-aws-service-access --service-principal account.amazonaws.com
   ```

2. From the management account, run `aws account start-primary-email-update`, then `aws account accept-primary-email-update`.
3. Update the email in tfvars.

### Accounts can't be destroyed

Every account has `prevent_destroy`, so Terraform refuses to destroy one. Closing an account is a manual step in AWS.

### `~/.aws/config`

Add one profile per account. The `sso-session tutorlink` block must already exist.

```ini
[profile Neves-Labs]
sso_session = tutorlink
sso_account_id = <Neves-Labs id from terraform output account_ids>
sso_role_name = AdministratorAccess
region = us-east-1

[profile tutorlink-prod]
sso_session = tutorlink
sso_account_id = <tutorlink-prod id from terraform output account_ids>
sso_role_name = AdministratorAccess
region = us-east-1

[profile tn-cleaning-prod]
sso_session = tutorlink
sso_account_id = <tn-cleaning-prod id from terraform output account_ids>
sso_role_name = AdministratorAccess
region = us-east-1
```

### CI

`.github/workflows/terraform.yml` runs on pull requests and pushes to `main`, once for `organization/` and once for
`bootstrap/`:

- `terraform fmt -check -recursive`
- `terraform init -backend=false`
- `terraform validate`
- `tflint --init` and `tflint`, configured by `.tflint.hcl` (the `terraform` recommended preset and the `aws` ruleset)
- `terraform test`

CI has no AWS credentials and no secrets, and never touches AWS. Dependabot checks the Terraform providers in both
roots weekly, alongside the GitHub Actions versions.

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

### Forks and Dependabot

PRs from forks and runs triggered by Dependabot have no access to `PROJECT_TOKEN`, so they skip with a green run and
one notice:

- `skip (fork PR: PROJECT_TOKEN unavailable)`
- `skip (Dependabot: PROJECT_TOKEN unavailable)`

Status is not synced for them.

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

   For same-repo events, if the secret is missing the run fails with `PROJECT_TOKEN secret is not set`.
   Fork PRs and Dependabot runs skip instead (see below).

3. **Dependabot**: `.github/dependabot.yml` checks GitHub Actions versions weekly.

### Reading the run log

Open the **Actions** tab, then the **Project status** workflow, then a run. Each run writes one notice per issue in the
run summary's **Annotations**, for example:

- `#3: set Blocked`
- `#3: skip (closed)`
- `#3: skip (already In Progress)`
- `#3: skip (no blocked label and Status is Todo, not Blocked)`
- `skip (fork PR: PROJECT_TOKEN unavailable)`
- `skip (Dependabot: PROJECT_TOKEN unavailable)`

A run with no notices ignored the event (for example, a label other than `blocked`). A failed run means a GraphQL
or API error, usually a token that lacks access to the project.
