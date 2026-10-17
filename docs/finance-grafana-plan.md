# Finance dashboards in Grafana (notgroschen)

Status: four dashboards ready on branch `feat/finance-grafana`, Parqet panels pending.
This repo is public. The plan and the dashboards hold SQL only, never figures, names or identifiers.

## Architecture

```text
notgroschen (Rails) ──writes──▶ psql-notgroschen (CNPG, ns default, db notgroschen)
                                        ▲
                                        │ role grafana_ro, column-level SELECT, TLS (sslmode=require)
                                        │
Grafana (kube-prometheus-stack, ns monitoring)
  ├─ datasource "notgroschen" (uid notgroschen)  ◀── Secret labelled grafana_datasource=1
  └─ folder "Finanzen", 4 dashboards              ◀── ConfigMaps labelled grafana_dashboard=1
```

Everything lives next to the app in `cluster/apps/default/notgroschen/app/`, reconciled by the per-app
Kustomization `apps-default-notgroschen`:

| File                           | What it is                                                                                      |
| ------------------------------ | ----------------------------------------------------------------------------------------------- |
| `cluster.yaml`                 | `spec.managed.roles` gains `grafana_ro` (login, connection limit 4, password from Secret)       |
| `grafana-ro-secret.sops.yaml`  | `kubernetes.io/basic-auth` Secret `notgroschen-grafana-ro` (ns default), label `cnpg.io/reload` |
| `grafana/kustomization.yaml`   | `namespace: monitoring`, dashboard ConfigMaps, folder annotation `Finanzen`                     |
| `grafana/datasource.sops.yaml` | Secret `grafana-datasource-notgroschen` with the datasource provisioning file                   |
| `grafana/dashboards/*.json`    | wealth, cashflow, consumption, depot-moneymoney                                                 |

## How Grafana is provisioned here

- Grafana is the subchart of `cluster/apps/monitoring/kube-prometheus-stack/helm-release.yaml` (Grafana 13.2), reconciled by
  the top-level `apps` Kustomization with substitution from `cluster-settings` and `cluster-secrets`.
- Auth is Authentik OAuth with auto-login. Only members of `Grafana Admins` and `Grafana Editors` may log in (policy
  bindings in `kube-prometheus-stack/authentik-blueprint.yaml`); the role falls back to Viewer.
- Dashboards come from two places. Helm values `dashboardProviders` + `dashboards` (gnetId imports) and the
  dashboard sidecar: ConfigMaps with label `grafana_dashboard: "1"` in any namespace, folder from the annotation
  `grafana_folder`. Repo convention for the sidecar: `configMapGenerator` with `disableNameSuffixHash: true`, label on
  `generatorOptions`, and `kustomize.toolkit.fluxcd.io/substitute: disabled` so Grafana's `$vars` need no escaping.
  TeslaMate keeps its dashboards next to the app (`cluster/apps/default/teslamate/app/dashboards`, `namespace: monitoring`);
  the finance dashboards follow that.
- Datasources come from Helm `additionalDataSources` (TeslaMate is a Postgres datasource there, password via
  `${SECRET_TESLAMATE_POSTGRES_PASSWORD}` from `cluster-secrets`) and from the datasource sidecar, which is enabled by
  the chart default: label `grafana_datasource: "1"`, watching only the `monitoring` namespace. No Postgres datasource
  for notgroschen existed.

The finance datasource uses the sidecar instead of `additionalDataSources`. That keeps the password out of
`cluster-secrets` (substituted into every Kustomization), needs no HelmRelease upgrade, and keeps the role and its
datasource in one directory. The cost is two encrypted copies of one password, one per namespace.

## Read-only role

CNPG 1.30 manages roles declaratively (`spec.managed.roles` or the `DatabaseRole` CRD) but has no declarative table
privileges. The `Database` CRD grants only on FDWs and foreign servers. The only declarative read path is
`inRoles: [pg_read_all_data]`, which reads every column of every table, including IBANs, booking purposes,
counterparty names and the raw import payloads. Rejected.

So the role is declarative in gitops and the grants are applied by notgroschen as table owner (role `notgroschen`). The
allowlist is column-level: the dashboards never need IBANs, account numbers, counterparty names, purposes, mandate or
creditor IDs, or the `imports`, `solid_*` and `cmp_*` tables.

```sql
-- db/grafana_grants.sql in notgroschen. Idempotent, safe without the role (dev, test).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana_ro') THEN
    REVOKE ALL ON ALL TABLES IN SCHEMA public FROM grafana_ro;
    GRANT USAGE ON SCHEMA public TO grafana_ro;
    GRANT SELECT (id, name, person, portfolio, account_type, currency, active) ON accounts TO grafana_ro;
    GRANT SELECT (account_id, balance_at, balance_cents, currency, source) ON account_balances TO grafana_ro;
    GRANT SELECT (id, account_id, booking_date, amount_cents, currency, flow_type, merchant_id, category_path, recurring)
      ON transactions TO grafana_ro;
    GRANT SELECT (id, display_name, kind) ON merchants TO grafana_ro;
    GRANT SELECT (id, account_id, taken_at) ON portfolio_snapshots TO grafana_ro;
    GRANT SELECT (portfolio_snapshot_id, name, isin, quantity, value_cents, currency) ON holdings TO grafana_ro;
  END IF;
END $$;
```

No `ALTER DEFAULT PRIVILEGES`: a default grant would hand every future table to Grafana, which defeats the allowlist.
New tables (Parqet) get their own line in the same file.

Where it should live: a notgroschen change applies `db/grafana_grants.sql` on every boot, after `db:prepare` in
`bin/docker-entrypoint` (for example `bin/rails runner 'ActiveRecord::Base.connection.execute(File.read("db/grafana_grants.sql"))'`).
A one-off migration is the alternative, but it runs once: if it lands before the role exists, the grants never
happen. Running on boot heals that and any table rebuild. This is notgroschen-side work for the agent that owns that repo.

