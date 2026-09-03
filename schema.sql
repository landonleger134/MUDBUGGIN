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
create or replace function next_invoice_number() returns text
  language sql
  set search_path = public
  as $$
    select 'MB-' || lpad(nextval('invoice_number_seq')::text, 6, '0');
  $$;

-- ===================================================================
-- Client Portal support (Phase 3)
-- ===================================================================

-- Distinguishes the operator (staff) from client portal logins, since both
-- are just "authenticated" Supabase users once the portal exists.
create table staff_users (
  user_id uuid primary key references auth.users(id)
);
alter table staff_users enable row level security;

create or replace function is_staff() returns boolean
  language sql security definer stable
  set search_path = public
  as $$
    select exists(select 1 from staff_users where user_id = auth.uid());
  $$;

-- After creating your operator login in Supabase, register it as staff:
-- insert into staff_users (user_id) values ('<your-auth-user-id>');

-- Links a client record to a portal login (set when you create their portal access)
alter table clients add column if not exists auth_user_id uuid references auth.users(id);

-- Order requests placed by clients through the portal
create table order_requests (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references clients(id),
  requested_sacks integer not null,
  requested_date date not null,
  notes text,
  status text not null default 'pending',  -- pending / acknowledged / fulfilled / declined
  created_at timestamptz not null default now()
);
alter table order_requests enable row level security;

create policy "staff full access" on order_requests for all using (is_staff()) with check (is_staff());
create policy "staff full access" on staff_users for all using (is_staff()) with check (is_staff());

create policy "client reads own record" on clients for select using (auth_user_id = auth.uid());
create policy "client reads own invoices" on invoices for select using (client_id in (select id from clients where auth_user_id = auth.uid()));
create policy "client reads own orders" on order_requests for select using (client_id in (select id from clients where auth_user_id = auth.uid()));
create policy "client inserts own order" on order_requests for insert with check (client_id in (select id from clients where auth_user_id = auth.uid()));

-- Links a delivery back to the order request it fulfilled, so the "Deliver" pipeline can mark it complete
alter table deliveries add column if not exists order_request_id uuid references order_requests(id);

-- What dock sellers say to expect in coming days (soft/unconfirmed — kept separate from real on-hand stock)
create table expected_pickups (
  id uuid primary key default gen_random_uuid(),
  expected_date date not null,
  source text,
  expected_weight_lbs numeric(10,2) not null,
  notes text,
  created_at timestamptz not null default now()
);
alter table expected_pickups enable row level security;
create policy "staff full access" on expected_pickups for all using (is_staff()) with check (is_staff());

-- Split single address into billing vs delivery (keeps old data via backfill)
alter table clients add column if not exists billing_address text;
alter table clients add column if not exists delivery_address text;
update clients set billing_address = coalesce(billing_address, address);
update clients set delivery_address = coalesce(delivery_address, address);

-- Per-day sack capacity, set based on what the operator expects to have on hand
create table daily_capacity (
  capacity_date date primary key,
  max_sacks integer not null
);
alter table daily_capacity enable row level security;
create policy "staff full access" on daily_capacity for all using (is_staff()) with check (is_staff());
create policy "authenticated can read capacity" on daily_capacity for select using (auth.role() = 'authenticated');

-- Lets a client (via the portal) check how full a day is without seeing other clients' order details
create or replace function booked_sacks_for_date(check_date date) returns integer
  language sql security definer stable
  set search_path = public
  as $$
    select coalesce(sum(requested_sacks),0)::integer
    from order_requests
    where requested_date = check_date and status in ('pending','confirmed');
  $$;
grant execute on function booked_sacks_for_date(date) to authenticated, anon;

-- Lock the app down: staff (you) get full access, clients only see their own data via the policies above.
alter table clients enable row level security;
alter table pickups enable row level security;
alter table deliveries enable row level security;
alter table delivery_sacks enable row level security;
alter table invoices enable row level security;

create policy "staff full access" on clients for all using (is_staff()) with check (is_staff());
create policy "staff full access" on pickups for all using (is_staff()) with check (is_staff());
create policy "staff full access" on deliveries for all using (is_staff()) with check (is_staff());
create policy "staff full access" on delivery_sacks for all using (is_staff()) with check (is_staff());
create policy "staff full access" on invoices for all using (is_staff()) with check (is_staff());
