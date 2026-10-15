# TutorLink cutover to `neves-labs-pg`

Moves TutorLink's data from the old `tutorlink` RDS instance in the management account to its own database on the
shared `neves-labs-pg` instance in Neves-Labs. Part of #4. Nothing can reach `neves-labs-pg` until the tutorlink-prod
peering from #4 is active. The window also moves TutorLink's Elastic IP to tutorlink-prod, so the sslip.io URL stays
the same.

The laptop is the hop between the two accounts: the dump lands in a local file and is restored from there. No S3
bucket is involved.

## Facts

- `neves-labs-pg` sits in availability zone ID `use1-az1`. Pin tutorlink-prod's EC2 to the same availability zone
  ID, so queries don't cross zones. Availability zone names differ between accounts, so match on the ID.
- The server allows about 80 connections in total, across every client. The `tutorlink` role is capped at 30.
- The server enforces TLS (`rds.force_ssl = 1`), so every connection below uses `sslmode=require`.
- Each client gets its own database and login role, never a schema in another client's database.
- `database/sql/client.sql` sends the password in plaintext `CREATE ROLE` / `ALTER ROLE` statements. Keep
  `log_statement = none` (`mod` and `ddl` both log role statements) and pgaudit role logging off on
  `neves-labs-pg`, or the password lands in the RDS logs.

## Prerequisites

Do these in order, before the window. Nothing here needs downtime.

1. Add the `tutorlink-prod` profile (account 046451670022) to `~/.aws/config`, as in the README.
2. In TutorLink `infra/bootstrap`, run `terraform apply` with `AWS_PROFILE=tutorlink-prod`. Every TutorLink
   `terraform` command in this runbook runs with that profile.
3. In TutorLink `infra/`, run apply 1 (`AWS_PROFILE=tutorlink-prod`) with `elastic_ip_allocation_id` unset. Record the `instance_id` and
   `peering_connection_id` outputs.
   - The local `infra/.terraform/` still points at the old state bucket in the management account. Initialise
     against the new backend with `-reconfigure` before apply 1:

     ```sh
     AWS_PROFILE=tutorlink-prod terraform -chdir=infra init -reconfigure
     ```

   - **Never answer "yes" to a prompt to copy or migrate existing state** (from this init, or from a plain
     `terraform init` run by mistake). It would copy the old state, with the old database passwords and the live
     `SECRET_KEY`, into the new bucket. If such a prompt appears, answer "no", delete `infra/.terraform/` and run the
     command above again.
4. In `network/`, paste the peering ID into the `tutorlink-prod` entry of `client_peerings` (`network/variables.tf`),
   then plan and apply.
   - TutorLink's apply goes first: the plan reads the pending peering from AWS, so it fails on a placeholder or
     unknown ID.
   - The entry already holds `requester_account_id` (046451670022) and `app_subnet_cidr` (10.20.0.0/24). The plan's
     precondition fails unless the peering was requested by that account, from the 10.20.0.0/16 VPC, toward the shared
     VPC.
   - The apply accepts the peering, adds the route, and opens 5432 from the app subnet in the `neves-labs-pg` security
     group and the default network ACL (rule number 210).
   - Confirm the peering is `active`. A pending request expires after 7 days, so do this within 7 days of step 3.
