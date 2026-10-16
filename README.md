# Neves-Labs-Infra

Infrastructure for Neves Labs.

## Infrastructure

Terraform for the Neves Labs AWS organization.

### Layout

- `organization/`: management account (211125623243). Member accounts, the `Clients` OU, SSO access, and budgets.
- `bootstrap/`: the Terraform state bucket, in the Neves-Labs account.
- `network/`: shared VPC in the Neves-Labs account (277396470866). Private subnets, the `neves-labs-pg` security group and DB subnet group. No NAT or internet gateway.
- `database/`: the shared RDS PostgreSQL instance `neves-labs-pg` in the Neves-Labs account (277396470866), in the shared VPC, pinned to AZ ID `use1-az1`.

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
3. The state bucket doesn't exist yet, so force local state until it does. In both `organization/` and `bootstrap/`,
   create `backend_override.tf` (gitignored via `*_override.tf`) containing:

   ```hcl
   terraform {
     backend "local" {}
   }
   ```

   If `organization/` was already applied with local state, this keeps that state; `terraform init` in the next step picks it up.
4. In `organization/`, run `terraform init && terraform plan && terraform apply` (skip the apply if it is already applied).
5. Read `terraform output account_ids`.
6. In `bootstrap/`, run `terraform init && terraform apply`.
7. Migrate both states to the bucket:
   1. Delete `backend_override.tf` in both directories.
   2. In `organization/`, then in `bootstrap/`, run `terraform init -migrate-state` and answer `yes` to copy the state.
   3. If an `errored.tfstate` file appears in either directory, the migration failed: stop and delete nothing.
   4. In each directory, run `terraform plan` against the new backend and confirm it reports "No changes". Also check `terraform state list`.
   5. Only then delete the local `terraform.tfstate` and `terraform.tfstate.backup` files in both directories.

   After this, `terraform init` works as usual everywhere.

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

### Operator notes

- Run scripts with `bash x.sh`, never `source x.sh`: a failing sourced script closes the terminal.
- Use single-line commands or script files. Long multi-line pastes get mangled in the macOS bash 3.2 terminal.
- Systems Manager port-forward tunnels open but never forward on Franklin's Mac, so database work runs on servers
  through Run Command (`database/bootstrap-client.sh` and `database/set-database-url.sh`).
- Franklin runs `terraform apply` in his own console. Claude Code's `!` prompt has no TTY to confirm an apply.
- `aws login` (management account, default profile) and `aws sso login --sso-session tutorlink` both expire
  mid-session. Refresh them before long steps.
- The `neves-labs-pg` instance is only visible with `--profile Neves-Labs`.
- Lifting deletion protection is a manual step for Franklin: the agent auto-mode safety check blocks it.
- Keep AWS CLI command history off (`cli_history` in `~/.aws/config` is off by default). When it is on, the CLI saves
  `put-parameter` values in plaintext, and that includes the connection string.

### Network (`network/`)

1. `aws login` into the management account (default profile). The root assumes `OrganizationAccountAccessRole` in
   Neves-Labs, and state already lives in the bucket, so no bootstrap or override is needed.