Until then, the owner can save the block above as `grafana_grants.sql` and apply it once by hand after the role
exists. It is idempotent, so the later notgroschen change does not conflict:

```bash
kubectl --kubeconfig provision/kubeconfig -n default exec -i psql-notgroschen-1 -c postgres -- \
  psql -U postgres -d notgroschen -v ON_ERROR_STOP=1 -f - < grafana_grants.sql
```

## Datasource

Provisioning file inside the encrypted Secret (password redacted here):

```yaml
apiVersion: 1
datasources:
  - name: notgroschen
    uid: notgroschen
    type: grafana-postgresql-datasource
    access: proxy
    orgId: 1
    url: psql-notgroschen-rw.default.svc:5432
    user: grafana_ro
    editable: false
    jsonData:
      database: notgroschen
      sslmode: require
      postgresVersion: 1500
      maxOpenConns: 4
      maxIdleConns: 2
      connMaxLifetime: 14400
    secureJsonData:
      password: <same as notgroschen-grafana-ro>
```

Rotate by generating a new password and re-encrypting both `grafana-ro-secret.sops.yaml` and
`grafana/datasource.sops.yaml`. CNPG picks the new password up through the `cnpg.io/reload` label.

## Rules every query follows

- Scope variable `$scope`: Haushalt (`me+joint`, default), Ich, Gemeinschaftskonto, Mama. Single-select, no "All", so mama
  is never summed with the household. Filter: `a.person = ANY(string_to_array('${scope}', '+'))`.
- The joint ING sub-depot is already `person = joint` in `accounts` ("Direkt-Depot - Gemeinschaftskonto"), so it counts
  in the household and drops out of "Ich".
- Savings rates appear only for complete units (`'${scope}' IN ('me+joint', 'mama')`), as `AccountScope#unit?`.
- Consumption stays signed (`-SUM(amount_cents) WHERE flow_type = 'consumption'`); refunds reduce it. Reimbursements,
  internal transfers and asset flows are neither income nor consumption. No panel shows gross outflow.
- The monthly fixed-cost share to the joint account is an `internal_transfer` with a counter-leg inside the household,
  so it is neither spending nor savings in household scope.
- Category groups at depth 3 like `CategoryPath::GROUP_DEPTH`:
  `COALESCE(array_to_string((string_to_array(t.category_path, chr(92)))[1:3], chr(92)), 'none')`. `chr(92)` is the
  backslash; it avoids escaping in JSON and never uses `LIKE`, which reads the backslash as an escape.
- EUR only. Non-EUR balances appear per currency in the accounts table and are never converted.
- Balance at time t: the last `account_balances` point at or before t, rolled forward through later bookings. Derived
  points stop at the last `notgroschen:rebuild`, so a plain carry-forward shows stale balances after money moves between
  savings accounts. Depots are never derived: only `observed` points count, and the depot and net lines start when
  every depot in scope has been observed once (as `NetWorthHistoryQuery`).

## Dashboards (ready)

All four dashboards are built from existing tables and every panel query was run read-only against the live database.
The exact SQL per panel is in the appendix, generated from the same source as the JSON.

| Dashboard                     | uid                   | Panels                                                                                                                    | Variables                      |
| ----------------------------- | --------------------- | ------------------------------------------------------------------------------------------------------------------------- | ------------------------------ |
| Finanzen · Vermögen           | `finance-wealth`      | Vermögensstand, Notgroschen + Monate Deckung, Stichtage, Vermögen über Zeit, Notgroschen über Zeit, Konten                | `$scope`, `$notgroschen`       |
| Finanzen · Cashflow           | `finance-cashflow`    | Zeitraum-Kennzahlen, Einnahmen/Konsum je Monat, Sparquote rollierend 12 M., Fixkosten vs. variabel, wiederkehrende Kosten | `$scope`                       |
| Finanzen · Konsum             | `finance-consumption` | Händlerart, Konsum je Monat nach Kategorie, Kategorien im Zeitraum, Top-Händler, Händlerart je Monat                      | `$scope`, `$kategorie`, `$top` |
| Finanzen · Depot (MoneyMoney) | `finance-depot-mm`    | Depotwert gesamt, Depotwert je Depot, Positionen über Zeit, aktuelle Positionen                                           | `$scope`, `$top`               |

Units: `currencyEUR` for money, `percentunit` for rates, `none` with one decimal for months of coverage.

Definitions that need the owner's eye:

- Notgroschen is the balance of the accounts picked in `$notgroschen`. The default is the day-money and savings accounts
  between which the reserve actually moves, including the broker clearing account (ids 4, 45, 5, 40, 6, 57).
- Months of coverage = Notgroschen / average monthly consumption over the last 12 full months.
- Sparquote = (Einnahmen − Konsum) / Einnahmen. The app divides by funding instead (income plus the named external
  contribution to the joint account). That contribution is identified by counterparty name, a column Grafana does not
  get, so the Grafana rate reads lower than the app's until notgroschen exposes it (see below).
- "Nach Fixkosten": Fixkosten = consumption with `recurring = true`; "Frei nach Fixkosten" = Einnahmen − Fixkosten;
  Fixkostenquote = Fixkosten / Einnahmen.
- Depot history exists only from the first MoneyMoney portfolio push on; it grows with every sync.

## Depot from Parqet (pending)

PENDING. No Parqet tables exist yet: branch `feat/parqet-sync` in notgroschen has no migrations. The table and column
names below are a proposal, unstable until that branch lands; each query must be re-checked against the real migration.
Each table also needs its line in `db/grafana_grants.sql`.

Proposed tables:

```text
parqet_portfolios        id, parqet_id, name, person (me | joint), account_id -> accounts (nullable)
parqet_portfolio_values  parqet_portfolio_id, valued_on (date), market_value_cents, invested_cents
parqet_activities        id, parqet_portfolio_id, parqet_id, activity_type (buy | sell | dividend | interest |
                         fees_taxes | transfer_in | transfer_out | deposit | withdrawal), executed_at, isin, asset_name,
                         shares, price, amount_cents, fee_cents, tax_cents, currency, savings_plan (bool)
parqet_positions         parqet_portfolio_id, isin, name, shares, purchase_value_cents, market_value_cents, valued_at
```

