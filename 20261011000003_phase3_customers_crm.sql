-- RANIBO Phase 3: customers, CRM follow-ups, order payments
-- Run AFTER the Phase 1 and Phase 2 migrations, once, in Supabase Dashboard -> SQL Editor.
--
-- STATUS: written but NOT yet executed against any database by its author.
-- Run supabase/tests/04_phase3_test.sql on a scratch database first (see README-phase3.md).
--
-- Design rules (same as Phase 2):
--   * Every new table has business_id, Row Level Security, and select-only access for clients.
--   * All writes go through the SECURITY DEFINER functions at the bottom of this file.
--   * Composite foreign keys (id, business_id) make cross-business links impossible.
--   * Money figures are always computed from orders and order_payments, never stored twice.
--
-- Definitions used by the customer_summary view (change them here if your business differs):
--   "Valid order"  = an order linked to the customer whose status is confirmed, shipped or delivered.
--                    Pending (not yet a sale), cancelled and returned orders are NOT counted.
--   Total purchases = sum of total_amount over valid orders.
--   Total paid      = sum of non-voided payments on valid orders.
--   Outstanding     = total purchases - total paid (over valid orders only).
--   Segment (checked in this order):
--     inactive  = last valid order (or, with no valid order, the creation date) is older than 60 days
--     returning = 2 or more valid orders, and not inactive
--     new       = everything else (0 or 1 valid order, and not inactive)

-- ---------------------------------------------------------------------------
-- Helper: clean up a tag list (lowercase, trimmed, de-duplicated, max 10, each <= 30 chars)
-- ---------------------------------------------------------------------------
create function public.normalize_tags(p_tags text[])
returns text[]
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_out text[] := '{}';
  v_tag text;
begin
  if p_tags is null then
    return v_out;
  end if;
  foreach v_tag in array p_tags loop
    v_tag := lower(btrim(coalesce(v_tag, '')));
    if v_tag = '' then
      continue;
    end if;
    if char_length(v_tag) > 30 then
      raise exception 'Each tag must be 30 characters or fewer' using errcode = 'RB001';
    end if;
    if not (v_tag = any (v_out)) then
      v_out := v_out || v_tag;
    end if;
  end loop;
  if coalesce(array_length(v_out, 1), 0) > 10 then
    raise exception 'Use at most 10 tags per customer' using errcode = 'RB001';
  end if;
  return v_out;