5. `database/` is applied (`terraform -chdir=database output` shows `address`).
6. Copy these parameters from the management account into tutorlink-prod: `SECRET_KEY`, `TWILIO_ACCOUNT_SID`,
   `TWILIO_AUTH_TOKEN`, `TWILIO_WHATSAPP_NUMBER`, `ANTHROPIC_API_KEY`, `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`,
   `SMTP_PASSWORD` and `MAIL_FROM`.
   - Run this in **work**. It is self-contained: `jq` builds the JSON (and escapes the value), the file lives in a
     private directory, and the value never appears on a command line. It runs in a subshell and stops at the first
     parameter that fails to copy, printing its name. Copying again is safe, so fix the cause and rerun the whole
     block. Each entry in `COPIED_PARAMETERS` is a name and its type, and each type matches TutorLink `infra/ssm.tf`,
     so apply 2 sees no type drift. The subshell lets a failure end the copy without closing the terminal, and its
     `EXIT` trap removes the file even if the copy is interrupted. The blocks carry no `#` comments on purpose:
     interactive zsh runs them as commands, so keep explanations in the prose.

     ```sh
     umask 077
     CUTOVER_DIR="$HOME/tutorlink-cutover"
     mkdir -p "$CUTOVER_DIR" && chmod 700 "$CUTOVER_DIR"

     COPIED_PARAMETERS=(SECRET_KEY:SecureString TWILIO_ACCOUNT_SID:SecureString TWILIO_AUTH_TOKEN:SecureString
       TWILIO_WHATSAPP_NUMBER:String ANTHROPIC_API_KEY:SecureString SMTP_HOST:String SMTP_PORT:String
       SMTP_USERNAME:String SMTP_PASSWORD:SecureString MAIL_FROM:String)

     (
       set -o pipefail
       trap 'rm -f "$CUTOVER_DIR/param.json"' EXIT
       if [ "${#COPIED_PARAMETERS[@]}" -ne 10 ]; then
         echo "COPIED_PARAMETERS holds ${#COPIED_PARAMETERS[@]} entries, not 10: paste this block again." >&2
         exit 1
       fi
       for entry in "${COPIED_PARAMETERS[@]}"; do
         p="${entry%%:*}"
         type="${entry#*:}"
         aws ssm get-parameter --name "/tutorlink/prod/$p" --with-decryption --output json \
           | jq -e --arg type "$type" \
               '{Name: .Parameter.Name, Type: $type, Overwrite: true, Value: .Parameter.Value}' \
           > "$CUTOVER_DIR/param.json" \
           && aws ssm put-parameter --profile tutorlink-prod --cli-input-json "file://$CUTOVER_DIR/param.json" \
             --query Version --output text
         copy_status=$?
         rm -f "$CUTOVER_DIR/param.json"
         if [ "$copy_status" -ne 0 ]; then
           echo "Copy failed at $p; nothing after it was copied." >&2
           exit 1
         fi
       done
     )
     ```

   - Then check that none of them still holds the `unset` placeholder. This compares inside the AWS CLI query and
     prints only each name with `True` (still unset) or `False`, never a value. It refuses to run unless
     `COPIED_PARAMETERS` holds all 10 entries, so a broken paste can't pass with no lines at all:

     ```sh
     if [ "${#COPIED_PARAMETERS[@]}" -ne 10 ]; then
       echo "COPIED_PARAMETERS holds ${#COPIED_PARAMETERS[@]} entries, not 10: rerun the copy block first." >&2
     else
       for entry in "${COPIED_PARAMETERS[@]}"; do
         p="${entry%%:*}"
         printf '%s still unset: ' "$p"
         aws ssm get-parameter --profile tutorlink-prod --name "/tutorlink/prod/$p" --with-decryption \
           --query "Parameter.Value == 'unset'" --output text
       done
     fi
     ```

     Expect exactly 10 lines, each ending in `False`. A `True` means the management account itself holds `unset` for that
     parameter; set the real value in tutorlink-prod before the window.

   - Each parameter keeps the type TutorLink's `infra/ssm.tf` gives it: `TWILIO_WHATSAPP_NUMBER`, `SMTP_HOST`,
     `SMTP_PORT`, `SMTP_USERNAME` and `MAIL_FROM` are `String`, the rest `SecureString`. A different type here shows
     up as extra parameter changes in the apply 2 plan, mid-outage.
   - `SECRET_KEY` is write-only in TutorLink's Terraform, so only this copy sets it.
7. Set the TutorLink GitHub repo variables `AWS_DEPLOY_ROLE_ARN`, `ECR_API_REPO` and `ECR_WEB_REPO` from TutorLink's
   `infra/` outputs. `AWS_REGION` and `SITE_URL` stay as they are. Otherwise the Deploy run in step 7 targets the old
   EC2 and restarts the old `api` against the old database, after the dump.