`person` on `parqet_portfolios` carries the household rule: the joint ING sub-depot must be `joint`.

Marktwert vs. investiertes Kapital (timeseries, `currencyEUR`). The difference is the real gain only if
`invested_cents` is net contributed capital (buys minus sell proceeds); Parqet's purchase value of current holdings
excludes realised gains. Settle which one the sync stores.

```sql
SELECT v.valued_on::timestamp AS time,
       SUM(v.market_value_cents) / 100.0 AS "Marktwert",
       SUM(v.invested_cents) / 100.0 AS "Investiertes Kapital",
       SUM(v.market_value_cents - v.invested_cents) / 100.0 AS "Gewinn"
FROM parqet_portfolio_values v
JOIN parqet_portfolios p ON p.id = v.parqet_portfolio_id
WHERE p.person = ANY(string_to_array('${scope}', '+')) AND $__timeFilter(v.valued_on)
GROUP BY 1
ORDER BY 1
```

Dividenden je Jahr (bar chart, `currencyEUR`):

```sql
SELECT date_trunc('year', a.executed_at) AS time,
       SUM(a.amount_cents) / 100.0 AS "Dividenden brutto",
       SUM(a.amount_cents - COALESCE(a.tax_cents, 0)) / 100.0 AS "Dividenden netto"
FROM parqet_activities a
JOIN parqet_portfolios p ON p.id = a.parqet_portfolio_id
WHERE p.person = ANY(string_to_array('${scope}', '+')) AND a.activity_type = 'dividend' AND a.currency = 'EUR'
  AND $__timeFilter(a.executed_at)
GROUP BY 1
ORDER BY 1
```

Gebühren und Steuern je Jahr (stacked bars, `currencyEUR`):

```sql
SELECT date_trunc('year', a.executed_at) AS time,
       SUM(COALESCE(a.fee_cents, 0)) / 100.0 AS "Gebühren",
       SUM(COALESCE(a.tax_cents, 0)) / 100.0 AS "Steuern"
FROM parqet_activities a
JOIN parqet_portfolios p ON p.id = a.parqet_portfolio_id
WHERE p.person = ANY(string_to_array('${scope}', '+')) AND a.currency = 'EUR' AND $__timeFilter(a.executed_at)
GROUP BY 1
ORDER BY 1
```

Sparplan-Käufe je Monat (bars, `currencyEUR`). Needs `savings_plan`; if Parqet does not mark plan executions, the sync
must derive it (same ISIN, same amount, monthly rhythm, like `RecurrenceDeriver`).

```sql
SELECT date_trunc('month', a.executed_at) AS time, COALESCE(a.asset_name, a.isin) AS metric,
       SUM(a.amount_cents) / 100.0 AS value
FROM parqet_activities a
JOIN parqet_portfolios p ON p.id = a.parqet_portfolio_id
WHERE p.person = ANY(string_to_array('${scope}', '+')) AND a.activity_type = 'buy' AND a.savings_plan
  AND a.currency = 'EUR' AND $__timeFilter(a.executed_at)
GROUP BY 1, 2
ORDER BY 1
```

Unrealisierter Gewinn je Position (table, `currencyEUR` and `percentunit`):

```sql
WITH latest AS (
  SELECT DISTINCT ON (parqet_portfolio_id, isin) *
  FROM parqet_positions
  ORDER BY parqet_portfolio_id, isin, valued_at DESC
)
SELECT COALESCE(l.name, l.isin) AS "Position", l.isin AS "ISIN",
       SUM(l.market_value_cents) / 100.0 AS "Marktwert",
       SUM(l.purchase_value_cents) / 100.0 AS "Kaufwert",
       SUM(l.market_value_cents - l.purchase_value_cents) / 100.0 AS "Unrealisiert",
       SUM(l.market_value_cents - l.purchase_value_cents)::float / NULLIF(SUM(l.purchase_value_cents), 0) AS "Rendite"
FROM latest l
JOIN parqet_portfolios p ON p.id = l.parqet_portfolio_id
WHERE p.person = ANY(string_to_array('${scope}', '+'))
GROUP BY 1, 2
ORDER BY 5 DESC
```

## Needs a notgroschen-side change

1. Apply `db/grafana_grants.sql` on every boot (above). Without it the datasource connects but every query fails with
   `permission denied`.
2. Expose the external contribution without names, for example a derived flag `transactions.external_contribution`
   written next to `flow_type`, and grant it. Then the Grafana savings rate can divide by funding like the app.
3. Optional: run `BalanceDeriver` after each import. The dashboards roll forward from the last point, so this is
   cosmetic for Grafana, but the app's own chart shows the stale carry-forward.
4. Parqet tables: add grants, settle the `invested` definition and the savings-plan flag.

## Rollout

1. Review and merge `feat/finance-grafana`, push `main`, then `task flux:sync`.
2. Check that the per-app Kustomization went Ready, not only `apps`:
   `flux get ks apps-default-notgroschen`.
3. Check the role:
   `kubectl -n default get cluster psql-notgroschen -o jsonpath='{.status.managedRolesStatus}'` lists `grafana_ro` as reconciled.
4. Apply the grants: the notgroschen change from above, or once by hand with the `psql` command in "Read-only role".
5. Check least privilege, expecting the first query to succeed and the second to fail with `permission denied`:

   ```bash
   PW=$(kubectl -n default get secret notgroschen-grafana-ro -o jsonpath='{.data.password}' | base64 -d)
   kubectl -n default exec -i psql-notgroschen-1 -c postgres -- env PGPASSWORD="$PW" \
     psql "host=localhost user=grafana_ro dbname=notgroschen" -c 'SELECT count(*) FROM transactions' -c 'SELECT iban FROM accounts'
   ```

6. Check the Grafana objects:
   `kubectl -n monitoring get secret grafana-datasource-notgroschen` and
   `kubectl -n monitoring get cm -l grafana_dashboard=1 | grep finance` (four ConfigMaps).