end;
$$;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table public.customers (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  name        text not null check (char_length(btrim(name)) between 1 and 150),
  phone       text check (phone is null or char_length(phone) between 1 and 30),
  email       text check (email is null or char_length(email) <= 254),
  address     text check (address is null or char_length(address) <= 500),
  notes       text check (notes is null or char_length(notes) <= 2000),
  tags        text[] not null default '{}'
              check (coalesce(array_length(tags, 1), 0) <= 10),
  created_by  uuid references auth.users (id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (id, business_id)
);

-- One customer per phone number inside a business (spaces, dashes and brackets are ignored).
create unique index customers_business_phone_key
  on public.customers (business_id, regexp_replace(phone, '[^0-9+]', '', 'g'))
  where phone is not null;
create index customers_business_name_idx    on public.customers (business_id, lower(name));
create index customers_business_created_idx on public.customers (business_id, created_at desc);

create trigger customers_set_updated_at
  before update on public.customers
  for each row execute function public.set_updated_at();

-- Link orders to customers. Optional: older Phase 2 orders stay unlinked until you link them.
alter table public.orders add column customer_id uuid;
alter table public.orders
  add constraint orders_customer_fk
  foreign key (customer_id, business_id) references public.customers (id, business_id);
create index orders_customer_idx on public.orders (customer_id, created_at desc)
  where customer_id is not null;

create table public.customer_followups (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null,
  customer_id  uuid not null,
  due_at       timestamptz not null,
  purpose      text not null check (char_length(btrim(purpose)) between 1 and 200),
  notes        text check (notes is null or char_length(notes) <= 1000),
  status       text not null default 'open' check (status in ('open', 'done', 'cancelled')),
  assigned_to  uuid references auth.users (id),
  completed_at timestamptz,
  created_by   uuid not null references auth.users (id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  foreign key (customer_id, business_id)
    references public.customers (id, business_id) on delete cascade,
  check ((status = 'done') = (completed_at is not null))
);

create index followups_business_status_due_idx
  on public.customer_followups (business_id, status, due_at);
create index followups_customer_idx on public.customer_followups (customer_id, due_at desc);
create index followups_assigned_idx
  on public.customer_followups (assigned_to, status, due_at) where assigned_to is not null;

create trigger customer_followups_set_updated_at
  before update on public.customer_followups
  for each row execute function public.set_updated_at();

create table public.order_payments (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  order_id    uuid not null,
  amount      numeric(14, 2) not null check (amount > 0),
  method      text not null
              check (method in ('cash', 'bkash', 'nagad', 'rocket', 'bank_transfer', 'card', 'other')),
  reference   text check (reference is null or char_length(reference) <= 100),
  note        text check (note is null or char_length(note) <= 300),
  paid_at     timestamptz not null default now(),
  created_by  uuid not null references auth.users (id),
  created_at  timestamptz not null default now(),
  -- Payments are never deleted. A mistaken payment is voided with a reason, so history stays.
  voided_at   timestamptz,
  voided_by   uuid references auth.users (id),
  void_reason text check (void_reason is null or char_length(void_reason) <= 300),
  foreign key (order_id, business_id)
    references public.orders (id, business_id) on delete cascade,
  check ((voided_at is null) = (voided_by is null))
);

create index order_payments_order_idx on public.order_payments (order_id, paid_at desc);
create index order_payments_business_idx on public.order_payments (business_id, paid_at desc);

-- ---------------------------------------------------------------------------
-- Views (security_invoker: they run with the caller's rights, so Row Level Security applies)
-- ---------------------------------------------------------------------------
create view public.order_payment_summary
with (security_invoker = true) as
select
  o.id          as order_id,
  o.business_id as business_id,
  o.total_amount,
  coalesce(sum(p.amount) filter (where p.voided_at is null), 0)::numeric(14, 2) as paid_amount
from public.orders o
left join public.order_payments p
  on p.order_id = o.id and p.business_id = o.business_id
group by o.id, o.business_id, o.total_amount;

create view public.customer_summary
with (security_invoker = true) as
with valid as (
  select o.customer_id, o.total_amount, o.created_at, ps.paid_amount
  from public.orders o
  join public.order_payment_summary ps on ps.order_id = o.id
  where o.customer_id is not null
    and o.status in ('confirmed', 'shipped', 'delivered')
),
agg as (
  select customer_id,
         count(*)                as valid_orders,
         sum(total_amount)       as total_purchases,
         sum(paid_amount)        as total_paid,
         max(created_at)         as last_order_at
  from valid
  group by customer_id
),
all_orders as (
  select customer_id, count(*) as linked_orders
  from public.orders
  where customer_id is not null
  group by customer_id
)
select
  c.id,
  c.business_id,
  c.name,
  c.phone,
  c.email,
  c.address,
  c.notes,
  c.tags,
  c.created_at,
  coalesce(ao.linked_orders, 0)                       as linked_order_count,
  coalesce(a.valid_orders, 0)                         as valid_order_count,
  coalesce(a.total_purchases, 0)::numeric(14, 2)      as total_purchases,
  coalesce(a.total_paid, 0)::numeric(14, 2)           as total_paid,
  (coalesce(a.total_purchases, 0) - coalesce(a.total_paid, 0))::numeric(14, 2) as outstanding_balance,
  a.last_order_at,
  case
    when coalesce(a.last_order_at, c.created_at) < now() - interval '60 days' then 'inactive'
    when coalesce(a.valid_orders, 0) >= 2 then 'returning'
    else 'new'
  end as segment
from public.customers c
left join agg a         on a.customer_id = c.id
left join all_orders ao on ao.customer_id = c.id;

-- ---------------------------------------------------------------------------
-- Privileges: clients can only read. Everything else goes through the functions below.
-- ---------------------------------------------------------------------------
revoke all on public.customers          from anon, authenticated;
revoke all on public.customer_followups from anon, authenticated;
revoke all on public.order_payments     from anon, authenticated;
revoke all on public.order_payment_summary from anon, authenticated;
revoke all on public.customer_summary   from anon, authenticated;

grant select on public.customers, public.customer_followups, public.order_payments,
                public.order_payment_summary, public.customer_summary
  to authenticated;

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
alter table public.customers          enable row level security;
alter table public.customer_followups enable row level security;
alter table public.order_payments     enable row level security;

create policy customers_select_member on public.customers
  for select to authenticated
  using (public.is_business_member(business_id));

create policy followups_select_member on public.customer_followups
  for select to authenticated
  using (public.is_business_member(business_id));

create policy order_payments_select_member on public.order_payments
  for select to authenticated
  using (public.is_business_member(business_id));

-- ---------------------------------------------------------------------------
-- Functions. Messages raised with errcode RB001 are written to be shown to the user as-is.
-- ---------------------------------------------------------------------------

-- Internal validation shared by create_customer and update_customer.
create function public.check_customer_fields(
  p_name text, p_phone text, p_email text, p_address text, p_notes text
)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if char_length(p_name) < 1 or char_length(p_name) > 150 then
    raise exception 'Customer name must be 1 to 150 characters' using errcode = 'RB001';
  end if;
  if p_phone is not null then
    if char_length(p_phone) > 30
       or char_length(regexp_replace(p_phone, '[^0-9]', '', 'g')) not between 6 and 15
       or p_phone !~ '^[0-9+()\- ]+$' then
      raise exception 'Enter a valid phone number (6 to 15 digits; only digits, spaces, + ( ) - allowed)'
        using errcode = 'RB001';
    end if;
  end if;
  if p_email is not null and (char_length(p_email) > 254 or p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') then
    raise exception 'Enter a valid email address' using errcode = 'RB001';
  end if;
  if p_address is not null and char_length(p_address) > 500 then
    raise exception 'Address must be 500 characters or fewer' using errcode = 'RB001';
  end if;
  if p_notes is not null and char_length(p_notes) > 2000 then
    raise exception 'Notes must be 2000 characters or fewer' using errcode = 'RB001';
  end if;
end;
$$;

create function public.create_customer(
  p_business_id uuid,
  p_name        text,
  p_phone       text,
  p_email       text,
  p_address     text,
  p_notes       text,
  p_tags        text[]
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user  uuid := auth.uid();
  v_id    uuid;
  v_name  text := btrim(coalesce(p_name, ''));
  v_phone text := nullif(btrim(coalesce(p_phone, '')), '');
  v_email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  v_addr  text := nullif(btrim(coalesce(p_address, '')), '');
  v_notes text := nullif(btrim(coalesce(p_notes, '')), '');
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;
  if not public.is_business_member(p_business_id) then
    raise exception 'You do not have permission to add customers to this business' using errcode = 'RB001';
  end if;

  perform public.check_customer_fields(v_name, v_phone, v_email, v_addr, v_notes);

  begin
    insert into public.customers (business_id, name, phone, email, address, notes, tags, created_by)
    values (p_business_id, v_name, v_phone, v_email, v_addr, v_notes, public.normalize_tags(p_tags), v_user)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'A customer with this phone number already exists in this business' using errcode = 'RB001';
  end;

  return v_id;
end;
$$;

create function public.update_customer(
  p_customer_id uuid,
  p_name        text,
  p_phone       text,
  p_email       text,
  p_address     text,
  p_notes       text,
  p_tags        text[]
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user     uuid := auth.uid();
  v_business uuid;
  v_name     text := btrim(coalesce(p_name, ''));
  v_phone    text := nullif(btrim(coalesce(p_phone, '')), '');
  v_email    text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  v_addr     text := nullif(btrim(coalesce(p_address, '')), '');
  v_notes    text := nullif(btrim(coalesce(p_notes, '')), '');
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  select business_id into v_business from public.customers where id = p_customer_id;
  if v_business is null or not public.is_business_member(v_business) then
    raise exception 'Customer not found' using errcode = 'RB001';
  end if;

  perform public.check_customer_fields(v_name, v_phone, v_email, v_addr, v_notes);

  begin
    update public.customers
    set name = v_name, phone = v_phone, email = v_email, address = v_addr,
        notes = v_notes, tags = public.normalize_tags(p_tags)
    where id = p_customer_id and business_id = v_business;
  exception when unique_violation then
    raise exception 'A customer with this phone number already exists in this business' using errcode = 'RB001';
  end;
end;
$$;

-- Deleting a customer keeps their orders (each order already stores the customer's name,
-- phone and address as written at the time); the orders are simply unlinked.
create function public.delete_customer(p_customer_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user     uuid := auth.uid();
  v_business uuid;
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  select business_id into v_business from public.customers where id = p_customer_id;
  if v_business is null
     or not public.has_business_role(v_business, array['owner', 'admin', 'manager']::public.member_role[]) then
    raise exception 'Customer not found, or you do not have permission to delete customers' using errcode = 'RB001';
  end if;

  update public.orders set customer_id = null
  where customer_id = p_customer_id and business_id = v_business;

  delete from public.customers where id = p_customer_id and business_id = v_business;
end;
$$;

-- Creates an order for an existing customer. The customer's current name/phone/email/address
-- are copied onto the order (as in Phase 2), then the order is linked to the customer.
-- Both steps happen in one transaction, so there is never a half-created order.
create function public.create_order_with_customer(
  p_business_id uuid,
  p_customer_id uuid,
  p_notes       text,
  p_items       jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user     uuid := auth.uid();
  v_customer public.customers%rowtype;
  v_order_id uuid;
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;
  if not public.is_business_member(p_business_id) then
    raise exception 'You do not have permission to create orders in this business' using errcode = 'RB001';
  end if;

  select * into v_customer
  from public.customers
  where id = p_customer_id and business_id = p_business_id
  for share;
  if not found then
    raise exception 'Customer not found' using errcode = 'RB001';
  end if;

  v_order_id := public.create_order(
    p_business_id, v_customer.name, v_customer.phone, v_customer.email,
    v_customer.address, p_notes, p_items
  );

  update public.orders set customer_id = p_customer_id
  where id = v_order_id and business_id = p_business_id;

  return v_order_id;
end;
$$;

-- For back-filling real Phase 2 orders that were typed in by hand before customers existed.
-- Nothing is linked automatically: a manager chooses the match.
create function public.link_order_to_customer(p_order_id uuid, p_customer_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user     uuid := auth.uid();
  v_business uuid;
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  select business_id into v_business from public.orders where id = p_order_id;
  if v_business is null
     or not public.has_business_role(v_business, array['owner', 'admin', 'manager']::public.member_role[]) then
    raise exception 'Order not found, or you do not have permission to link orders' using errcode = 'RB001';
  end if;

  if not exists (select 1 from public.customers where id = p_customer_id and business_id = v_business) then
    raise exception 'Customer not found' using errcode = 'RB001';
  end if;

  update public.orders set customer_id = p_customer_id
  where id = p_order_id and business_id = v_business;
end;
$$;

-- ----------------------------- follow-ups -----------------------------------
create function public.create_followup(
  p_customer_id uuid,
  p_due_at      timestamptz,
  p_purpose     text,
  p_notes       text,
  p_assigned_to uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user     uuid := auth.uid();
  v_business uuid;
  v_id       uuid;
  v_purpose  text := btrim(coalesce(p_purpose, ''));
  v_notes    text := nullif(btrim(coalesce(p_notes, '')), '');
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  select business_id into v_business from public.customers where id = p_customer_id;
  if v_business is null or not public.is_business_member(v_business) then
    raise exception 'Customer not found' using errcode = 'RB001';
  end if;

  if p_due_at is null or p_due_at < now() - interval '1 day' or p_due_at > now() + interval '5 years' then
    raise exception 'Choose a follow-up date and time from yesterday up to 5 years ahead' using errcode = 'RB001';
  end if;
  if char_length(v_purpose) < 1 or char_length(v_purpose) > 200 then
    raise exception 'Purpose must be 1 to 200 characters' using errcode = 'RB001';
  end if;
  if v_notes is not null and char_length(v_notes) > 1000 then
    raise exception 'Notes must be 1000 characters or fewer' using errcode = 'RB001';
  end if;
  if p_assigned_to is not null
     and not exists (select 1 from public.memberships where business_id = v_business and user_id = p_assigned_to) then
    raise exception 'The assigned person is not a member of this business' using errcode = 'RB001';
  end if;

  insert into public.customer_followups
    (business_id, customer_id, due_at, purpose, notes, assigned_to, created_by)
  values
    (v_business, p_customer_id, p_due_at, v_purpose, v_notes, p_assigned_to, v_user)
  returning id into v_id;

  return v_id;
end;
$$;

-- Managers can change any follow-up. Other members can change follow-ups they created
-- or that are assigned to them.
create function public.update_followup(
  p_followup_id uuid,
  p_due_at      timestamptz,
  p_purpose     text,
  p_notes       text,
  p_assigned_to uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user     uuid := auth.uid();
  v_row      public.customer_followups%rowtype;
  v_purpose  text := btrim(coalesce(p_purpose, ''));
  v_notes    text := nullif(btrim(coalesce(p_notes, '')), '');
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  select * into v_row from public.customer_followups where id = p_followup_id;
  if not found
     or not public.is_business_member(v_row.business_id)
     or not (
       public.has_business_role(v_row.business_id, array['owner', 'admin', 'manager']::public.member_role[])
       or v_row.created_by = v_user
       or v_row.assigned_to = v_user
     ) then
    raise exception 'Follow-up not found, or you do not have permission to change it' using errcode = 'RB001';
  end if;

  if v_row.status <> 'open' then
    raise exception 'Only open follow-ups can be edited. Reopen it first.' using errcode = 'RB001';
  end if;
  -- An already-overdue follow-up may keep its original date; a changed date must be sensible.
  if p_due_at is null
     or (p_due_at is distinct from v_row.due_at
         and (p_due_at < now() - interval '1 day' or p_due_at > now() + interval '5 years')) then
    raise exception 'Choose a follow-up date and time from yesterday up to 5 years ahead' using errcode = 'RB001';
  end if;
  if char_length(v_purpose) < 1 or char_length(v_purpose) > 200 then
    raise exception 'Purpose must be 1 to 200 characters' using errcode = 'RB001';
  end if;
  if v_notes is not null and char_length(v_notes) > 1000 then
    raise exception 'Notes must be 1000 characters or fewer' using errcode = 'RB001';
  end if;
  if p_assigned_to is not null
     and not exists (select 1 from public.memberships where business_id = v_row.business_id and user_id = p_assigned_to) then
    raise exception 'The assigned person is not a member of this business' using errcode = 'RB001';
  end if;

  update public.customer_followups
  set due_at = p_due_at, purpose = v_purpose, notes = v_notes, assigned_to = p_assigned_to
  where id = p_followup_id and business_id = v_row.business_id;
end;
$$;

create function public.set_followup_status(p_followup_id uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_row  public.customer_followups%rowtype;
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;
  if p_status is null or p_status not in ('open', 'done', 'cancelled') then
    raise exception 'Status must be open, done or cancelled' using errcode = 'RB001';
  end if;

  select * into v_row from public.customer_followups where id = p_followup_id for update;
  if not found
     or not public.is_business_member(v_row.business_id)
     or not (
       public.has_business_role(v_row.business_id, array['owner', 'admin', 'manager']::public.member_role[])
       or v_row.created_by = v_user
       or v_row.assigned_to = v_user
     ) then
    raise exception 'Follow-up not found, or you do not have permission to change it' using errcode = 'RB001';
  end if;

  update public.customer_followups
  set status = p_status,
      completed_at = case when p_status = 'done' then now() else null end
  where id = p_followup_id and business_id = v_row.business_id;
end;
$$;

-- Lets the app show names in the "assigned to" list. Only members of the business can call it.
create function public.list_business_members(p_business_id uuid)
returns table (user_id uuid, role text, display_name text, email text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;
  if not public.is_business_member(p_business_id) then
    raise exception 'You do not have permission to view this business' using errcode = 'RB001';
  end if;

  return query
  select m.user_id,
         m.role::text,
         coalesce(nullif(btrim(u.raw_user_meta_data ->> 'full_name'), ''), split_part(u.email, '@', 1))::text,
         u.email::text
  from public.memberships m
  join auth.users u on u.id = m.user_id
  where m.business_id = p_business_id
  order by m.created_at;
end;
$$;

-- ----------------------------- payments -------------------------------------
-- Any member can record a payment; only managers can void one. Rules enforced here:
--   * the order must not be cancelled or returned
--   * the payment cannot push the total paid above the order total
--   * the order row is locked, so two simultaneous payments cannot overpay it
create function public.record_payment(
  p_order_id  uuid,
  p_amount    numeric,
  p_method    text,
  p_reference text,
  p_note      text,
  p_paid_at   timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user      uuid := auth.uid();
  v_business  uuid;
  v_status    public.order_status;
  v_total     numeric(14, 2);
  v_paid      numeric(14, 2);
  v_id        uuid;
  v_reference text := nullif(btrim(coalesce(p_reference, '')), '');
  v_note      text := nullif(btrim(coalesce(p_note, '')), '');
  v_paid_at   timestamptz := coalesce(p_paid_at, now());
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  select business_id into v_business from public.orders where id = p_order_id;
  if v_business is null or not public.is_business_member(v_business) then
    raise exception 'Order not found' using errcode = 'RB001';
  end if;

  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then
    raise exception 'Enter an amount above zero with at most 2 decimal places' using errcode = 'RB001';
  end if;
  if p_method is null or p_method not in ('cash', 'bkash', 'nagad', 'rocket', 'bank_transfer', 'card', 'other') then
    raise exception 'Choose a valid payment method' using errcode = 'RB001';
  end if;
  if v_reference is not null and char_length(v_reference) > 100 then
    raise exception 'Reference must be 100 characters or fewer' using errcode = 'RB001';
  end if;
  if v_note is not null and char_length(v_note) > 300 then
    raise exception 'Note must be 300 characters or fewer' using errcode = 'RB001';
  end if;
  if v_paid_at > now() + interval '5 minutes' then
    raise exception 'Payment date cannot be in the future' using errcode = 'RB001';
  end if;

  select status, total_amount into v_status, v_total
  from public.orders
  where id = p_order_id and business_id = v_business
  for update;

  if v_status in ('cancelled', 'returned') then
    raise exception 'Payments cannot be recorded on a % order', v_status using errcode = 'RB001';
  end if;

  select coalesce(sum(amount), 0) into v_paid
  from public.order_payments
  where order_id = p_order_id and business_id = v_business and voided_at is null;

  if v_paid + p_amount > v_total then
    raise exception 'This payment is more than the outstanding balance (%)', (v_total - v_paid)
      using errcode = 'RB001';
  end if;

  insert into public.order_payments
    (business_id, order_id, amount, method, reference, note, paid_at, created_by)
  values
    (v_business, p_order_id, p_amount, p_method, v_reference, v_note, v_paid_at, v_user)
  returning id into v_id;

  return v_id;
end;
$$;

create function public.void_payment(p_payment_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user     uuid := auth.uid();
  v_business uuid;
  v_voided   timestamptz;
  v_reason   text := btrim(coalesce(p_reason, ''));
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  select business_id into v_business from public.order_payments where id = p_payment_id;
  if v_business is null
     or not public.has_business_role(v_business, array['owner', 'admin', 'manager']::public.member_role[]) then
    raise exception 'Payment not found, or you do not have permission to void payments' using errcode = 'RB001';
  end if;

  if char_length(v_reason) < 1 or char_length(v_reason) > 300 then
    raise exception 'Enter a reason (1 to 300 characters)' using errcode = 'RB001';
  end if;

  select voided_at into v_voided
  from public.order_payments
  where id = p_payment_id and business_id = v_business
  for update;
  if v_voided is not null then
    raise exception 'This payment is already voided' using errcode = 'RB001';
  end if;

  update public.order_payments
  set voided_at = now(), voided_by = v_user, void_reason = v_reason
  where id = p_payment_id and business_id = v_business;
end;
$$;

-- ---------------------------------------------------------------------------
-- Function privileges: nobody by default, then only logged-in users for the public ones.
-- ---------------------------------------------------------------------------
revoke all on function public.normalize_tags(text[])                          from public, anon, authenticated;
revoke all on function public.check_customer_fields(text, text, text, text, text) from public, anon, authenticated;

revoke all on function public.create_customer(uuid, text, text, text, text, text, text[]) from public, anon, authenticated;
revoke all on function public.update_customer(uuid, text, text, text, text, text, text[]) from public, anon, authenticated;
revoke all on function public.delete_customer(uuid)                           from public, anon, authenticated;
revoke all on function public.create_order_with_customer(uuid, uuid, text, jsonb) from public, anon, authenticated;
revoke all on function public.link_order_to_customer(uuid, uuid)              from public, anon, authenticated;
revoke all on function public.create_followup(uuid, timestamptz, text, text, uuid) from public, anon, authenticated;
revoke all on function public.update_followup(uuid, timestamptz, text, text, uuid) from public, anon, authenticated;
revoke all on function public.set_followup_status(uuid, text)                 from public, anon, authenticated;
revoke all on function public.list_business_members(uuid)                     from public, anon, authenticated;
revoke all on function public.record_payment(uuid, numeric, text, text, text, timestamptz) from public, anon, authenticated;
revoke all on function public.void_payment(uuid, text)                        from public, anon, authenticated;

grant execute on function public.create_customer(uuid, text, text, text, text, text, text[]) to authenticated;
grant execute on function public.update_customer(uuid, text, text, text, text, text, text[]) to authenticated;
grant execute on function public.delete_customer(uuid)                        to authenticated;
grant execute on function public.create_order_with_customer(uuid, uuid, text, jsonb) to authenticated;
grant execute on function public.link_order_to_customer(uuid, uuid)           to authenticated;
grant execute on function public.create_followup(uuid, timestamptz, text, text, uuid) to authenticated;
grant execute on function public.update_followup(uuid, timestamptz, text, text, uuid) to authenticated;
grant execute on function public.set_followup_status(uuid, text)              to authenticated;
grant execute on function public.list_business_members(uuid)                  to authenticated;
grant execute on function public.record_payment(uuid, numeric, text, text, text, timestamptz) to authenticated;
grant execute on function public.void_payment(uuid, text)                     to authenticated;

notify pgrst, 'reload schema';