8. Merge nothing to TutorLink `main` until the cutover ends, so no Deploy runs against a half-moved setup.

A tutorlink-prod host must also be reachable by SSM. The laptop has:

- the PostgreSQL 17 client tools (`psql`, `pg_dump`, `pg_restore`)
- `jq`
- the AWS CLI and the Session Manager plugin
- the management account as the default profile, and the `tutorlink-prod` profile from the README

## Terminals

The cutover uses three terminals, all opened in the repo root:

| Terminal | Runs |
|---|---|
| **forward-new** | the port-forward to `neves-labs-pg` on local port 15432, through the tutorlink-prod host (step 1) |
| **forward-old** | the port-forward to the old `tutorlink` RDS instance on local port 15433, through the old EC2 (step 3) |
| **work** | every other command |

Production data and scratch files go in a private directory outside the repo, never in the working tree. Paste
this into **work** first. `old_db_password` reads the old password out of the management account DATABASE_URL
(`postgresql+psycopg://tutorlink:<password>@...`):

```sh
umask 077
CUTOVER_DIR="$HOME/tutorlink-cutover"
mkdir -p "$CUTOVER_DIR" && chmod 700 "$CUTOVER_DIR"

NEW_HOST_ID=<tutorlink-prod instance id>
OLD_HOST_ID=<old EC2 instance id>

NEW_DB="host=localhost port=15432 dbname=tutorlink user=tutorlink sslmode=require"
OLD_DB="host=localhost port=15433 dbname=tutorlink user=tutorlink sslmode=require"

old_db_password() {
  aws ssm get-parameter --name /tutorlink/prod/DATABASE_URL --with-decryption \
    --query Parameter.Value --output text | sed -E 's#^[^:]+://[^:]+:([^@]+)@.*$#\1#'
}

tutorlink_password() { terraform -chdir=database output -json client_passwords | jq -r .tutorlink; }
```

Secrets only ever come from `terraform output` (directly or through `tutorlink_password`) or an SSM parameter, and
`PGPASSWORD` is set per command rather than exported, so no password lands in shell history or lingers in a shell.
Replace `<...>` placeholders with real values.

## 1. Bootstrap (before the window)

In **forward-new**, open the port-forward to `neves-labs-pg` and leave it running until step 9:

```sh
NEW_HOST_ID=<tutorlink-prod instance id>
PG_ADDRESS="$(terraform -chdir=database output -raw address)"
aws ssm start-session --profile tutorlink-prod \
  --target "$NEW_HOST_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$PG_ADDRESS\"],\"portNumber\":[\"5432\"],\"localPortNumber\":[\"15432\"]}"
```

In **work**, run the bootstrap script. It runs `database/sql/client.sql` as `neveslabs_admin`, then prints the role
and the database:

```sh
database/bootstrap-client.sh tutorlink
```

`\du` shows `tutorlink` with `30 connections` and no Superuser, Create role or Create DB attribute. `\l` shows
`tutorlink` owned by `tutorlink`, with access privileges `tutorlink=CTc/tutorlink` only and no `=c/...` (PUBLIC)
entry.

## 2. Downtime starts

Stop TutorLink's `api` container on the old EC2 in the management account. TutorLink has no read-only mode, and
WhatsApp messages sent during the window are lost. The compose file and `.env` paths are the ones TutorLink's
`deploy/remote-deploy.sh` uses.

In **work**:

```sh
aws ssm send-command \
  --instance-ids "$OLD_HOST_ID" \
  --document-name AWS-RunShellScript \
  --comment "tutorlink cutover: stop api" \
  --parameters 'commands=["docker compose -f /srv/tutorlink/app/docker-compose.prod.yml --env-file /srv/tutorlink/app/.env stop api"]' \
  --query Command.CommandId --output text
```

Check that it succeeded (`Status` is `Success`):

