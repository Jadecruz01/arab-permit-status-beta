# City of Arab — Permit Status

Public permit status lookup, plus a staff dashboard for fee totals and the monthly CICT report.

**Files**

- `index.html` — the whole site (public lookup, admin dashboard, CICT report, Excel/PDF/CSV export). No build step, no third-party libraries.
- `schema.sql` — the Supabase database (tables, functions, and the hourly Google Sheet sync). Everything is prefixed `pm_`, so it can share a Supabase project with the Ticket Portal.

**Setup**

1. In Supabase, enable the `http` and `pg_cron` extensions (Database → Extensions).
2. Paste `schema.sql` into the SQL Editor and run it. Then run `select pm_create_staff('admin', 'your-strong-password');` (edit the password first).
3. In `index.html`, fill in `SUPABASE_URL` and `SUPABASE_ANON_KEY` near the top of the script. While they are blank the site runs in demo mode with sample data (login `admin` / `demo1234`).
4. Turn on GitHub Pages (Settings → Pages → Deploy from branch → `main` / root).
5. Log in at `…/#admin`, open **Sheets & Sync**, paste the published CSV link for each Google Sheet, and choose **Save & sync now**. After that the data refreshes every hour on its own.

**How stages are decided**

- Submitted — the permit is in the sheet.
- Inspection — any of Footing, Framing, Electrical, Plumbing or Final has a value.
- Payment received — *Type of Payment Received* has a value.
- Complete & issued — *Certificate of Occupancy Given?* is yes **and** payment has been received.

Fiscal years run October 1 – September 30 and are named for the year they end (FY2026 = 10/1/2025 – 9/30/2026). CICT and fee totals are counted by submission date.
