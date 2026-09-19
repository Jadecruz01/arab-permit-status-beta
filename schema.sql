-- =====================================================================
-- City of Arab — Permit Status Checker : database schema
-- Run this whole file ONCE in the Supabase SQL Editor.
-- Everything is prefixed pm_ so it can share a Supabase project with
-- the Ticket Portal without touching its tables or logins.
--
-- Before running: Database > Extensions > enable  http  and  pg_cron
-- (pgcrypto is normally already on).
-- =====================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists http     with schema extensions;
create extension if not exists pg_cron;

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------
create table if not exists pm_sources (
  source          text primary key check (source in ('building','subtrade','sign')),
  label           text not null,
  csv_url         text,                       -- "Publish to web" CSV link of the Google Sheet
  mapping         jsonb not null,             -- field -> list of column headers to look for
  has_inspections boolean not null default true,
  last_sync_at    timestamptz,
  last_sync_ok    boolean,
  last_sync_msg   text,
  last_sync_rows  int,
  last_missing    text[]
);

create table if not exists pm_permits (
  id                 bigserial primary key,
  source             text not null references pm_sources(source) on delete cascade,
  row_num            int  not null,           -- row number in the sheet (header = 1)
  permit_no          text,
  submitted_on       date,
  applicant          text,
  address            text,
  permit_fee         numeric(12,2) not null default 0,
  cict_fee           numeric(12,2) not null default 0,
  grand_total        numeric(12,2),
  payment_type       text,
  paid               boolean not null default false,
  inspections        jsonb   not null default '{}'::jsonb,   -- only inspections that have data
  inspection_started boolean not null default false,
  coo_text           text,
  coo_given          boolean not null default false,
  complete           boolean not null default false          -- C of O given AND paid
);
create index if not exists pm_permits_permit_idx on pm_permits (lower(btrim(permit_no)));
create index if not exists pm_permits_date_idx   on pm_permits (submitted_on);
create index if not exists pm_permits_source_idx on pm_permits (source);

create table if not exists pm_staff_users (
  id            uuid primary key default gen_random_uuid(),
  username      text unique not null,
  password_hash text not null,
  created_at    timestamptz not null default now()
);
create table if not exists pm_staff_sessions (
  token      uuid primary key default gen_random_uuid(),
  user_id    uuid not null references pm_staff_users(id) on delete cascade,
  expires_at timestamptz not null
);
create table if not exists pm_login_attempts (
  id       bigserial primary key,
  username text not null,
  at       timestamptz not null default now()
);

-- Lock every table: no direct access for the public key. All access goes
-- through the SECURITY DEFINER functions below.
alter table pm_sources        enable row level security;
alter table pm_permits        enable row level security;
alter table pm_staff_users    enable row level security;
alter table pm_staff_sessions enable row level security;
alter table pm_login_attempts enable row level security;
revoke all on pm_sources, pm_permits, pm_staff_users, pm_staff_sessions, pm_login_attempts from anon, authenticated;
revoke all on sequence pm_permits_id_seq, pm_login_attempts_id_seq from anon, authenticated;

-- ---------------------------------------------------------------------
-- The three permit sheets and how to read their columns.
-- Each field lists header names to look for. If a header appears more than
-- once in the sheet (the form has several "Permit #" and "Date" columns),
-- every copy is checked and the first non-blank value wins.
-- ---------------------------------------------------------------------
with m as (
  select '{
    "permit_no":     ["Permit #"],
    "submitted_on":  ["Submission Date"],
    "applicant":     ["Applicant Name"],
    "address":       ["Address", "Property Address"],
    "permit_fee":    ["Permit Fee", "Permit Fee Background"],
    "cict_fee":      ["CICT Fee", "CICT Fee Background"],
    "grand_total":   ["Grand Total Fee Amount", "Total Fee Amount Background"],
    "payment_type":  ["Type of Payment Received"],
    "coo_given":     ["Certificate of Occupancy Given?"],
    "inspections":   ["Footing", "Framing", "Electrical", "Plumbing", "Final"]
  }'::jsonb as v
)
insert into pm_sources (source, label, mapping)
select x.source, x.label, m.v
from m, (values
  ('building', 'Building Permit – Contractor/Owner'),
  ('subtrade', 'Building Permit – Sub Trade'),
  ('sign',     'Sign Permit')
) as x(source, label)
on conflict (source) do nothing;

