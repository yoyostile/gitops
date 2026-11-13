-- Prices TeslaMate home charges from evcc sessions.
-- psql variables: sessions_file (evcc /api/sessions JSON), net_price, dry_run.
\set ON_ERROR_STOP 1
\set sessions `cat :'sessions_file'`
SET client_min_messages = warning;

BEGIN;

CREATE SCHEMA IF NOT EXISTS evcc_sync;
CREATE TABLE IF NOT EXISTS evcc_sync.cost_log (
  charging_process_id int PRIMARY KEY,
  cost numeric(14, 2) NOT NULL,
  source text NOT NULL,
  evcc_session_ids int[],
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- TeslaMate stores naive UTC timestamps.
CREATE TEMP TABLE evcc_session ON COMMIT DROP AS
SELECT
  *,
  -- An open session that has a newer one on the same loadpoint was never
  -- closed. It must not swallow every later charge.
  coalesce(
    finished,
    lead(started) OVER (PARTITION BY loadpoint ORDER BY started),
    'infinity'
  ) AS ends
FROM (
  SELECT
    s.id,
    s.loadpoint,
    s.created AT TIME ZONE 'UTC' AS started,
    -- Empty (or the zero time) while the car is plugged in.
    CASE WHEN f.ts > s.created THEN f.ts AT TIME ZONE 'UTC' END AS finished,
    s.price
  FROM jsonb_to_recordset(:'sessions'::jsonb)
    AS s (id int, created timestamptz, finished text, price numeric, loadpoint text)
  CROSS JOIN LATERAL (SELECT nullif(s.finished, '')::timestamptz) AS f (ts)
) s;

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM evcc_session) THEN
    RAISE EXCEPTION 'evcc returned no sessions, refusing to fall back to net_price';
  END IF;
END $$;

CREATE TEMP TABLE home_charge ON COMMIT DROP AS
SELECT
  cp.id,
  cp.start_date,
  cp.end_date,
  cp.cost,
  coalesce(nullif(cp.charge_energy_used, 0), cp.charge_energy_added, 0) AS kwh
FROM charging_processes cp
JOIN geofences g ON g.id = cp.geofence_id
WHERE g.name = 'Home' AND cp.end_date IS NOT NULL;

-- One evcc session (plug-in to unplug) spans several TeslaMate charges when
-- PV surplus charging pauses. Its price is split by the energy each charge
-- drew inside the session, i.e. kWh times the share of the charge's
-- duration that overlaps the session.
CREATE TEMP TABLE overlap ON COMMIT DROP AS
SELECT
  c.id AS charge_id,
  s.id AS session_id,
  s.price,
  s.finished IS NOT NULL AND s.price IS NOT NULL AS settled,
  c.kwh * CASE
    WHEN c.end_date > c.start_date THEN
      extract(epoch FROM least(c.end_date, s.ends) - greatest(c.start_date, s.started))
      / extract(epoch FROM c.end_date - c.start_date)
    ELSE 1
  END AS weight
FROM home_charge c
JOIN evcc_session s ON c.start_date < s.ends AND c.end_date > s.started;

CREATE TEMP TABLE target ON COMMIT DROP AS
SELECT
  charge_id,
  round(sum(coalesce(price * weight / nullif(session_weight, 0), 0)), 2) AS cost,
  'evcc' AS source,
  array_agg(session_id ORDER BY session_id) AS session_ids
FROM (
  SELECT *, sum(weight) OVER (PARTITION BY session_id) AS session_weight
  FROM overlap
) o
GROUP BY charge_id
-- An open session's price still grows, so its charges wait until unplug.
HAVING bool_and(settled)
UNION ALL
SELECT c.id, round(:'net_price'::numeric * c.kwh, 2), 'fallback', NULL
FROM home_charge c
WHERE c.end_date < (now() AT TIME ZONE 'UTC') - interval '1 day'
  AND NOT EXISTS (SELECT FROM overlap o WHERE o.charge_id = c.id)
  -- A session missing from the response never downgrades an evcc price.
  AND NOT EXISTS (
    SELECT FROM evcc_sync.cost_log l
    WHERE l.charging_process_id = c.id AND l.source = 'evcc'
  );

-- Manual edits win: only overwrite a cost that is unset, 0, or still the
-- value this job wrote last time.
CREATE TEMP TABLE result ON COMMIT DROP AS
SELECT
  t.*,
  c.start_date,
  c.kwh,
  c.cost IS DISTINCT FROM t.cost AS differs,
  c.cost IS NULL OR c.cost = 0 OR c.cost IS NOT DISTINCT FROM l.cost AS writable
FROM target t
JOIN home_charge c ON c.id = t.charge_id
LEFT JOIN evcc_sync.cost_log l ON l.charging_process_id = t.charge_id;

UPDATE charging_processes cp
SET cost = r.cost
FROM result r
WHERE cp.id = r.charge_id AND r.differs AND r.writable;

INSERT INTO evcc_sync.cost_log
  (charging_process_id, cost, source, evcc_session_ids, updated_at)
SELECT charge_id, cost, source, session_ids, now()
FROM result
WHERE differs AND writable
ON CONFLICT (charging_process_id) DO UPDATE
SET cost = excluded.cost,
  source = excluded.source,
  evcc_session_ids = excluded.evcc_session_ids,
  updated_at = excluded.updated_at;

SELECT
  coalesce(month, 'total') AS month,
  count(*) FILTER (WHERE source = 'evcc' AND NOT skipped) AS evcc_n,
  coalesce(sum(kwh) FILTER (WHERE source = 'evcc' AND NOT skipped), 0) AS evcc_kwh,
  coalesce(sum(cost) FILTER (WHERE source = 'evcc' AND NOT skipped), 0) AS evcc_eur,
  count(*) FILTER (WHERE source = 'fallback' AND NOT skipped) AS fallback_n,
  coalesce(sum(kwh) FILTER (WHERE source = 'fallback' AND NOT skipped), 0) AS fallback_kwh,
  coalesce(sum(cost) FILTER (WHERE source = 'fallback' AND NOT skipped), 0) AS fallback_eur,
  count(*) FILTER (WHERE differs AND writable) AS updated,
  count(*) FILTER (WHERE skipped) AS skipped_manual
FROM (
  SELECT
    *,
    to_char(start_date AT TIME ZONE 'UTC' AT TIME ZONE 'Europe/Berlin', 'YYYY-MM') AS month,
    differs AND NOT writable AS skipped
  FROM result
) r
GROUP BY ROLLUP (month)
ORDER BY month NULLS LAST;

SELECT :'dry_run' = '1' AS dry_run \gset
\if :dry_run
\echo 'DRY_RUN=1, rolling back'
ROLLBACK;
\else
COMMIT;
\endif