```sh
aws ssm get-command-invocation --instance-id "$OLD_HOST_ID" --command-id <command id from above> \
  --query '[Status,StandardOutputContent,StandardErrorContent]'
```

## 3. Dump

In **forward-old**, open the port-forward to the old RDS instance and leave it running until step 9:

```sh
OLD_HOST_ID=<old EC2 instance id>
OLD_DB_ADDRESS="$(aws rds describe-db-instances --db-instance-identifier tutorlink \
  --query 'DBInstances[0].Endpoint.Address' --output text)"
aws ssm start-session \
  --target "$OLD_HOST_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$OLD_DB_ADDRESS\"],\"portNumber\":[\"5432\"],\"localPortNumber\":[\"15433\"]}"
```

In **work**, dump as `tutorlink` into the private directory:

```sh
PGPASSWORD="$(old_db_password)" pg_dump -Fc -d "$OLD_DB" -f "$CUTOVER_DIR/tutorlink.dump"
```

## 4. Restore

In **work**, restore as `tutorlink` through the step 1 port-forward (reopen it in **forward-new** if it closed):

```sh
PGPASSWORD="$(tutorlink_password)" \
  pg_restore --no-owner --no-privileges -d "$NEW_DB" "$CUTOVER_DIR/tutorlink.dump" \
  2> "$CUTOVER_DIR/restore-errors.log"
cat "$CUTOVER_DIR/restore-errors.log"
```

Review every error in `restore-errors.log`:

- An error saying an extension or the `public` schema already exists is benign.
- Anything else is a failure: go to step 8.

## 5. Verify

In **work**, write the per-table row count query to a file. It counts every row exactly, rather than reading
planner estimates:

```sh
cat > "$CUTOVER_DIR/row-counts.sql" <<'SQL'
SELECT table_name,
       (xpath('/row/n/text()',
              query_to_xml(format('SELECT count(*) AS n FROM public.%I', table_name), false, true, '')))[1]::text::bigint
FROM information_schema.tables
WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
ORDER BY table_name;
SQL
```

Run it on old and new, and diff the results:

```sh
PGPASSWORD="$(old_db_password)" \
  psql -X "$OLD_DB" -At -f "$CUTOVER_DIR/row-counts.sql" > "$CUTOVER_DIR/counts-old.txt"

PGPASSWORD="$(tutorlink_password)" \
  psql -X "$NEW_DB" -At -f "$CUTOVER_DIR/row-counts.sql" > "$CUTOVER_DIR/counts-new.txt"

diff "$CUTOVER_DIR/counts-old.txt" "$CUTOVER_DIR/counts-new.txt" && echo "row counts match"
```

Then check the extensions and the table owners on new. The first command must list `pgcrypto` and `btree_gist`. The
second must return no rows, because every table in `public` is owned by `tutorlink`:

```sh
PGPASSWORD="$(tutorlink_password)" psql -X "$NEW_DB" -c '\dx'

PGPASSWORD="$(tutorlink_password)" psql -X "$NEW_DB" \
  -c "SELECT tablename, tableowner FROM pg_tables WHERE schemaname = 'public' AND tableowner <> 'tutorlink';"
```

Any difference, a missing extension, or a returned row is a failure: go to step 8.

## 6. Move the Elastic IP

The old site goes dark at the first command below (it is already down since step 2), and TutorLink's sslip.io URL
only works again once the address is associated with the new host in tutorlink-prod.

In **work**, with `OLD_HOST_ID` from the terminal setup:

1. Disassociate the address from the old EC2, in the management account:

   ```sh
   OLD_ALLOCATION_ID=<old Elastic IP allocation id>
   EIP_ADDRESS="$(aws ec2 describe-addresses --allocation-ids "$OLD_ALLOCATION_ID" \
     --query 'Addresses[0].PublicIp' --output text)"
   aws ec2 disassociate-address \
     --association-id "$(aws ec2 describe-addresses --allocation-ids "$OLD_ALLOCATION_ID" \
       --query 'Addresses[0].AssociationId' --output text)"
   ```