-- ---------------------------------------------------------------------
-- Internal helpers (not callable from the website)
-- ---------------------------------------------------------------------
create or replace function pm_norm(t text) returns text
language sql immutable as $$
  select lower(regexp_replace(regexp_replace(btrim(coalesce(t,'')), '\s+', ' ', 'g'), ':$', ''))
$$;

-- Proper CSV parser: handles quoted fields, commas and line breaks inside
-- quotes, and "" escapes. Returns one text[] per row.
create or replace function pm_parse_csv(p text) returns setof text[]
language plpgsql immutable as $$
declare
  r   record;
  cur text[] := '{}';
  src text := regexp_replace(coalesce(p,''), '^\ufeff', '');
begin
  for r in
    select m[1] as q, m[2] as u, m[3] as d
    from regexp_matches(src,
      '(?:"((?:[^"]|"")*)"|([^,\r\n]*))(,|\r\n|\n|\r|$)', 'g') as m
  loop
    cur := cur || coalesce(replace(r.q, '""', '"'), r.u, '');
    if r.d = ',' then
      continue;
    end if;
    -- end of a row
    if not (array_length(cur,1) = 1 and cur[1] = '') then
      return next cur;
    end if;
    cur := '{}';
  end loop;
  return;
end $$;

create or replace function pm_money(t text) returns numeric
language plpgsql immutable as $$
declare c text := regexp_replace(coalesce(t,''), '[^0-9.\-]', '', 'g');
begin
  if c = '' or c = '-' or c = '.' then return 0; end if;
  return round(c::numeric, 2);
exception when others then return 0;
end $$;

create or replace function pm_date(t text) returns date
language plpgsql immutable as $$
declare s text := btrim(coalesce(t,''));
begin
  if s = '' then return null; end if;
  if s ~ '^\d{4}-\d{1,2}-\d{1,2}' then
    return substring(s from '^\d{4}-\d{1,2}-\d{1,2}')::date;
  elsif s ~ '^\d{1,2}/\d{1,2}/\d{4}' then
    return to_date(substring(s from '^\d{1,2}/\d{1,2}/\d{4}'), 'MM/DD/YYYY');
  end if;
  return s::timestamp::date;
exception when others then return null;
end $$;

-- "Yes"-style check: blank or a negative word means no; anything else means yes.
create or replace function pm_truthy(t text) returns boolean
language sql immutable as $$
  select nullif(btrim(coalesce(t,'')),'') is not null
     and lower(btrim(t)) !~ '^(no|n|n/a|na|none|false|0|pending|not .*)$'
$$;

-- Column positions (1-based) in the header row whose name matches any candidate.
create or replace function pm_idx(hn text[], cands jsonb) returns int[]
language sql immutable as $$
  select coalesce(array_agg(i order by c.ord, i), '{}'::int[])
  from jsonb_array_elements_text(cands) with ordinality as c(v, ord)
  cross join lateral generate_subscripts(hn, 1) as i
  where hn[i] = pm_norm(c.v)
$$;

-- First non-blank value among the given column positions.
create or replace function pm_val(f text[], idx int[]) returns text
language sql immutable as $$
  select v from (
    select nullif(btrim(f[i]), '') as v, o
    from unnest(idx) with ordinality as u(i, o)
  ) t where v is not null order by o limit 1
$$;

-- Fiscal year (Oct 1 - Sep 30) named for the year it ends in.
create or replace function pm_fy(d date) returns int
language sql immutable as $$
  select case when d is null then null else extract(year from d + interval '3 months')::int end