2. `cd network && terraform init && terraform plan`.
3. Check that the plan holds only the following and nothing else, with no replaces of the VPC, subnets or DB subnet
   group: the VPC, 2 subnets, the route table and 2 associations, the default security group takeover, the default
   network ACL takeover (both subnets), the `neves-labs-pg` security group, the DB subnet group, and per
   `client_peerings` entry one peering accepter, one route and one 5432 ingress rule. The plan fails while a client's
   `peering_connection_id` is still the placeholder, or when the peering wasn't requested by that client's account and
   VPC range; see [Adding a client](#adding-a-client), step 3.
4. `terraform apply`.
5. Run `terraform output` and record `vpc_id`, `private_subnet_ids`, `private_route_table_id`,
   `postgres_security_group_id` and `db_subnet_group_name`. Other roots and the TutorLink repo hard-code these values;
   nothing reads this state remotely.

Reserved CIDRs:

| Range | Use |
|---|---|
| 10.10.0.0/16 | Neves-Labs shared VPC |
| 10.20.0.0/16 | tutorlink-prod |
| 10.30.0.0/16 | tn-cleaning-prod |
| 172.31.0.0/16 | default VPC, avoid |

Adding a client means reserving its CIDR in `reserved_cidrs` and, once its peering exists, adding a `client_peerings`
entry in `network/`. Only the `client_peerings` entry opens 5432, and only from the client's app subnet. See
[Adding a client](#adding-a-client) for the full checklist.

Notes:

- The VPC, subnets and DB subnet group have `prevent_destroy`.
- Subnets are pinned by AZ ID (`use1-az1`, `use1-az2`), because AZ names differ between accounts.

### Database (`database/`)

1. `aws login` into the management account. The root assumes `OrganizationAccountAccessRole` in Neves-Labs.
2. `cd database && terraform init && terraform plan`.
3. Check that the plan creates only the parameter group `neves-labs-pg-postgres17`, the instance `neves-labs-pg`, the
   admin password and one random password per client in `clients`, with no replaces. With the current map that is
   2 passwords in total.
4. `terraform apply`.
5. Record `terraform output address` and `availability_zone_id`. The passwords are kept in state: the admin's is
   `terraform output -raw admin_password`, and one client's is
   `terraform output -json client_passwords | jq -r .<client>`. Read one client at a time; don't print the whole map.
6. Once the client's peering is active, create its login role and database with
   `database/bootstrap-client.sh <client> <aws-profile> <instance-id> <parameter-prefix>`. It needs `aws login` for
   the management account (it reads terraform) and a login for `<aws-profile>`. It runs
   `database/sql/client.sql` as `neveslabs_admin` on a host in the client's account through Systems Manager Run
   Command, so nothing on your machine connects to the database. The host needs the prerequisites in
   [Adding a client](#adding-a-client), step 4, substep 3. Re-running it is safe. It refuses a role that it didn't create
   (marked by the comment `Managed by database/sql/client.sql`) and a same-named database the client doesn't own.
7. To move a client's existing data onto `neves-labs-pg`, see
   [Moving a client's existing data](#moving-a-clients-existing-data).

Notes:

- Each client gets its own database and login role, never a schema in another client's database. No client role is the
  server's admin, which is `neveslabs_admin`.
- TLS is enforced (`rds.force_ssl = 1`), so clients connect with `sslmode=require` or stricter.
- The server allows about 80 connections in total. Each client has a `connection_limit` in `clients`: `tutorlink` is
  capped at 30 and the default is 10. The plan fails when the limits add up to more than 70, which leaves the rest as
  headroom for admin and the reserved slots.
- Backups are kept 7 days (point-in-time restore). Database Insights standard mode is on (the free 7-day tier).
- Deletion protection is on, and the final snapshot is `neves-labs-pg-final`.
- No RDS Proxy (TutorLink's chat LISTEN connection).

Security notes:

- Read the admin password on demand with `terraform output -raw admin_password`, and a client's password with
  `terraform output -json client_passwords | jq -r .<client>`, one client at a time.
- Never paste the admin or a client password into files, chats, tickets or shell history.
- If a stored copy is needed, keep it in a password manager only. The one exception is the app's connection string,
  which goes in a SecureString parameter in the client's account (see [Adding a client](#adding-a-client), step 4).
- `database/bootstrap-client.sh` briefly stages the `neves-labs-pg` admin password, which reaches every client's
  database, as a SecureString parameter in the client's account. That account's admins and the client server's role
  can read it while it is staged, and so can any process on the client host, including the client's app and
  containers on the host network (bridge-network containers can't when the instance requires IMDSv2 and its metadata hop limit is 1). The
  script deletes it on exit. This is accepted because clients have no access
  to their AWS accounts: Franklin manages them. Revisit it if a client ever gets AWS access.
- `database/sql/client.sql` sends the password in plaintext `CREATE ROLE` / `ALTER ROLE` statements. Keep
  `log_statement = none` and pgaudit role logging off on `neves-labs-pg`, or every client password lands in the RDS
  logs.
- Anyone who can read the state bucket `neves-labs-tfstate-277396470866` (`database/terraform.tfstate`) can read every
  database password, so treat read access to that bucket as database admin access.

### Adding a client

Work through these in order. Each step ends with a plan you read before applying.

1. **`organization/`**: add the client's account.
   - Add an entry to `accounts` in `organization/main.tf` with an `email_key`, a `parent_id` of the `Clients` OU
     (`aws_organizations_organizational_unit.clients.id`) and a `monthly_limit_usd`.
   - Add the matching key to `account_emails` in `organization/terraform.tfvars` and in
     `organization/terraform.tfvars.example` (a placeholder email only, the repo is public). The plan fails when the
     keys of `account_emails` don't match the `email_key` of every account.
   - Add the same key, with a placeholder email, to `account_emails` in the `variables` block at the top of
     `organization/tests/organization.tftest.hcl`. The tests fail on the same key check otherwise.
   - Run `terraform plan`, then `terraform apply`. Accounts can't be destroyed, see
     [Accounts can't be destroyed](#accounts-cant-be-destroyed).
   - Add a profile for the new account to [`~/.aws/config`](#awsconfig), with its id from
     `terraform output account_ids`.
2. **`network/`**: add the client's range to `reserved_cidrs` in `network/locals.tf`.
   - It must not overlap the other ranges; the network test checks this.
   - Add a row to the Reserved CIDRs table in the Network section.
   - This reserves the range only; it opens nothing. Postgres opens in step 3.
   - Run `terraform plan`, then `terraform apply`.
3. **Peering**: the client repo requests the peering, then `network/` accepts it.
   - Apply the client repo first and read its `terraform output peering_connection_id` (TutorLink: `infra/`).
   - Add an entry to `client_peerings` in `network/variables.tf`, keyed like `reserved_cidrs`, with that
     `peering_connection_id`, the client's `app_subnet_cidr` (inside its reserved range) and its
     `requester_account_id` (the client account's ID, from `terraform output account_ids` in `organization/`).
   - Before accepting, the plan reads the peering from AWS and fails unless it was requested from that account, from a
     VPC whose range is the client's reserved range, toward the shared VPC. A wrong or foreign `pcx-` ID never gets
     accepted.
   - The entry accepts the peering, routes the client's reserved range through it, and opens 5432 from the app subnet
     in both the `neves-labs-pg` security group and the default network ACL.
   - Run `terraform plan`, then `terraform apply`.
4. **`database/`** (only if the client needs Postgres):
   1. Add an entry to `clients` in `database/variables.tf`, for example `acme = { connection_limit = 20 }`.
      - `connection_limit` is optional and defaults to 10.
      - The limits of all clients must total at most 70.
      - The name uses lowercase letters, digits and underscores, starts with a letter, has at most 63 characters, does
        not start with `pg_` or `rds`, and is not `postgres`, `neveslabs_admin`, `template0`, `template1` or `public`.
   2. Run `terraform plan`. Expect exactly one new password and no replaces. Then `terraform apply`.
   3. Once the peering from step 3 is active, bootstrap the client from a host in its account. The host must:
      - be an online Systems Manager managed node, with Docker and the AWS CLI installed
      - sit in the client's app subnet (`app_subnet_cidr`), the only source that step 3 allows to reach port 5432
      - have an instance role that reads the parameters under `<parameter-prefix>*` (which covers the temporary
        `<parameter-prefix>-bootstrap/` parameters) and decrypts with the key of those parameters

      Then run:

      ```sh
      database/bootstrap-client.sh <client> <aws-profile> <instance-id> <parameter-prefix>
      ```

      For tutorlink that is `database/bootstrap-client.sh tutorlink tutorlink-prod <instance-id> /tutorlink/prod`.
      The script stages the admin and client passwords as temporary SecureString parameters under
      `<parameter-prefix>-bootstrap/`, runs `database/sql/client.sql` on the host through Run Command, and deletes the
      parameters on exit. It prints the `\du` and `\l` output for the client. Check that:
      - the role has no Superuser, Create role or Create DB attribute, and the connection limit is the one in `clients`
      - the database is owned by the client
      - the access privileges are `<client>=CTc/<client>` only, with no PUBLIC `=c/` entry

      Re-running it is safe. If it warns that it couldn't delete the temporary parameters, run the
      `aws ssm delete-parameters` command it prints.
   4. Store the app's connection string with:

      ```sh
      database/set-database-url.sh <client> <aws-profile> <parameter-name> [scheme]
      ```

      The value is `<scheme>://<client>:<password>@<address>:5432/<client>?sslmode=require`. The scheme defaults to
      `postgresql`; pass another as the fourth argument, for example `postgresql+psycopg`. The parameter name must start
      with `/<client>/` (underscores in the client name may be hyphens). The script writes a SecureString parameter in
      the client's account through a private temporary file and prints only `<parameter-name> set, version <N>`, so the
      password never reaches a repo, a chat or the command line. The password logging warning in the Database security
      notes applies to every client.

Removing a client from `clients` fails the plan on purpose (`prevent_destroy`). Offboarding isn't automated.

### Moving a client's existing data

This is the pattern the tutorlink move used in October 2026. It needs no scripts in this repo. Dumps never go in the
repo (`*.dump` is gitignored), and the downtime plan and any app-specific steps live in the client's repo.

1. Stage the passwords as `database/bootstrap-client.sh` does: temporary SecureString parameters in the client account.
2. On the old host, run `pg_dump -Fc` in `postgres:17-alpine` with `--network host`, and record the dump's sha256.
   Write the dump into a private directory (`umask 077`, or `chmod 700`) and delete it afterwards. Read the old
   database password from Systems Manager on the host into the container's environment (`-e PGPASSWORD` with no
   value); never type it or put it on a command line.
3. Upload the dump with a 15-minute presigned PUT to a temporary private S3 bucket in the client account. The bucket
   has Block Public Access on and no policy that grants outside access.
4. On the new host, download it with a 15-minute presigned GET and verify the sha256. Presigned URLs are bearer
   credentials and show in the Run Command history while valid, so keep them short-lived.
5. Run `pg_restore --no-owner --no-privileges` as the client role.
6. Compare per-table row counts from both hosts. Drop blank and whitespace-only lines when parsing Run Command output;
   that bit the tutorlink move.
7. Delete the dumps on both hosts, the bucket and the staged parameters.

### CI

`.github/workflows/terraform.yml` runs on pull requests and pushes to `main`, once for `organization/`, once for
`bootstrap/`, once for `network/` and once for `database/`:

- `terraform fmt -check -recursive`
- `terraform init -backend=false`
- `terraform validate`
- `tflint --init` and `tflint`, configured by `.tflint.hcl` (the `terraform` recommended preset and the `aws` ruleset)
- `terraform test`

A separate `shellcheck` job lints every committed shell script and runs the stub tests
(`bash database/tests/scripts/run-tests.sh`), which replace `aws`, `terraform`, `docker`, `jq` and `sleep` with stubs.

CI has no AWS credentials and no secrets, and never touches AWS. Dependabot checks the Terraform providers in all four
roots (`organization/`, `bootstrap/`, `network/`, `database/`) weekly, alongside the GitHub Actions versions.

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