7. In Grafana: Connections → Data sources → notgroschen → Test, then folder "Finanzen". Compare Vermögen → Vermögensstand
   with the app's Übersicht and Cashflow → Zeitraum (range = one calendar year) with the app's Jahresbilanz for that year.

## Open questions

- Is the default Notgroschen set right, especially the broker clearing account?
- Who is in `Grafana Editors`? Editors can run any query in Explore against the granted columns.
- Should "Ich" and "Gemeinschaftskonto" stay selectable at all, given they are half-views?
- Parqet: which `invested` figure, and does Parqet mark savings-plan executions?

## Appendix: panel SQL

Generated from the dashboard source. Grafana macros (`$__timeFilter`, `$__timeFrom()`) and variables are left in place.

### Finanzen · Vermögen (`wealth.json`, uid `finance-wealth`)

Variables: `$scope`, `$notgroschen`. Default range: `now-15y`.

#### Variable `$notgroschen`

```sql
SELECT a.name || ' (' || a.person || ')' AS __text, a.id AS __value
FROM accounts a
WHERE a.person = ANY(string_to_array('${scope}', '+')) AND NOT a.portfolio AND a.active AND a.currency = 'EUR'
  AND a.account_type IS DISTINCT FROM 'Loan account' AND a.account_type IS DISTINCT FROM 'Credit card'
ORDER BY a.name
```

#### Vermögensstand (EUR, letzter Abruf)

Panel `stat`, unit `currencyEUR`, format `table`.

```sql
WITH latest AS (
  SELECT DISTINCT ON (ab.account_id) ab.account_id, ab.balance_at
  FROM account_balances ab
  WHERE ab.source = 'observed'
  ORDER BY ab.account_id, ab.balance_at DESC
)
SELECT
  SUM(ab.balance_cents) FILTER (WHERE NOT a.portfolio AND a.account_type IS DISTINCT FROM 'Loan account') / 100.0 AS "Cash",
  SUM(ab.balance_cents) FILTER (WHERE a.portfolio) / 100.0 AS "Depot",
  SUM(ab.balance_cents) FILTER (WHERE a.account_type = 'Loan account') / 100.0 AS "Schulden",
  SUM(ab.balance_cents) / 100.0 AS "Netto"
FROM latest l
JOIN account_balances ab ON ab.account_id = l.account_id AND ab.balance_at = l.balance_at AND ab.source = 'observed'
JOIN accounts a ON a.id = ab.account_id
WHERE a.person = ANY(string_to_array('${scope}', '+')) AND ab.currency = 'EUR'
```

#### Notgroschen

Panel `stat`, unit `currencyEUR` (overrides: Monate Deckung: none), format `table`.

```sql
WITH latest AS (
  SELECT DISTINCT ON (ab.account_id) ab.account_id, ab.balance_at
  FROM account_balances ab
  WHERE ab.source = 'observed'
  ORDER BY ab.account_id, ab.balance_at DESC
),
ng AS (
  SELECT COALESCE(SUM(ab.balance_cents), 0) AS c
  FROM latest l
JOIN account_balances ab ON ab.account_id = l.account_id AND ab.balance_at = l.balance_at AND ab.source = 'observed'
JOIN accounts a ON a.id = ab.account_id
  WHERE a.id IN (${notgroschen:csv}) AND ab.currency = 'EUR'
),
kon AS (
  SELECT -SUM(t.amount_cents) / 12.0 AS c
  FROM transactions t
JOIN accounts a ON a.id = t.account_id
  WHERE a.person = ANY(string_to_array('${scope}', '+')) AND t.flow_type = 'consumption' AND t.currency = 'EUR'
    AND t.booking_date >= date_trunc('month', now()) - interval '12 months'
    AND t.booking_date < date_trunc('month', now())
)
SELECT ng.c / 100.0 AS "Notgroschen",
       kon.c / 100.0 AS "Konsum Ø Monat (12 M.)",
       ng.c / NULLIF(kon.c, 0) AS "Monate Deckung"
FROM ng, kon
```

#### Stichtage

Panel `stat`, unit `none` (overrides: Stand Konten: dateTimeAsLocalNoDateIfToday, Stand Depots: dateTimeAsLocalNoDateIfToday), format `table`.

```sql
WITH latest AS (
  SELECT DISTINCT ON (ab.account_id) ab.account_id, ab.balance_at
  FROM account_balances ab
  WHERE ab.source = 'observed'
  ORDER BY ab.account_id, ab.balance_at DESC
)
SELECT MAX(l.balance_at) FILTER (WHERE NOT a.portfolio) AS "Stand Konten",
       MAX(l.balance_at) FILTER (WHERE a.portfolio) AS "Stand Depots",
       (SELECT COUNT(DISTINCT ps.taken_at::date) FROM portfolio_snapshots ps JOIN accounts a ON a.id = ps.account_id WHERE a.person = ANY(string_to_array('${scope}', '+'))) AS "Depot-Stichtage"
FROM latest l JOIN accounts a ON a.id = l.account_id
WHERE a.person = ANY(string_to_array('${scope}', '+'))
```

#### Vermögen über Zeit (Monatsanfang)

Panel `timeseries`, unit `currencyEUR`, format `time_series`.