$$;

-- ---------------------------------------------------------------------
-- Load a CSV body into pm_permits for one source (replaces that source's rows)
-- ---------------------------------------------------------------------
create or replace function pm_ingest_csv(p_source text, p_body text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  s       pm_sources%rowtype;
  m       jsonb;
  rec     record;
  hn      text[];
  missing text[] := '{}';
  k       text;
  nm      text;
  n       int := 0;
  i_permit int[]; i_date int[]; i_app int[]; i_addr int[]; i_fee int[]; i_cict int[];
  i_grand int[]; i_pay int[]; i_coo int[];
  insp_names text[]; insp_idx int[][]; insp_json jsonb; iv text; found_insp boolean := false;
  v_pay text; v_coo text; v_paid boolean; v_cooB boolean; v_inspB boolean; j int;
  insp_cols int[];
begin
  select * into s from pm_sources where source = p_source;
  if not found then raise exception 'unknown source %', p_source; end if;
  m := s.mapping;

  -- header row = first row returned
  select r into rec from pm_parse_csv(p_body) as r limit 1;
  if rec is null then raise exception 'The sheet came back empty.'; end if;
  hn := array(select pm_norm(x) from unnest(rec.r) with ordinality as t(x, o) order by o);

  i_permit := pm_idx(hn, m->'permit_no');
  i_date   := pm_idx(hn, m->'submitted_on');
  if coalesce(array_length(i_permit,1),0) = 0 or coalesce(array_length(i_date,1),0) = 0 then
    raise exception 'This does not look like the permit sheet (no "Permit #" / "Submission Date" columns found). Check the published link.';
  end if;
  i_app := pm_idx(hn, m->'applicant');   i_addr := pm_idx(hn, m->'address');
  i_fee := pm_idx(hn, m->'permit_fee');  i_cict := pm_idx(hn, m->'cict_fee');
  i_grand := pm_idx(hn, m->'grand_total'); i_pay := pm_idx(hn, m->'payment_type');
  i_coo := pm_idx(hn, m->'coo_given');

  for k in select unnest(array['applicant','address','permit_fee','cict_fee','payment_type','coo_given']) loop
    if coalesce(array_length(pm_idx(hn, m->k),1),0) = 0 then missing := missing || k; end if;
  end loop;

  select array_agg(x order by o) into insp_names
  from jsonb_array_elements_text(coalesce(m->'inspections','[]'::jsonb)) with ordinality as t(x, o);
  insp_names := coalesce(insp_names, '{}');
  foreach nm in array insp_names loop
    if coalesce(array_length(pm_idx(hn, to_jsonb(array[nm])),1),0) > 0 then found_insp := true;
    else missing := missing || ('inspection: ' || nm); end if;
  end loop;

  delete from pm_permits where source = p_source;

  for rec in select r as f, o from pm_parse_csv(p_body) with ordinality as t(r, o) where o > 1 order by o loop
    -- skip fully blank rows
    if not exists (select 1 from unnest(rec.f) as x where btrim(x) <> '') then continue; end if;

    v_pay := pm_val(rec.f, i_pay);
    v_paid := v_pay is not null;
    v_coo := pm_val(rec.f, i_coo);
    v_cooB := pm_truthy(v_coo);

    insp_json := '{}'::jsonb; v_inspB := false;
    foreach nm in array insp_names loop
      iv := pm_val(rec.f, pm_idx(hn, to_jsonb(array[nm])));
      if pm_truthy(iv) then
        insp_json := insp_json || jsonb_build_object(nm, iv);
        v_inspB := true;
      end if;
    end loop;

    insert into pm_permits (source, row_num, permit_no, submitted_on, applicant, address,
                            permit_fee, cict_fee, grand_total, payment_type, paid,
                            inspections, inspection_started, coo_text, coo_given, complete)
    values (p_source, rec.o::int, pm_val(rec.f, i_permit), pm_date(pm_val(rec.f, i_date)),
            pm_val(rec.f, i_app), pm_val(rec.f, i_addr),
            pm_money(pm_val(rec.f, i_fee)), pm_money(pm_val(rec.f, i_cict)),
            case when pm_val(rec.f, i_grand) is null then null else pm_money(pm_val(rec.f, i_grand)) end,
            v_pay, v_paid, insp_json, v_inspB, v_coo, v_cooB, (v_cooB and v_paid));
    n := n + 1;
  end loop;

  update pm_sources set has_inspections = found_insp, last_sync_at = now(), last_sync_ok = true,
         last_sync_msg = 'Synced ' || n || ' rows', last_sync_rows = n, last_missing = missing
   where source = p_source;
  return jsonb_build_object('ok', true, 'rows', n, 'missing', to_jsonb(missing));
end $$;

-- Download the published CSV and load it. Never raises: failures are recorded
-- on the source row and the previous data is kept.
create or replace function pm_sync_source(p_source text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare s pm_sources%rowtype; resp extensions.http_response; res jsonb;
begin
  select * into s from pm_sources where source = p_source;
  if not found then return jsonb_build_object('ok', false, 'error', 'unknown source'); end if;
  if s.csv_url is null or btrim(s.csv_url) = '' then
    return jsonb_build_object('ok', false, 'error', 'No sheet link saved yet');
  end if;
  begin
    begin   -- older versions of the http extension may not support these options; that's fine
      perform extensions.http_set_curlopt('CURLOPT_FOLLOWLOCATION', '1');
      perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '60');
    exception when others then null;
    end;
    resp := extensions.http_get(btrim(s.csv_url));
    if resp.status <> 200 then
      raise exception 'Google returned HTTP % for this link', resp.status;
    end if;
    res := pm_ingest_csv(p_source, resp.content);
    return res;
  exception when others then
    update pm_sources set last_sync_at = now(), last_sync_ok = false, last_sync_msg = left(sqlerrm, 300)
     where source = p_source;
    return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
end $$;

create or replace function pm_sync_all() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare s record;
begin
  for s in select source from pm_sources where nullif(btrim(coalesce(csv_url,'')),'') is not null loop
    perform pm_sync_source(s.source);
  end loop;
end $$;

create or replace function pm_auth(p_token uuid) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare u uuid;
begin
  select user_id into u from pm_staff_sessions where token = p_token and expires_at > now();
  if u is null then raise exception 'unauthorized' using errcode = '28000'; end if;
  return u;
end $$;

-- Create / reset a staff login. Run from the SQL Editor only.
create or replace function pm_create_staff(p_username text, p_password text) returns text
language plpgsql security definer set search_path = public, extensions as $$
begin
  if length(coalesce(p_password,'')) < 10 or p_password like 'PUT-A-STRONG%' then
    raise exception 'Choose a real password of at least 10 characters.';
  end if;
  insert into pm_staff_users (username, password_hash)
  values (lower(btrim(p_username)), crypt(p_password, gen_salt('bf')))
  on conflict (username) do update set password_hash = excluded.password_hash;
  return 'Staff login saved for ' || lower(btrim(p_username));
end $$;

revoke all on function pm_norm(text), pm_parse_csv(text), pm_money(text), pm_date(text), pm_truthy(text),
  pm_idx(text[], jsonb), pm_val(text[], int[]), pm_fy(date), pm_ingest_csv(text, text), pm_sync_source(text),
  pm_sync_all(), pm_auth(uuid), pm_create_staff(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Public function: permit status lookup.
-- The visitor must supply ALL of: permit type (which sheet), permit #,
-- date submitted, applicant name, and property address. Permit type,
-- permit # and date must match exactly; name and address match loosely
-- (word-based, ignoring case/punctuation/order, so "431 oak" finds
-- "431 Oak Ave, Arab, AL 35016" and "John Smith" finds "Smith, John").
-- Returns stage info only — no names, phone numbers, emails or amounts.
-- ---------------------------------------------------------------------
create or replace function pm_tokens_match(p_in text, p_stored text) returns boolean
language sql immutable as $$
  with i as (
    select t from unnest(regexp_split_to_array(lower(regexp_replace(coalesce(p_in,''), '[^a-zA-Z0-9]+', ' ', 'g')), '\s+')) as t where t <> ''
  ), s as (
    select t from unnest(regexp_split_to_array(lower(regexp_replace(coalesce(p_stored,''), '[^a-zA-Z0-9]+', ' ', 'g')), '\s+')) as t where t <> ''
  )
  select exists (select 1 from i) and not exists (
    select 1 from i where not exists (
      select 1 from s where s.t = i.t
         or (length(i.t) >= 3 and s.t like i.t || '%')      -- "oak" ~ "oaks", "mount" ~ "mountain"
         or (length(s.t) >= 3 and i.t like s.t || '%')      -- "avenue" ~ "ave"
    )
  )
$$;
revoke all on function pm_tokens_match(text, text) from public, anon, authenticated;

drop function if exists pm_search_permit(text, text, date, text, text);   -- older version that also asked for a permit number
create or replace function pm_search_permit(p_source text, p_date date, p_name text, p_address text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare out jsonb;
begin
  if p_source not in ('building','subtrade','sign') or p_date is null
     or length(btrim(coalesce(p_name,''))) < 2 or length(btrim(coalesce(p_address,''))) < 4 then
    return jsonb_build_object('ok', false, 'error', 'missing');
  end if;
  select coalesce(jsonb_agg(t.obj order by t.d desc nulls last), '[]'::jsonb)
  into out
  from (
    select p.submitted_on as d, jsonb_build_object(
      'source', p.source,
      'label', s.label,
      'permit_no', p.permit_no,
      'address', p.address,
      'submitted_on', p.submitted_on,
      'has_inspections', s.has_inspections,
      'inspection_started', p.inspection_started,
      'inspections', p.inspections,
      'paid', p.paid,
      'coo_given', p.coo_given,
      'complete', p.complete
    ) as obj
    from pm_permits p join pm_sources s on s.source = p.source
    where p.source = p_source
      and p.submitted_on = p_date
      and pm_tokens_match(p_name, p.applicant)
      and pm_tokens_match(p_address, p.address)
    order by p.submitted_on desc nulls last, p.permit_no
    limit 10
  ) t;
  return jsonb_build_object('ok', true, 'results', out);
end $$;

-- ---------------------------------------------------------------------
-- Staff functions (all require a valid session token)
-- ---------------------------------------------------------------------
create or replace function pm_staff_login(p_username text, p_password text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare u pm_staff_users%rowtype; uname text := lower(btrim(coalesce(p_username,''))); t uuid;
begin
  delete from pm_login_attempts where at < now() - interval '1 day';
  delete from pm_staff_sessions where expires_at < now();
  if (select count(*) from pm_login_attempts where username = uname and at > now() - interval '15 minutes') >= 5 then
    return jsonb_build_object('ok', false, 'error', 'locked');
  end if;
  select * into u from pm_staff_users where username = uname;
  if not found or u.password_hash <> crypt(coalesce(p_password,''), u.password_hash) then
    insert into pm_login_attempts (username) values (uname);
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  delete from pm_login_attempts where username = uname;
  insert into pm_staff_sessions (user_id, expires_at) values (u.id, now() + interval '12 hours') returning token into t;
  return jsonb_build_object('ok', true, 'token', t, 'username', u.username);
end $$;

create or replace function pm_staff_logout(p_token uuid) returns void
language sql security definer set search_path = public, extensions as $$
  delete from pm_staff_sessions where token = p_token
$$;

create or replace function pm_staff_change_password(p_token uuid, p_old text, p_new text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := pm_auth(p_token); u pm_staff_users%rowtype;
begin
  select * into u from pm_staff_users where id = uid;
  if u.password_hash <> crypt(coalesce(p_old,''), u.password_hash) then
    return jsonb_build_object('ok', false, 'error', 'Current password is incorrect.');
  end if;
  if length(coalesce(p_new,'')) < 10 then
    return jsonb_build_object('ok', false, 'error', 'New password must be at least 10 characters.');
  end if;
  update pm_staff_users set password_hash = crypt(p_new, gen_salt('bf')) where id = uid;
  return jsonb_build_object('ok', true);
end $$;

-- Fiscal years present in the data + sheet status
create or replace function pm_staff_meta(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare yrs int[]; srcs jsonb; undated int;
begin
  perform pm_auth(p_token);
  select array_agg(y order by y desc) into yrs from (
    select distinct pm_fy(submitted_on) as y from pm_permits where submitted_on is not null
    union select pm_fy(current_date)
  ) t;
  select jsonb_agg(jsonb_build_object(
      'source', source, 'label', label, 'csv_url', coalesce(csv_url,''), 'mapping', mapping,
      'last_sync_at', last_sync_at, 'last_sync_ok', last_sync_ok, 'last_sync_msg', last_sync_msg,
      'last_sync_rows', last_sync_rows, 'last_missing', coalesce(last_missing,'{}'),
      'has_inspections', has_inspections
    ) order by case source when 'building' then 1 when 'subtrade' then 2 else 3 end)
  into srcs from pm_sources;
  select count(*) into undated from pm_permits where submitted_on is null;
  return jsonb_build_object('years', to_jsonb(yrs), 'sources', srcs, 'undated', undated);
end $$;

-- Dashboard totals (p_fy null = overall)
create or replace function pm_staff_summary(p_token uuid, p_fy int) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare d1 date; d2 date; out jsonb;
begin
  perform pm_auth(p_token);
  if p_fy is not null then d1 := make_date(p_fy - 1, 10, 1); d2 := make_date(p_fy, 9, 30); end if;
  select jsonb_object_agg(source, obj) into out from (
    select s.source, jsonb_build_object(
      'label', s.label,
      'count', count(p.id),
      'fees', coalesce(sum(p.permit_fee), 0),
      'fees_paid', coalesce(sum(p.permit_fee) filter (where p.paid), 0),
      'cict', coalesce(sum(p.cict_fee), 0)
    ) as obj
    from pm_sources s
    left join pm_permits p on p.source = s.source
         and (p_fy is null or p.submitted_on between d1 and d2)
    group by s.source
  ) t;
  return out;
end $$;

-- Permit list for a fiscal year (used for the table and exports)
create or replace function pm_staff_permits(p_token uuid, p_fy int) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare d1 date; d2 date;
begin
  perform pm_auth(p_token);
  if p_fy is not null then d1 := make_date(p_fy - 1, 10, 1); d2 := make_date(p_fy, 9, 30); end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'source', p.source, 'label', s.label, 'permit_no', p.permit_no, 'submitted_on', p.submitted_on,
      'applicant', p.applicant, 'address', p.address,
      'permit_fee', p.permit_fee, 'cict_fee', p.cict_fee, 'paid', p.paid, 'payment_type', p.payment_type,
      'inspection_started', p.inspection_started, 'coo_given', p.coo_given, 'complete', p.complete
    ) order by p.submitted_on desc nulls last, p.permit_no)
    from pm_permits p join pm_sources s on s.source = p.source
    where p_fy is null or p.submitted_on between d1 and d2
  ), '[]'::jsonb);
end $$;

-- CICT report. p_month is the calendar month number (1-12) inside the fiscal year, or null for all months.
create or replace function pm_staff_cict(p_token uuid, p_fy int, p_month int, p_paid_only boolean) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare d1 date; d2 date; y int; out jsonb;
begin
  perform pm_auth(p_token);
  if p_fy is null then raise exception 'fiscal year required'; end if;
  if p_month is null then
    d1 := make_date(p_fy - 1, 10, 1); d2 := make_date(p_fy, 9, 30);
  else
    y := case when p_month >= 10 then p_fy - 1 else p_fy end;
    d1 := make_date(y, p_month, 1); d2 := (d1 + interval '1 month - 1 day')::date;
  end if;

  with f as (
    select p.*, s.label from pm_permits p join pm_sources s on s.source = p.source
    where p.submitted_on between d1 and d2 and p.cict_fee > 0
      and (not coalesce(p_paid_only, false) or p.paid)
  )
  select jsonb_build_object(
    'from', d1, 'to', d2,
    'total', coalesce((select sum(cict_fee) from f), 0),
    'paid_total', coalesce((select sum(cict_fee) from f where paid), 0),
    'count', (select count(*) from f),
    'by_source', coalesce((select jsonb_agg(jsonb_build_object('source', s.source, 'label', s.label,
        'count', coalesce(x.c, 0), 'cict', coalesce(x.t, 0)) order by case s.source when 'building' then 1 when 'subtrade' then 2 else 3 end)
        from pm_sources s left join (select source, count(*) c, sum(cict_fee) t from f group by source) x on x.source = s.source), '[]'::jsonb),
    'by_month', coalesce((select jsonb_agg(jsonb_build_object('month', ym, 'count', c, 'cict', t) order by ym)
        from (select to_char(submitted_on, 'YYYY-MM') ym, count(*) c, sum(cict_fee) t from f group by 1) q), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('source', source, 'label', label, 'permit_no', permit_no,
        'submitted_on', submitted_on, 'applicant', applicant, 'address', address, 'permit_fee', permit_fee,
        'cict_fee', cict_fee, 'paid', paid) order by submitted_on, permit_no) from f), '[]'::jsonb)
  ) into out;
  return out;
end $$;

create or replace function pm_staff_save_source(p_token uuid, p_source text, p_url text, p_mapping jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform pm_auth(p_token);
  update pm_sources set csv_url = nullif(btrim(coalesce(p_url,'')), ''),
         mapping = coalesce(p_mapping, mapping)
   where source = p_source;
  if not found then return jsonb_build_object('ok', false, 'error', 'unknown source'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- Sync now (p_source null = all three). Large sheets are better left to the hourly job if this times out.
create or replace function pm_staff_sync(p_token uuid, p_source text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare s record; res jsonb := '{}'::jsonb;
begin
  perform pm_auth(p_token);
  for s in select source from pm_sources where (p_source is null or source = p_source)
           and nullif(btrim(coalesce(csv_url,'')),'') is not null loop
    res := res || jsonb_build_object(s.source, pm_sync_source(s.source));
  end loop;
  return res;
end $$;

grant execute on function
  pm_search_permit(text, date, text, text), pm_staff_login(text, text), pm_staff_logout(uuid),
  pm_staff_change_password(uuid, text, text), pm_staff_meta(uuid), pm_staff_summary(uuid, int),
  pm_staff_permits(uuid, int), pm_staff_cict(uuid, int, int, boolean),
  pm_staff_save_source(uuid, text, text, jsonb), pm_staff_sync(uuid, text)
to anon, authenticated;

-- ---------------------------------------------------------------------
-- Automatic sync: every hour, whether or not anyone is logged in.
-- ---------------------------------------------------------------------
do $$
begin
  perform cron.unschedule('pm-permit-sync') where exists (select 1 from cron.job where jobname = 'pm-permit-sync');
  perform cron.schedule('pm-permit-sync', '0 * * * *', 'select public.pm_sync_all()');
end $$;

-- ---------------------------------------------------------------------
-- LAST STEP — create your first staff login. Edit the username/password
-- below, then run just this line. (It refuses weak/placeholder passwords.)
-- ---------------------------------------------------------------------
-- select pm_create_staff('admin', 'PUT-A-STRONG-PASSWORD-HERE');

notify pgrst, 'reload schema';
