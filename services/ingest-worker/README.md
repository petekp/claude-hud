# Capacitor Ingest Worker

Cloudflare Worker + D1 ingestion backend for Capacitor alpha feedback + telemetry.

## Endpoints

- `POST /v1/feedback`
- `POST /v1/telemetry`
- `GET /health`

`/v1/*` endpoints require bearer auth:

- `Authorization: Bearer <INGEST_KEY>`

## Setup

1. Install dependencies:

```bash
cd services/ingest-worker
npm install
```

2. Create a D1 database and capture its `database_id`:

```bash
npx wrangler d1 create capacitor-alpha
```

3. Update `wrangler.toml`:

- Set `database_id` in `[[d1_databases]]`.

4. Apply schema:

```bash
npx wrangler d1 migrations apply capacitor-alpha --remote
```

5. Set the ingest key secret:

```bash
npx wrangler secret put INGEST_KEY
```

6. Deploy:

```bash
npm run deploy
```

## Local dev

```bash
npm run dev
```

## Weekly triage report

Generate markdown report from D1 (last 7 days):

```bash
npm run triage -- --db capacitor-alpha --out ./reports/weekly-triage.md
```

Use `--local` to run against local D1.