```sql
WITH pts AS (
  SELECT generate_series(date_trunc('month', $__timeFrom()::timestamp), now()::timestamp, interval '1 month') AS t
  UNION
  SELECT now()::timestamp
),
acc AS (
  SELECT a.id,
         CASE WHEN a.portfolio THEN 'Depot' WHEN a.account_type = 'Loan account' THEN 'Schulden' ELSE 'Cash' END AS cls
  FROM accounts a
  WHERE a.person = ANY(string_to_array('${scope}', '+'))
),
-- Depots are never derived; the depot line starts once every depot in scope was observed once.
known AS (
  SELECT MAX(first_obs) AS since
  FROM (
    SELECT MIN(ab.balance_at) AS first_obs
    FROM account_balances ab JOIN acc ON acc.id = ab.account_id
    WHERE acc.cls = 'Depot' AND ab.source = 'observed' AND ab.currency = 'EUR'
    GROUP BY ab.account_id
  ) f
),
v AS (
  SELECT pts.t, acc.cls, b.balance_cents + COALESCE(d.c, 0) AS balance_cents
  FROM pts CROSS JOIN acc
  LEFT JOIN LATERAL (
    SELECT ab.balance_cents, ab.balance_at, ab.source FROM account_balances ab
    WHERE ab.account_id = acc.id AND ab.currency = 'EUR' AND ab.balance_at <= pts.t
      AND (acc.cls <> 'Depot' OR ab.source = 'observed')
    ORDER BY ab.balance_at DESC LIMIT 1
  ) b ON TRUE
  LEFT JOIN LATERAL (
    -- Roll the last point forward through later bookings: derived points stop at the last rebuild.
    SELECT COALESCE(SUM(tx.amount_cents), 0) AS c FROM transactions tx
    WHERE tx.account_id = acc.id AND tx.currency = 'EUR' AND tx.booking_date < pts.t::date
      AND (tx.booking_date > b.balance_at::date OR (b.source <> 'observed' AND tx.booking_date = b.balance_at::date))
  ) d ON acc.cls <> 'Depot' AND b.balance_at IS NOT NULL
)
SELECT t AS time, cls AS metric, SUM(COALESCE(balance_cents, 0)) / 100.0 AS value
FROM v, known
WHERE cls <> 'Depot' OR t >= known.since
GROUP BY 1, 2
UNION ALL
SELECT t, 'Netto', SUM(COALESCE(balance_cents, 0)) / 100.0
FROM v, known
WHERE t >= known.since
GROUP BY 1
ORDER BY 1
```

#### Notgroschen und Monate Deckung

Panel `timeseries`, unit `currencyEUR` (overrides: Monate Deckung: none), format `time_series`.

```sql
WITH pts AS (
  SELECT generate_series(date_trunc('month', $__timeFrom()::timestamp), now()::timestamp, interval '1 month') AS t
  UNION
  SELECT now()::timestamp
),
ng AS (
  SELECT pts.t, SUM(COALESCE(b.balance_cents, 0) + COALESCE(d.c, 0)) AS c
  FROM pts CROSS JOIN accounts a
  LEFT JOIN LATERAL (
    SELECT ab.balance_cents, ab.balance_at, ab.source FROM account_balances ab
    WHERE ab.account_id = a.id AND ab.currency = 'EUR' AND ab.balance_at <= pts.t
    ORDER BY ab.balance_at DESC LIMIT 1
  ) b ON TRUE
  LEFT JOIN LATERAL (
    -- Roll the last point forward through later bookings: derived points stop at the last rebuild.
    SELECT COALESCE(SUM(tx.amount_cents), 0) AS c FROM transactions tx
    WHERE tx.account_id = a.id AND tx.currency = 'EUR' AND tx.booking_date < pts.t::date
      AND (tx.booking_date > b.balance_at::date OR (b.source <> 'observed' AND tx.booking_date = b.balance_at::date))
  ) d ON b.balance_at IS NOT NULL
  WHERE a.id IN (${notgroschen:csv})
  GROUP BY 1
),
kon AS (
  SELECT pts.t,
         (SELECT -SUM(t.amount_cents) / 12.0
          FROM transactions t
JOIN accounts a ON a.id = t.account_id
          WHERE a.person = ANY(string_to_array('${scope}', '+')) AND t.flow_type = 'consumption' AND t.currency = 'EUR'
            AND t.booking_date >= pts.t - interval '12 months' AND t.booking_date < pts.t) AS c
  FROM pts
)
SELECT ng.t AS time, ng.c / 100.0 AS "Notgroschen", ng.c / NULLIF(kon.c, 0) AS "Monate Deckung"
FROM ng JOIN kon USING (t)
ORDER BY 1
```

#### Konten (letzter Stand)

Panel `table`, unit `` (overrides: Saldo: none, Stand: dateTimeAsLocal), format `table`.

```sql
WITH latest AS (
  SELECT DISTINCT ON (ab.account_id) ab.account_id, ab.balance_at
  FROM account_balances ab
  WHERE ab.source = 'observed'
  ORDER BY ab.account_id, ab.balance_at DESC
)
SELECT a.name AS "Konto", a.person AS "Person", a.account_type AS "Art",
       CASE WHEN a.account_type = 'Loan account' THEN 'Schulden' WHEN a.portfolio THEN 'Depot' ELSE 'Cash' END AS "Klasse",
       ab.currency AS "Währung", ab.balance_cents / 100.0 AS "Saldo", l.balance_at AS "Stand"
FROM latest l
JOIN account_balances ab ON ab.account_id = l.account_id AND ab.balance_at = l.balance_at AND ab.source = 'observed'
JOIN accounts a ON a.id = ab.account_id
WHERE a.person = ANY(string_to_array('${scope}', '+')) AND ab.balance_cents <> 0
ORDER BY ab.currency <> 'EUR', ab.balance_cents DESC
```

### Finanzen · Cashflow (`cashflow.json`, uid `finance-cashflow`)

Variables: `$scope`. Default range: `now-5y`.

#### Zeitraum

Panel `stat`, unit `currencyEUR` (overrides: Sparquote: percentunit, Fixkostenquote: percentunit), format `table`.