2. Offer it to tutorlink-prod:

   ```sh
   aws ec2 enable-address-transfer --allocation-id "$OLD_ALLOCATION_ID" --transfer-account-id 046451670022
   ```

3. Accept it there:

   ```sh
   aws ec2 accept-address-transfer --address "$EIP_ADDRESS" --profile tutorlink-prod
   ```

4. Read the new allocation ID (the transfer assigns a new one):

   ```sh
   aws ec2 describe-addresses --public-ips "$EIP_ADDRESS" --profile tutorlink-prod \
     --query 'Addresses[0].AllocationId' --output text
   ```

5. In TutorLink `infra/`, run apply 2 (`AWS_PROFILE=tutorlink-prod`) with `elastic_ip_allocation_id` set to that ID. Read the plan first: it shows
   the address imported (with an in-place tag update), the association and the `SITE_ADDRESS` parameter created,
   and nothing destroyed. If anything is destroyed, don't
   apply: go to step 8, "After the transfer was accepted", and skip its steps 1 to 3.
6. Check that the address is on the new instance:

   ```sh
   aws ec2 describe-addresses --public-ips "$EIP_ADDRESS" --profile tutorlink-prod \
     --query 'Addresses[0].[AllocationId,InstanceId]'
   ```

   `InstanceId` must be the `instance_id` from prerequisite 3.

Notes:

- The default quota is 5 Elastic IP addresses per account; check that tutorlink-prod has room before the window.
- An offered transfer expires after 7 days if nobody accepts it.

## 7. Switch

In **work**, confirm the deploy role lives in tutorlink-prod. The account ID inside the ARN must be tutorlink-prod's
(`terraform -chdir=organization output account_ids`); if it isn't, stop and go to step 8:

```sh
gh variable get AWS_DEPLOY_ROLE_ARN -R Neves-Labs-Inc/TutorLink
```

Set `DATABASE_URL` in tutorlink-prod. It overwrites the placeholder TutorLink's `infra/` created. The value goes through a private file rather than the command line, so the
password never appears in history or in the process list:

```sh
PG_ADDRESS="$(terraform -chdir=database output -raw address)"
printf '{"Name":"/tutorlink/prod/DATABASE_URL","Type":"SecureString","Overwrite":true,"Value":"postgresql+psycopg://tutorlink:%s@%s:5432/tutorlink?sslmode=require"}' \
  "$(tutorlink_password)" "$PG_ADDRESS" \
  > "$CUTOVER_DIR/database-url.json"

aws ssm put-parameter --profile tutorlink-prod --cli-input-json "file://$CUTOVER_DIR/database-url.json"
rm "$CUTOVER_DIR/database-url.json"
```

The password has no special characters, so it goes into the URL and the JSON unescaped.

Start the app there: run TutorLink's **Deploy** workflow from `main`. It builds the images into the still-empty
tutorlink-prod ECR repositories, writes `.env` from SSM, runs the migrations (a no-op on the restored schema) and
starts the containers.

```sh
gh workflow run deploy.yml -R Neves-Labs-Inc/TutorLink --ref main
```

Then run the smoke checks from TutorLink#179:

- [ ] `<site url>/health/ready` answers ready.
- [ ] Log in.
- [ ] Send a WhatsApp booking and see it land.
- [ ] Open a chat and check that messages arrive live, which proves the LISTEN connection works over the peering.

## 8. Rollback

If verify or the smoke checks fail, or the Elastic IP plan wants to destroy anything, roll back. The branch depends on
whether tutorlink-prod already accepted the transfer (step 6.3 done).

### Before the transfer was accepted

Start the old `api` container again:

```sh
aws ssm send-command \
  --instance-ids "$OLD_HOST_ID" \
  --document-name AWS-RunShellScript \
  --comment "tutorlink cutover: rollback, start api" \
  --parameters 'commands=["docker compose -f /srv/tutorlink/app/docker-compose.prod.yml --env-file /srv/tutorlink/app/.env start api"]' \
  --query Command.CommandId --output text
```

