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
6. Open the **Users** tab to add people, choose their access level, and (as an administrator) customize what Staff and Viewer can do under **Role permissions**.

**Overriding a permit's status**

An administrator can tick permits in the Overview table and choose **Mark complete…**. After re-entering their own password (and, optionally, a reason), every step (inspection, payment, Certificate of Occupancy, complete) shows as done when the applicant looks the permit up, and the dashboard's paid/unpaid amounts and the CICT paid-only report count the permit as paid. The fee amounts and the Google Sheet data are not changed, the dashboard notes how much of the paid total is by override, the override survives the hourly sync, and every override and removal is recorded with who did it and when. Use **Remove override** to go back to what the sheet says.

**Permit PDFs**

Staff and administrators can tick one or more permits in the Overview table and choose **Download permit PDF**. Each permit gets a formatted record (status tracker, summary, and every field from the sheet). Any field whose name contains "background" is left out. The full field list is stored at each sync, so permits already loaded need one more sync before their details appear.

**Update notices**

There are two separate notices. The public permit lookup shows its own notice whenever the page loads, and the staff area shows its own when it opens (after signing in, or on refresh). Closing a notice shrinks it into a banner at the top that goes away by itself after about a minute. When you change `index.html`, edit only the matching block in `RELEASES` (`public` for the lookup, `admin` for the staff area: version, date, notes) so each side only describes its own updates.

A "Beta" label shows at the top of both sides of the site.

**Access levels**

- Administrator — everything, plus adding and managing users, changing the Google Sheet links, and editing what Staff and Viewer can do (see **Role permissions** below).
- Staff — dashboard, permit list with names and addresses, permit PDFs, CICT report, and Excel/PDF/CSV exports, by default.
- Viewer — dashboard and CICT totals only by default. No names, addresses or exports.

Levels are enforced in the database, not just hidden on the page. Deactivating a user signs them out immediately. Administrators cannot lower, deactivate or delete their own login, so at least one administrator always remains. An administrator's own account can only be edited, password-reset or deleted by another administrator — granting Staff or Viewer full access to the Users tab never lets them touch an administrator account or promote anyone to Administrator.

**Role permissions**

An administrator can open the **Users** tab and scroll to **Role permissions** to change exactly what Staff and Viewer can see and do — this replaces the fixed descriptions above with whatever an administrator sets. For each role, choose a level for each tab (No access / View / Edit — Overview and CICT Report only go up to View) and toggle the individual actions: seeing applicant names & addresses, exporting files, downloading permit PDFs, and marking permits complete (override). Turning on permit PDFs or override automatically turns on names & addresses too, since both need the permit list. **Reset to defaults** clears any customization for that role and goes back to the descriptions above. Administrators always have full access and cannot be restricted here. Every change is logged with who made it and when.

**How stages are decided**

- Submitted — the permit is in the sheet.
- Inspection — any of Footing, Framing, Electrical, Plumbing or Final has a value.
- Payment received — *Type of Payment Received* has a value.
- Complete & issued — *Certificate of Occupancy Given?* is yes **and** payment has been received.

Fiscal years run October 1 – September 30 and are named for the year they end (FY2026 = 10/1/2025 – 9/30/2026). CICT and fee totals are counted by submission date.
