-- Mud Buggin LLC — Phase 1 schema
-- Run this in the Supabase SQL editor (or as a migration) on a fresh project.

create extension if not exists "pgcrypto";

-- Clients (retailers, resellers, etc.)
create table clients (
  id uuid primary key default gen_random_uuid(),
  business_name text not null,
  contact_name text,
  phone text,
  email text,
  address text,
  price_per_lb numeric(10,2) not null default 0,   -- current/live rate, shown to client at order time
  lead_time_hours integer not null default 24,      -- how far in advance an order must be placed
  notes text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- Pickups from the dock (his own supply)
create table pickups (
  id uuid primary key default gen_random_uuid(),
  pickup_date date not null default current_date,
  source text,                                       -- dock / supplier name
  total_weight_lbs numeric(10,2) not null default 0,
  cost_total numeric(10,2) not null default 0,
  notes text,
  photo_url text,        -- path within the 'pickup-photos' storage bucket, if a ticket photo was attached
  ocr_raw_text text,      -- raw text the ticket-reading Edge Function returned, kept for reference
  created_at timestamptz not null default now()
);

-- Storage bucket for pickup ticket photos (private; only authenticated users can read/write)
insert into storage.buckets (id, name, public) values ('pickup-photos', 'pickup-photos', false) on conflict (id) do nothing;
create policy "authenticated read pickup photos" on storage.objects for select using (bucket_id = 'pickup-photos' and auth.role() = 'authenticated');
create policy "authenticated upload pickup photos" on storage.objects for insert with check (bucket_id = 'pickup-photos' and auth.role() = 'authenticated');

-- Deliveries: one per drop-off to a client
create table deliveries (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references clients(id),
  delivery_date date not null default current_date,
  price_per_lb numeric(10,2) not null,   -- LOCKED at time of delivery, never recalculated retroactively
  status text not null default 'delivered',  -- delivered / invoiced / paid
  notes text,
  created_at timestamptz not null default now()
);

-- Individual sacks within a delivery, each with its own weight
create table delivery_sacks (
  id uuid primary key default gen_random_uuid(),
  delivery_id uuid not null references deliveries(id) on delete cascade,
  sack_number integer not null,
  weight_lbs numeric(10,2) not null
);

-- Invoices: one per delivery in Phase 1
create table invoices (
  id uuid primary key default gen_random_uuid(),
  invoice_number text not null unique,
  delivery_id uuid not null references deliveries(id),
  client_id uuid not null references clients(id),
  total_weight_lbs numeric(10,2) not null,
  price_per_lb numeric(10,2) not null,
  total_amount numeric(10,2) not null,
  status text not null default 'unpaid',  -- unpaid / paid
  sent_at timestamptz,
  created_at timestamptz not null default now()
);

create index on deliveries (client_id);
create index on delivery_sacks (delivery_id);
create index on invoices (client_id);
create index on invoices (delivery_id);

-- Simple invoice numbering: MB-000001, MB-000002, ...
create sequence invoice_number_seq start 1;
create or replace function next_invoice_number() returns text as $$
  select 'MB-' || lpad(nextval('invoice_number_seq')::text, 6, '0');
$$ language sql;

-- Lock the app down to logged-in users only (this is an internal tool, not public).
-- Create your one operator login under Authentication > Users in the Supabase dashboard.
alter table clients enable row level security;
alter table pickups enable row level security;
alter table deliveries enable row level security;
alter table delivery_sacks enable row level security;
alter table invoices enable row level security;

create policy "authenticated full access" on clients for all
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "authenticated full access" on pickups for all
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "authenticated full access" on deliveries for all
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "authenticated full access" on delivery_sacks for all
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "authenticated full access" on invoices for all
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