```sql
WITH s AS (
  SELECT COALESCE(SUM(t.amount_cents) FILTER (WHERE t.flow_type = 'income'), 0) AS inc,
         COALESCE(SUM(t.amount_cents) FILTER (WHERE t.flow_type = 'consumption'), 0) AS con,
         COALESCE(SUM(t.amount_cents) FILTER (WHERE t.flow_type = 'consumption' AND t.recurring), 0) AS fix
  FROM transactions t
JOIN accounts a ON a.id = t.account_id
  WHERE a.person = ANY(string_to_array('${scope}', '+')) AND t.currency = 'EUR' AND $__timeFilter(t.booking_date)
)
SELECT inc / 100.0 AS "Einnahmen",
       -con / 100.0 AS "Konsum",
       (inc + con) / 100.0 AS "Saldo",
       CASE WHEN '${scope}' IN ('me+joint', 'mama') AND inc > 0 THEN (inc + con)::float / inc END AS "Sparquote",
       -fix / 100.0 AS "Fixkosten",
       (inc + fix) / 100.0 AS "Frei nach Fixkosten",
       CASE WHEN inc > 0 THEN -fix::float / inc END AS "Fixkostenquote"
FROM s
```

#### Einnahmen und Konsum je Monat

Panel `timeseries`, unit `currencyEUR`, format `time_series`.

```sql
SELECT date_trunc('month', t.booking_date)::timestamp AS time,
       COALESCE(SUM(t.amount_cents) FILTER (WHERE t.flow_type = 'income'), 0) / 100.0 AS "Einnahmen",
       COALESCE(-SUM(t.amount_cents) FILTER (WHERE t.flow_type = 'consumption'), 0) / 100.0 AS "Konsum",
       COALESCE(SUM(t.amount_cents) FILTER (WHERE t.flow_type IN ('income', 'consumption')), 0) / 100.0 AS "Saldo"
FROM transactions t
JOIN accounts a ON a.id = t.account_id
WHERE a.person = ANY(string_to_array('${scope}', '+')) AND t.currency = 'EUR' AND $__timeFilter(t.booking_date)
GROUP BY 1
ORDER BY 1
```

#### Sparquote und Fixkostenquote, rollierend 12 Monate

Panel `timeseries`, unit `percentunit`, format `time_series`.

```sql
WITH m AS (
  SELECT date_trunc('month', t.booking_date)::timestamp AS mon,
         COALESCE(SUM(t.amount_cents) FILTER (WHERE t.flow_type = 'income'), 0) AS inc,
         COALESCE(SUM(t.amount_cents) FILTER (WHERE t.flow_type = 'consumption'), 0) AS con,
         COALESCE(SUM(t.amount_cents) FILTER (WHERE t.flow_type = 'consumption' AND t.recurring), 0) AS fix
  FROM transactions t
JOIN accounts a ON a.id = t.account_id
  WHERE a.person = ANY(string_to_array('${scope}', '+')) AND t.currency = 'EUR'
  GROUP BY 1
),
r AS (
  SELECT mon,
         SUM(inc) OVER w AS inc12, SUM(con) OVER w AS con12, SUM(fix) OVER w AS fix12,
         MIN(mon) OVER () AS first_mon
  FROM m
  WINDOW w AS (ORDER BY mon RANGE BETWEEN interval '11 months' PRECEDING AND CURRENT ROW)
)
SELECT mon AS time,
       CASE WHEN '${scope}' IN ('me+joint', 'mama') AND inc12 > 0 THEN (inc12 + con12)::float / inc12 END AS "Sparquote (12 M.)",
       CASE WHEN inc12 > 0 THEN -fix12::float / inc12 END AS "Fixkostenquote (12 M.)"
FROM r
WHERE mon >= first_mon + interval '11 months' AND mon < date_trunc('month', now())
  AND $__timeFilter(mon)
ORDER BY 1
```

#### Fixkosten vs. variabler Konsum je Monat

Panel `timeseries`, unit `currencyEUR`, format `time_series`.

```sql
SELECT date_trunc('month', t.booking_date)::timestamp AS time,
       COALESCE(-SUM(t.amount_cents) FILTER (WHERE t.recurring), 0) / 100.0 AS "Fixkosten (wiederkehrend)",
       COALESCE(-SUM(t.amount_cents) FILTER (WHERE NOT t.recurring), 0) / 100.0 AS "Variabler Konsum"
FROM transactions t
JOIN accounts a ON a.id = t.account_id
WHERE a.person = ANY(string_to_array('${scope}', '+')) AND t.flow_type = 'consumption' AND t.currency = 'EUR' AND $__timeFilter(t.booking_date)
GROUP BY 1
ORDER BY 1
```

#### Wiederkehrende Kosten (letzte 12 Monate)

Panel `table`, unit `` (overrides: Betrag: currencyEUR, Summe 12 M.: currencyEUR), format `table`.

```sql
SELECT COALESCE(m.display_name, '(ohne Händler)') AS "Händler",
       -r.amount_cents / 100.0 AS "Betrag",
       COUNT(*) AS "Buchungen 12 M.",
       -SUM(r.amount_cents) / 100.0 AS "Summe 12 M.",
       MAX(r.booking_date) AS "Zuletzt",
       MAX(CASE WHEN r.grp = 'none' THEN '(ohne Kategorie)'
         WHEN starts_with(r.grp, 'Ein-/Ausgaben' || chr(92) || 'Ausgaben' || chr(92)) THEN substr(r.grp, 24)
         ELSE replace(r.grp, chr(92), ' › ') END) AS "Kategorie"
FROM (
  SELECT t.merchant_id, t.amount_cents, t.booking_date,
         COALESCE(array_to_string((string_to_array(t.category_path, chr(92)))[1:3], chr(92)), 'none') AS grp
  FROM transactions t
JOIN accounts a ON a.id = t.account_id
  WHERE a.person = ANY(string_to_array('${scope}', '+')) AND t.recurring AND t.flow_type = 'consumption' AND t.currency = 'EUR'
    AND t.booking_date >= now() - interval '12 months'
) r
LEFT JOIN merchants m ON m.id = r.merchant_id
GROUP BY m.id, m.display_name, r.amount_cents
ORDER BY 4 DESC
```

### Finanzen · Konsum (`consumption.json`, uid `finance-consumption`)

Variables: `$scope`, `$kategorie`, `$top`. Default range: `now-1y`.

#### Variable `$kategorie`