If step 6 got as far as the offer (6.2), cancel it first, so it can't still be accepted and the address can be
associated:

```sh
aws ec2 disable-address-transfer --allocation-id "$OLD_ALLOCATION_ID"
```

If the address was disassociated (6.1), associate it with the old EC2 again before starting the `api`:

```sh
aws ec2 associate-address --allocation-id "$OLD_ALLOCATION_ID" --instance-id "$OLD_HOST_ID"
```

### After the transfer was accepted

If apply 2 never ran (you stopped at the 6.5 plan), skip steps 1 to 3: nothing is associated and nothing is in
TutorLink's state. Start at step 4.

Do these in order:

1. Stop the new containers in tutorlink-prod, so only one copy of TutorLink is live. If step 7's Deploy never ran,
   skip this: nothing is running, and the command would only fail on the missing compose file.

   ```sh
   aws ssm send-command --profile tutorlink-prod \
     --instance-ids "$NEW_HOST_ID" \
     --document-name AWS-RunShellScript \
     --comment "tutorlink cutover: rollback, stop containers" \
     --parameters 'commands=["docker compose -f /srv/tutorlink/app/docker-compose.prod.yml --env-file /srv/tutorlink/app/.env down"]' \
     --query Command.CommandId --output text
   ```

2. Disassociate the address in tutorlink-prod:

   ```sh
   aws ec2 disassociate-address --profile tutorlink-prod \
     --association-id "$(aws ec2 describe-addresses --public-ips "$EIP_ADDRESS" --profile tutorlink-prod \
       --query 'Addresses[0].AssociationId' --output text)"
   ```

3. In TutorLink `infra/`, remove the association and the address from state, then unset `elastic_ip_allocation_id`:

   ```sh
   AWS_PROFILE=tutorlink-prod terraform state rm 'aws_eip_association.app[0]' 'aws_eip.app[0]'
   ```

   Never apply with the variable nulled while the address is still in state: its
   `prevent_destroy` blocks that, and otherwise Terraform would release the address.
4. Transfer it back. Offer from tutorlink-prod, then accept with the management profile:

   ```sh
   NEW_ALLOCATION_ID=<allocation id from step 6.4>
   aws ec2 enable-address-transfer --allocation-id "$NEW_ALLOCATION_ID" \
     --transfer-account-id 211125623243 --profile tutorlink-prod
   aws ec2 accept-address-transfer --address "$EIP_ADDRESS"
   ```

5. Associate it with the old EC2. The transfer assigned a new allocation ID in management:

   ```sh
   aws ec2 associate-address --instance-id "$OLD_HOST_ID" \
     --allocation-id "$(aws ec2 describe-addresses --public-ips "$EIP_ADDRESS" \
       --query 'Addresses[0].AllocationId' --output text)"
   ```

6. Start the old `api` with the `start api` command from the previous section.

Then go to step 9: an aborted cutover still deletes the dump.

What is lost depends on when you roll back:

- **From steps 3 to 5**: nothing beyond the downtime. The old database was not written to during the window.
- **From step 6, before step 7**: nothing beyond the downtime. The new database has no writes yet; the cost is the
  extra transfers and a longer outage.
- **From step 7**: everything written to `neves-labs-pg` since the app started there, including the smoke-check
  booking and chat messages, plus any real traffic. The old database never sees those writes.
- **After the address moved back**: the old site has the same URL again, but rolling back also forgets the new
  database's writes, as above. The old Elastic IP's allocation ID changed twice; record the current one before
  anyone updates TutorLink's variables.

## 9. After

In **work**, delete the dump and every scratch file:

```sh
rm -rf "$CUTOVER_DIR"
```

Stop both port-forwards (Ctrl-C in **forward-new** and **forward-old**) and close all three terminals.

Removing the old `tutorlink` RDS instance is #5. #5 must `terraform state rm` (not destroy) the old state's
`aws_eip.app` and its association: the address now belongs to tutorlink-prod, and destroying it there would release
the address the site URL depends on.
