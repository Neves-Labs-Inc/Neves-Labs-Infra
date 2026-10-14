# TutorLink cutover to `neves-labs-pg`

Moves TutorLink's data from the old `tutorlink` RDS instance in the management account to its own database on the
shared `neves-labs-pg` instance in Neves-Labs. Part of #4. Nothing can reach `neves-labs-pg` until the tutorlink-prod
peering from #4 is active.

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

- `database/` applied (`terraform -chdir=database output` shows `address`).
- The #4 peering is active, and a tutorlink-prod host is reachable by SSM.
- TutorLink's GitHub repo variables (`AWS_DEPLOY_ROLE_ARN`, `AWS_REGION`, `ECR_API_REPO`, `ECR_WEB_REPO`,
  `SITE_URL`) already point at tutorlink-prod (TutorLink#179). Otherwise the Deploy run in step 6 targets the old
  EC2 and restarts the old `api` against the old database, after the dump.
- The laptop has:
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
this into **work** first:

```sh
umask 077
CUTOVER_DIR="$HOME/tutorlink-cutover"
mkdir -p "$CUTOVER_DIR" && chmod 700 "$CUTOVER_DIR"

NEW_HOST_ID=<tutorlink-prod instance id>
OLD_HOST_ID=<old EC2 instance id>

NEW_DB="host=localhost port=15432 dbname=tutorlink user=tutorlink sslmode=require"
OLD_DB="host=localhost port=15433 dbname=tutorlink user=tutorlink sslmode=require"

# The old password is inside the management account's DATABASE_URL: postgresql+psycopg://tutorlink:<password>@...
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

In **forward-new**, open the port-forward to `neves-labs-pg` and leave it running until step 8:

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

In **forward-old**, open the port-forward to the old RDS instance and leave it running until step 8:

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
- Anything else is a failure: go to step 7.

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

Then check the extensions and the table owners on new:

```sh
# Lists pgcrypto and btree_gist
PGPASSWORD="$(tutorlink_password)" psql -X "$NEW_DB" -c '\dx'

# Must return no rows: every table in public is owned by tutorlink
PGPASSWORD="$(tutorlink_password)" psql -X "$NEW_DB" \
  -c "SELECT tablename, tableowner FROM pg_tables WHERE schemaname = 'public' AND tableowner <> 'tutorlink';"
```

Any difference, a missing extension, or a returned row is a failure: go to step 7.

## 6. Switch

In **work**, confirm the deploy role lives in tutorlink-prod. The account ID inside the ARN must be tutorlink-prod's
(`terraform -chdir=organization output account_ids`); if it isn't, stop and go to step 7:

```sh
gh variable get AWS_DEPLOY_ROLE_ARN -R Neves-Labs-Inc/TutorLink
```

Set `DATABASE_URL` in tutorlink-prod. The value goes through a private file rather than the command line, so the
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

Start the app there: run TutorLink's **Deploy** workflow from `main`. It writes `.env` from SSM, runs the
migrations (a no-op on the restored schema) and starts the containers.

```sh
gh workflow run deploy.yml -R Neves-Labs-Inc/TutorLink --ref main
```

Then run the smoke checks from TutorLink#179:

- [ ] `<site url>/health/ready` answers ready.
- [ ] Log in.
- [ ] Send a WhatsApp booking and see it land.
- [ ] Open a chat and check that messages arrive live, which proves the LISTEN connection works over the peering.

## 7. Rollback

If verify or the smoke checks fail, start the old `api` container again:

```sh
aws ssm send-command \
  --instance-ids "$OLD_HOST_ID" \
  --document-name AWS-RunShellScript \
  --comment "tutorlink cutover: rollback, start api" \
  --parameters 'commands=["docker compose -f /srv/tutorlink/app/docker-compose.prod.yml --env-file /srv/tutorlink/app/.env start api"]' \
  --query Command.CommandId --output text
```

If the tutorlink-prod app was started in step 6, stop its containers too, so only one copy of TutorLink is live.

Then go to step 8: an aborted cutover still deletes the dump.

What is lost depends on when you roll back:

- **From steps 3 to 5**: nothing beyond the downtime. The old database was not written to during the window.
- **From step 6**: everything written to `neves-labs-pg` since the app started there, including the smoke-check
  booking and chat messages, plus any real traffic. The old database never sees those writes.

## 8. After

In **work**, delete the dump and every scratch file:

```sh
rm -rf "$CUTOVER_DIR"
```

Stop both port-forwards (Ctrl-C in **forward-new** and **forward-old**) and close all three terminals.

Removing the old `tutorlink` RDS instance is #5.