```sql
SELECT DISTINCT grp AS __value,
       CASE WHEN grp = 'none' THEN '(ohne Kategorie)'
         WHEN starts_with(grp, 'Ein-/Ausgaben' || chr(92) || 'Ausgaben' || chr(92)) THEN substr(grp, 24)
         ELSE replace(grp, chr(92), ' › ') END AS __text
FROM (
  SELECT COALESCE(array_to_string((string_to_array(t.category_path, chr(92)))[1:3], chr(92)), 'none') AS grp
  FROM transactions t
JOIN accounts a ON a.id = t.account_id
  WHERE a.person = ANY(string_to_array('${scope}', '+')) AND t.flow_type = 'consumption'
) g
ORDER BY 2
```

#### Konsum nach Händlerart

Panel `stat`, unit `currencyEUR` (overrides: Anteil Privatpersonen: percentunit), format `table`.

```sql
WITH tx AS (
  SELECT t.booking_date, t.amount_cents, t.merchant_id,
         COALESCE(array_to_string((string_to_array(t.category_path, chr(92)))[1:3], chr(92)), 'none') AS grp
  FROM transactions t
JOIN accounts a ON a.id = t.account_id
  WHERE a.person = ANY(string_to_array('${scope}', '+'))
    AND t.flow_type = 'consumption' AND t.currency = 'EUR'
    AND $__timeFilter(t.booking_date)
),
ktx AS (SELECT * FROM tx WHERE grp IN (${kategorie:sqlstring}))
SELECT -SUM(ktx.amount_cents) FILTER (WHERE m.kind = 'business') / 100.0 AS "Unternehmen",
       -SUM(ktx.amount_cents) FILTER (WHERE m.kind = 'person') / 100.0 AS "Privatpersonen",
       -SUM(ktx.amount_cents) FILTER (WHERE m.kind IS NULL) / 100.0 AS "ohne Händler",
       (SUM(ktx.amount_cents) FILTER (WHERE m.kind = 'person'))::float
         / NULLIF(SUM(ktx.amount_cents), 0) AS "Anteil Privatpersonen"
FROM ktx
LEFT JOIN merchants m ON m.id = ktx.merchant_id
```

#### Konsum je Monat nach Kategorie (Ebene 3)

Panel `timeseries`, unit `currencyEUR`, format `time_series`.

```sql
WITH tx AS (
  SELECT t.booking_date, t.amount_cents, t.merchant_id,
         COALESCE(array_to_string((string_to_array(t.category_path, chr(92)))[1:3], chr(92)), 'none') AS grp
  FROM transactions t
JOIN accounts a ON a.id = t.account_id
  WHERE a.person = ANY(string_to_array('${scope}', '+'))
    AND t.flow_type = 'consumption' AND t.currency = 'EUR'
    AND $__timeFilter(t.booking_date)
),
ktx AS (SELECT * FROM tx WHERE grp IN (${kategorie:sqlstring})),
top AS (SELECT grp FROM ktx GROUP BY grp ORDER BY SUM(amount_cents) ASC LIMIT $top)
SELECT date_trunc('month', booking_date)::timestamp AS time,
       CASE WHEN grp IN (SELECT grp FROM top) THEN CASE WHEN grp = 'none' THEN '(ohne Kategorie)'
         WHEN starts_with(grp, 'Ein-/Ausgaben' || chr(92) || 'Ausgaben' || chr(92)) THEN substr(grp, 24)
         ELSE replace(grp, chr(92), ' › ') END ELSE 'Übrige' END AS metric,
       -SUM(amount_cents) / 100.0 AS value
FROM ktx
GROUP BY 1, 2
ORDER BY 1
```

#### Konsum im Zeitraum nach Kategorie

Panel `bargauge`, unit `currencyEUR`, format `table`.

```sql
WITH tx AS (
  SELECT t.booking_date, t.amount_cents, t.merchant_id,
         COALESCE(array_to_string((string_to_array(t.category_path, chr(92)))[1:3], chr(92)), 'none') AS grp
  FROM transactions t
JOIN accounts a ON a.id = t.account_id
  WHERE a.person = ANY(string_to_array('${scope}', '+'))
    AND t.flow_type = 'consumption' AND t.currency = 'EUR'
    AND $__timeFilter(t.booking_date)
),
ktx AS (SELECT * FROM tx WHERE grp IN (${kategorie:sqlstring}))
SELECT CASE WHEN grp = 'none' THEN '(ohne Kategorie)'
         WHEN starts_with(grp, 'Ein-/Ausgaben' || chr(92) || 'Ausgaben' || chr(92)) THEN substr(grp, 24)
         ELSE replace(grp, chr(92), ' › ') END AS "Kategorie",
       -SUM(amount_cents) / 100.0 AS "Konsum"
FROM ktx
GROUP BY grp
ORDER BY 2 DESC
```

#### Top-Händler im Zeitraum

Panel `table`, unit `` (overrides: Konsum: currencyEUR, Ø Betrag: currencyEUR), format `table`.

```sql
WITH tx AS (
  SELECT t.booking_date, t.amount_cents, t.merchant_id,
         COALESCE(array_to_string((string_to_array(t.category_path, chr(92)))[1:3], chr(92)), 'none') AS grp
  FROM transactions t
JOIN accounts a ON a.id = t.account_id
  WHERE a.person = ANY(string_to_array('${scope}', '+'))
    AND t.flow_type = 'consumption' AND t.currency = 'EUR'
    AND $__timeFilter(t.booking_date)
),
ktx AS (SELECT * FROM tx WHERE grp IN (${kategorie:sqlstring})),
per AS (
  SELECT merchant_id, -SUM(amount_cents) AS c, COUNT(*) AS n,
         mode() WITHIN GROUP (ORDER BY grp) AS grp
  FROM ktx
  GROUP BY merchant_id
)
SELECT COALESCE(m.display_name, '(ohne Händler)') AS "Händler",
       COALESCE(m.kind, '–') AS "Art",
       per.c / 100.0 AS "Konsum",
       per.n AS "Buchungen",
       per.c / 100.0 / per.n AS "Ø Betrag",
       CASE WHEN per.grp = 'none' THEN '(ohne Kategorie)'
         WHEN starts_with(per.grp, 'Ein-/Ausgaben' || chr(92) || 'Ausgaben' || chr(92)) THEN substr(per.grp, 24)
         ELSE replace(per.grp, chr(92), ' › ') END AS "Kategorie"
FROM per
LEFT JOIN merchants m ON m.id = per.merchant_id
ORDER BY per.c DESC
LIMIT $top
```

#### Konsum je Monat: Privatpersonen vs. Unternehmen

Panel `timeseries`, unit `currencyEUR`, format `time_series`.

```sql
WITH tx AS (
  SELECT t.booking_date, t.amount_cents, t.merchant_id,
         COALESCE(array_to_string((string_to_array(t.category_path, chr(92)))[1:3], chr(92)), 'none') AS grp
  FROM transactions t
JOIN accounts a ON a.id = t.account_id
  WHERE a.person = ANY(string_to_array('${scope}', '+'))
    AND t.flow_type = 'consumption' AND t.currency = 'EUR'
    AND $__timeFilter(t.booking_date)
),
ktx AS (SELECT * FROM tx WHERE grp IN (${kategorie:sqlstring}))
SELECT date_trunc('month', ktx.booking_date)::timestamp AS time,
       CASE m.kind WHEN 'person' THEN 'Privatpersonen' WHEN 'business' THEN 'Unternehmen' ELSE 'ohne Händler' END AS metric,
       -SUM(ktx.amount_cents) / 100.0 AS value
FROM ktx
LEFT JOIN merchants m ON m.id = ktx.merchant_id
GROUP BY 1, 2
ORDER BY 1
```

### Finanzen · Depot (MoneyMoney) (`depot-moneymoney.json`, uid `finance-depot-mm`)

Variables: `$scope`, `$top`. Default range: `now-90d`.

#### Depots (letzter Abruf)

Panel `stat`, unit `currencyEUR` (overrides: Depots mit Bestand: none, Stand: dateTimeAsLocal), format `table`.

```sql
WITH latest AS (
  SELECT DISTINCT ON (ab.account_id) ab.account_id, ab.balance_at
  FROM account_balances ab
  WHERE ab.source = 'observed'
  ORDER BY ab.account_id, ab.balance_at DESC
)
SELECT SUM(ab.balance_cents) / 100.0 AS "Depotwert",
       COUNT(*) FILTER (WHERE ab.balance_cents <> 0) AS "Depots mit Bestand",
       MAX(l.balance_at) AS "Stand"
FROM latest l
JOIN account_balances ab ON ab.account_id = l.account_id AND ab.balance_at = l.balance_at AND ab.source = 'observed'
JOIN accounts a ON a.id = ab.account_id
WHERE a.person = ANY(string_to_array('${scope}', '+')) AND a.portfolio AND ab.currency = 'EUR'
```

#### Depotwert je Depot

Panel `timeseries`, unit `currencyEUR`, format `time_series`.

```sql
SELECT ab.balance_at AS time, a.name || ' (' || a.person || ')' AS metric, ab.balance_cents / 100.0 AS value
FROM account_balances ab
JOIN accounts a ON a.id = ab.account_id
WHERE a.person = ANY(string_to_array('${scope}', '+')) AND a.portfolio AND a.active AND ab.source = 'observed' AND ab.currency = 'EUR'
  AND ab.balance_at > '2000-01-01' AND $__timeFilter(ab.balance_at)
ORDER BY 1
```

#### Positionen über Zeit

Panel `timeseries`, unit `currencyEUR`, format `time_series`.

```sql
WITH snap AS (
  SELECT ps.id, ps.taken_at::date AS d
  FROM portfolio_snapshots ps JOIN accounts a ON a.id = ps.account_id
  WHERE a.person = ANY(string_to_array('${scope}', '+')) AND $__timeFilter(ps.taken_at)
),
pos AS (
  SELECT snap.d, COALESCE(h.name, h.isin) AS pos, SUM(h.value_cents) AS c
  FROM holdings h JOIN snap ON snap.id = h.portfolio_snapshot_id
  WHERE h.currency = 'EUR' AND h.value_cents IS NOT NULL
  GROUP BY 1, 2
),
top AS (
  SELECT pos FROM pos WHERE d = (SELECT MAX(d) FROM pos) ORDER BY c DESC LIMIT $top
)
SELECT d::timestamp AS time, CASE WHEN pos IN (SELECT pos FROM top) THEN pos ELSE 'Übrige' END AS metric,
       SUM(c) / 100.0 AS value
FROM pos
GROUP BY 1, 2
ORDER BY 1
```

#### Aktuelle Positionen

Panel `table`, unit `` (overrides: Wert: currencyEUR, Anteil: percentunit, Stand: dateTimeAsLocal), format `table`.

```sql
WITH latest_snap AS (
  SELECT DISTINCT ON (ps.account_id) ps.id, ps.account_id, ps.taken_at
  FROM portfolio_snapshots ps
  ORDER BY ps.account_id, ps.taken_at DESC
),
pos AS (
  SELECT COALESCE(h.name, h.isin) AS "Position", h.isin AS "ISIN",
         string_agg(DISTINCT a.name || ' (' || a.person || ')', ', ') AS "Depot",
         SUM(h.quantity) AS "Stück", SUM(h.value_cents) / 100.0 AS "Wert",
         MAX(ls.taken_at) AS "Stand"
  FROM holdings h
  JOIN latest_snap ls ON ls.id = h.portfolio_snapshot_id
  JOIN accounts a ON a.id = ls.account_id
  WHERE a.person = ANY(string_to_array('${scope}', '+')) AND h.currency = 'EUR' AND h.value_cents IS NOT NULL
  GROUP BY COALESCE(h.name, h.isin), h.isin
)
SELECT *, "Wert" / NULLIF(SUM("Wert") OVER (), 0) AS "Anteil" FROM pos ORDER BY "Wert" DESC
```
