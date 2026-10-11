-- Phase 3 tests: customers, order history, payments, follow-ups, permissions, cross-business isolation.
-- Run after: 00_supabase_stub.sql and the Phase 1, 2 and 3 migrations (it can run after 02_phase2_test.sql
-- in the same scratch database; it uses its own users and businesses).
-- Run with psql, e.g.:  psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/04_phase3_test.sql
-- Any failure raises an exception and stops. NEVER run this against your real/production database.
--
-- STATUS: written but not yet executed by its author (no PostgreSQL was available when it was written).

create schema if not exists t;
grant usage on schema t to public;

create or replace function t.ok(cond boolean, msg text) returns void language plpgsql as $$
begin
  if cond is not true then raise exception 'FAIL: %', msg; end if;
  raise notice 'PASS: %', msg;
end $$;

create or replace function t.expect_err(p_sql text, p_state text, p_label text) returns void
language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlstate = p_state then
      raise notice 'PASS: %', p_label;
      return;
    end if;
    raise exception 'FAIL: % (expected %, got % - %)', p_label, p_state, sqlstate, sqlerrm;
  end;
  raise exception 'FAIL: % (no error was raised)', p_label;
end $$;

create or replace function t.login(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid)::text, false);
  execute 'set role authenticated';
end $$;

grant execute on function t.ok(boolean, text) to public;
grant execute on function t.expect_err(text, text, text) to public;
grant execute on function t.login(uuid) to public;

-- ---------------------------------------------------------------- setup (superuser)
insert into auth.users (id, email, raw_user_meta_data) values
  ('cccccccc-0000-0000-0000-0000000000c1', 'carol.owner@example.com', '{"full_name":"Carol Owner"}'),
  ('cccccccc-0000-0000-0000-0000000000c2', 'mark.manager@example.com', '{"full_name":"Mark Manager"}'),
  ('cccccccc-0000-0000-0000-0000000000c3', 'sara.staff@example.com',   '{"full_name":"Sara Staff"}'),
  ('cccccccc-0000-0000-0000-0000000000c4', 'sid.staff@example.com',    '{"full_name":"Sid Staff"}'),
  ('dddddddd-0000-0000-0000-0000000000d1', 'dave.owner@example.com',   '{"full_name":"Dave Owner"}');

select t.login('cccccccc-0000-0000-0000-0000000000c1');
select public.create_business('Carol Trading') as biz_a \gset
reset role;
select t.login('dddddddd-0000-0000-0000-0000000000d1');
select public.create_business('Dave Trading') as biz_b \gset
reset role;

insert into public.memberships (business_id, user_id, role) values
  (:'biz_a', 'cccccccc-0000-0000-0000-0000000000c2', 'manager'),
  (:'biz_a', 'cccccccc-0000-0000-0000-0000000000c3', 'staff'),
  (:'biz_a', 'cccccccc-0000-0000-0000-0000000000c4', 'staff');

-- Products are needed to build orders (created through the Phase 2 function).
select t.login('cccccccc-0000-0000-0000-0000000000c1');
select public.create_product(:'biz_a', 'Phase3 Shirt', 'P3-TEE', null, 100, 250, 50, 3) as pa \gset
reset role;
select t.login('dddddddd-0000-0000-0000-0000000000d1');
select public.create_product(:'biz_b', 'Phase3 Mug', 'P3-MUG', null, 40, 80, 50, 3) as pb \gset
reset role;

-- ---------------------------------------------------------------- customers: create / validate
select t.login('cccccccc-0000-0000-0000-0000000000c1');

select public.create_customer(:'biz_a', '  Rina Akter ', '01712-345678', 'Rina@Example.com', 'Dhaka', 'VIP', array['VIP', ' vip ', 'Dhaka']) as c1 \gset
select t.ok((select name from public.customers where id = :'c1') = 'Rina Akter', 'customer name is trimmed');
select t.ok((select email from public.customers where id = :'c1') = 'rina@example.com', 'email is lower-cased');
select t.ok((select tags from public.customers where id = :'c1') = array['vip', 'dhaka'], 'tags are normalized and de-duplicated');
select t.ok((select created_by from public.customers where id = :'c1') = 'cccccccc-0000-0000-0000-0000000000c1', 'created_by is the logged-in user');

select t.expect_err(format('select public.create_customer(%L, ''Dup'', ''01712 345 678'', null, null, null, null)', :'biz_a'),
                    'RB001', 'duplicate phone (ignoring spaces/dashes) rejected with a friendly error');
select t.expect_err(format('select public.create_customer(%L, '''', null, null, null, null, null)', :'biz_a'),
                    'RB001', 'empty name rejected');
select t.expect_err(format('select public.create_customer(%L, ''Bad Phone'', ''abc'', null, null, null, null)', :'biz_a'),
                    'RB001', 'non-numeric phone rejected');
select t.expect_err(format('select public.create_customer(%L, ''Short'', ''123'', null, null, null, null)', :'biz_a'),
                    'RB001', 'too-short phone rejected');
select t.expect_err(format('select public.create_customer(%L, ''Bad Email'', null, ''not-an-email'', null, null, null)', :'biz_a'),
                    'RB001', 'invalid email rejected');
select t.expect_err(format('select public.create_customer(%L, ''Many Tags'', null, null, null, null, array[''a'',''b'',''c'',''d'',''e'',''f'',''g'',''h'',''i'',''j'',''k''])', :'biz_a'),
                    'RB001', 'more than 10 tags rejected');
select t.expect_err(format('select public.create_customer(%L, ''Long Tag'', null, null, null, null, array[repeat(''x'', 31)])', :'biz_a'),
                    'RB001', 'tag longer than 30 characters rejected');
select t.expect_err(format('select public.create_customer(%L, %L, null, null, null, null, null)', :'biz_a', repeat('n', 151)),
                    'RB001', 'name longer than 150 characters rejected');

-- clients cannot bypass the functions
select t.expect_err(format('insert into public.customers (business_id, name) values (%L, ''Direct'')', :'biz_a'),
                    '42501', 'clients cannot insert customers directly');
select t.expect_err(format('update public.customers set name = ''Hacked'' where id = %L', :'c1'),
                    '42501', 'clients cannot update customers directly');
select t.expect_err(format('delete from public.customers where id = %L', :'c1'),
                    '42501', 'clients cannot delete customers directly');
reset role;

-- staff can create and edit customers
select t.login('cccccccc-0000-0000-0000-0000000000c3');
select public.create_customer(:'biz_a', 'Karim Uddin', '01811111111', null, null, null, null) as c2 \gset
select public.update_customer(:'c2', 'Karim Uddin Updated', '01811111111', 'karim@example.com', 'Chattogram', 'note', array['wholesale']);
select t.ok((select name from public.customers where id = :'c2') = 'Karim Uddin Updated', 'staff can update a customer');
select t.expect_err(format('select public.update_customer(%L, ''Clash'', ''01712345678'', null, null, null, null)', :'c2'),
                    'RB001', 'update cannot reuse another customer''s phone');
select t.expect_err(format('select public.delete_customer(%L)', :'c2'),
                    'RB001', 'staff cannot delete customers');
reset role;

-- ---------------------------------------------------------------- orders, history, totals
select t.login('cccccccc-0000-0000-0000-0000000000c1');
select public.create_order_with_customer(:'biz_a', :'c1', 'first',
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 2))) as o1 \gset      -- 2 x 250 = 500
select public.create_order_with_customer(:'biz_a', :'c1', 'second',
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 1))) as o2 \gset      -- 250
select public.create_order_with_customer(:'biz_a', :'c1', 'third',
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 4))) as o3 \gset      -- 1000

select t.ok((select customer_id from public.orders where id = :'o1') = :'c1', 'order is linked to the customer');
select t.ok((select customer_name from public.orders where id = :'o1') = 'Rina Akter', 'customer name snapshot copied onto the order');
select t.ok((select total_amount from public.orders where id = :'o1') = 500, 'order total computed by the database (500)');

-- pending orders are not valid sales yet
select t.ok((select linked_order_count from public.customer_summary where id = :'c1') = 3, 'summary counts 3 linked orders');
select t.ok((select valid_order_count from public.customer_summary where id = :'c1') = 0, 'pending orders are not counted as valid orders');
select t.ok((select total_purchases from public.customer_summary where id = :'c1') = 0, 'total purchases is 0 while all orders are pending');
select t.ok((select segment from public.customer_summary where id = :'c1') = 'new', 'brand-new customer is segment new');

select public.set_order_status(:'o1', 'confirmed');
select public.set_order_status(:'o2', 'confirmed');
select t.ok((select valid_order_count from public.customer_summary where id = :'c1') = 2, 'two confirmed orders are valid');
select t.ok((select total_purchases from public.customer_summary where id = :'c1') = 750, 'total purchases = 500 + 250');
select t.ok((select outstanding_balance from public.customer_summary where id = :'c1') = 750, 'nothing paid yet: outstanding = 750');
select t.ok((select segment from public.customer_summary where id = :'c1') = 'returning', 'two valid orders and recent: segment returning');

-- cancel / return remove an order from totals
select public.set_order_status(:'o2', 'cancelled');
select t.ok((select total_purchases from public.customer_summary where id = :'c1') = 500, 'cancelled order is removed from total purchases');
select t.ok((select segment from public.customer_summary where id = :'c1') = 'new', 'one valid order again: segment new');
select t.ok((select linked_order_count from public.customer_summary where id = :'c1') = 3, 'cancelled order stays in order history');
reset role;

-- ---------------------------------------------------------------- payments
select t.login('cccccccc-0000-0000-0000-0000000000c3');   -- staff may record payments
select public.record_payment(:'o1', 200, 'cash', null, 'advance', null) as pay1 \gset
select t.ok((select paid_amount from public.order_payment_summary where order_id = :'o1') = 200, 'payment recorded: paid 200');
select t.ok((select outstanding_balance from public.customer_summary where id = :'c1') = 300, 'outstanding = 500 - 200 = 300');

select t.expect_err(format('select public.record_payment(%L, 301, ''cash'', null, null, null)', :'o1'),
                    'RB001', 'overpayment rejected');
select t.expect_err(format('select public.record_payment(%L, 0, ''cash'', null, null, null)', :'o1'),
                    'RB001', 'zero amount rejected');
select t.expect_err(format('select public.record_payment(%L, -5, ''cash'', null, null, null)', :'o1'),
                    'RB001', 'negative amount rejected');
select t.expect_err(format('select public.record_payment(%L, 10.555, ''cash'', null, null, null)', :'o1'),
                    'RB001', 'more than 2 decimal places rejected');
select t.expect_err(format('select public.record_payment(%L, 10, ''bitcoin'', null, null, null)', :'o1'),
                    'RB001', 'unknown payment method rejected');
select t.expect_err(format('select public.record_payment(%L, 10, ''cash'', null, null, now() + interval ''2 days'')', :'o1'),
                    'RB001', 'future payment date rejected');
select t.expect_err(format('select public.record_payment(%L, 10, ''cash'', null, null, null)', :'o2'),
                    'RB001', 'payment on a cancelled order rejected');
select t.expect_err(format('select public.void_payment(%L, ''mistake'')', :'pay1'),
                    'RB001', 'staff cannot void payments');
select t.expect_err(format('insert into public.order_payments (business_id, order_id, amount, method, created_by) values (%L, %L, 1, ''cash'', %L)',
                           :'biz_a', :'o1', 'cccccccc-0000-0000-0000-0000000000c3'),
                    '42501', 'clients cannot insert payments directly');
reset role;

select t.login('cccccccc-0000-0000-0000-0000000000c2');   -- manager
select public.record_payment(:'o1', 300, 'bkash', 'TX123', null, null) as pay2 \gset
select t.ok((select outstanding_balance from public.customer_summary where id = :'c1') = 0, 'fully paid: outstanding = 0');
select t.expect_err(format('select public.record_payment(%L, 1, ''cash'', null, null, null)', :'o1'),
                    'RB001', 'cannot pay more once the order is fully paid');
select t.expect_err(format('select public.void_payment(%L, '''')', :'pay2'),
                    'RB001', 'void requires a reason');
select public.void_payment(:'pay2', 'Entered by mistake');
select t.ok((select outstanding_balance from public.customer_summary where id = :'c1') = 300, 'voided payment no longer counts: outstanding back to 300');
select t.ok((select count(*) from public.order_payments where order_id = :'o1') = 2, 'voided payment stays in the history');
select t.expect_err(format('select public.void_payment(%L, ''again'')', :'pay2'),
                    'RB001', 'a payment cannot be voided twice');
reset role;

-- ---------------------------------------------------------------- segments (age-based)
-- Make c1's remaining valid order old, and the customer old: should become inactive.
update public.orders set created_at = now() - interval '90 days' where id = :'o1';
update public.customers set created_at = now() - interval '200 days' where id = :'c1';
select t.login('cccccccc-0000-0000-0000-0000000000c1');
select t.ok((select segment from public.customer_summary where id = :'c1') = 'inactive', 'last valid order 90 days ago: segment inactive');
-- A customer with no orders created long ago is inactive too; a fresh one is new.
reset role;
update public.customers set created_at = now() - interval '61 days' where id = :'c2';
select t.login('cccccccc-0000-0000-0000-0000000000c1');
select t.ok((select segment from public.customer_summary where id = :'c2') = 'inactive', 'no orders and created 61 days ago: inactive');
reset role;
update public.customers set created_at = now() - interval '10 days' where id = :'c2';
select t.login('cccccccc-0000-0000-0000-0000000000c1');
select t.ok((select segment from public.customer_summary where id = :'c2') = 'new', 'no orders and created 10 days ago: new');
reset role;

-- ---------------------------------------------------------------- follow-ups
select t.login('cccccccc-0000-0000-0000-0000000000c3');
select public.create_followup(:'c1', now() - interval '2 hours', 'Call about reorder', 'asked for discount',
                              'cccccccc-0000-0000-0000-0000000000c3') as f1 \gset
select public.create_followup(:'c1', now() + interval '2 days', 'Send catalogue', null,
                              'cccccccc-0000-0000-0000-0000000000c2') as f2 \gset
select public.create_followup(:'c1', now() + interval '30 days', 'Birthday wish', null, null) as f3 \gset

select t.ok((select count(*) from public.customer_followups where status = 'open' and due_at < now()) = 1, 'exactly one follow-up is overdue');
select t.ok((select count(*) from public.customer_followups
             where status = 'open' and due_at >= now() and due_at < now() + interval '7 days') = 1, 'exactly one follow-up is due in the next 7 days');

select t.expect_err(format('select public.create_followup(%L, now() - interval ''5 days'', ''Too old'', null, null)', :'c1'),
                    'RB001', 'follow-up more than a day in the past rejected');
select t.expect_err(format('select public.create_followup(%L, now() + interval ''10 years'', ''Too far'', null, null)', :'c1'),
                    'RB001', 'follow-up more than 5 years ahead rejected');
select t.expect_err(format('select public.create_followup(%L, null, ''No date'', null, null)', :'c1'),
                    'RB001', 'missing date rejected');
select t.expect_err(format('select public.create_followup(%L, now() + interval ''1 day'', '''', null, null)', :'c1'),
                    'RB001', 'empty purpose rejected');
select t.expect_err(format('select public.create_followup(%L, now() + interval ''1 day'', ''x'', null, %L)', :'c1', 'dddddddd-0000-0000-0000-0000000000d1'),
                    'RB001', 'cannot assign a follow-up to someone outside the business');
select t.expect_err(format('insert into public.customer_followups (business_id, customer_id, due_at, purpose, created_by) values (%L, %L, now(), ''x'', %L)',
                           :'biz_a', :'c1', 'cccccccc-0000-0000-0000-0000000000c3'),
                    '42501', 'clients cannot insert follow-ups directly');

-- overdue follow-up can still be edited while keeping its original date
select public.update_followup(:'f1', (select due_at from public.customer_followups where id = :'f1'), 'Call about reorder (updated)', 'n', 'cccccccc-0000-0000-0000-0000000000c3');
select t.ok((select purpose from public.customer_followups where id = :'f1') = 'Call about reorder (updated)', 'overdue follow-up can be edited');

-- Sara can complete her own assigned follow-up
select public.set_followup_status(:'f1', 'done');
select t.ok((select completed_at is not null from public.customer_followups where id = :'f1'), 'done sets completed_at');
select t.ok((select count(*) from public.customer_followups where status = 'open' and due_at < now()) = 0, 'no overdue follow-ups after completing it');
select public.set_followup_status(:'f1', 'open');
select t.ok((select completed_at is null from public.customer_followups where id = :'f1'), 'reopening clears completed_at');
select t.expect_err(format('select public.set_followup_status(%L, ''banana'')', :'f1'),
                    'RB001', 'invalid status rejected');
reset role;

-- Sid (staff, neither creator nor assignee) cannot touch Sara's follow-up; the manager can
select t.login('cccccccc-0000-0000-0000-0000000000c4');
select t.expect_err(format('select public.set_followup_status(%L, ''done'')', :'f1'),
                    'RB001', 'unrelated staff cannot change someone else''s follow-up');
select t.expect_err(format('select public.update_followup(%L, now() + interval ''1 day'', ''x'', null, null)', :'f1'),
                    'RB001', 'unrelated staff cannot edit someone else''s follow-up');
reset role;
select t.login('cccccccc-0000-0000-0000-0000000000c2');
select public.set_followup_status(:'f1', 'cancelled');
select t.ok((select status from public.customer_followups where id = :'f1') = 'cancelled', 'manager can change any follow-up');
select t.expect_err(format('select public.update_followup(%L, now() + interval ''1 day'', ''x'', null, null)', :'f1'),
                    'RB001', 'cancelled follow-up cannot be edited');
select t.ok((select count(*) from public.list_business_members(:'biz_a')) = 4, 'member list returns the 4 members of the business');
reset role;

-- ---------------------------------------------------------------- cross-business isolation (Dave vs Carol)
select t.login('dddddddd-0000-0000-0000-0000000000d1');
select public.create_customer(:'biz_b', 'Dave Customer', '01922222222', null, null, null, null) as cb \gset
-- the same phone number as one of Carol's customers is fine in a different business
select public.create_customer(:'biz_b', 'Same Phone Other Business', '01712345678', null, null, null, null) as cb2 \gset
select t.ok(true, 'the same phone number can exist in two different businesses');

select t.ok((select count(*) from public.customers) = 2, 'Dave sees only his own 2 customers');
select t.ok((select count(*) from public.customers where business_id = :'biz_a') = 0, 'Dave cannot read Carol''s customers');
select t.ok((select count(*) from public.customer_summary where business_id = :'biz_a') = 0, 'Dave cannot read Carol''s customer summary');
select t.ok((select count(*) from public.customer_followups) = 0, 'Dave cannot read Carol''s follow-ups');
select t.ok((select count(*) from public.order_payments) = 0, 'Dave cannot read Carol''s payments');
select t.ok((select count(*) from public.order_payment_summary where business_id = :'biz_a') = 0, 'Dave cannot read Carol''s payment summaries');

select t.expect_err(format('select public.update_customer(%L, ''Hijack'', null, null, null, null, null)', :'c1'),
                    'RB001', 'Dave cannot update Carol''s customer');
select t.expect_err(format('select public.delete_customer(%L)', :'c1'),
                    'RB001', 'Dave cannot delete Carol''s customer');
select t.expect_err(format('select public.create_customer(%L, ''Intruder'', null, null, null, null, null)', :'biz_a'),
                    'RB001', 'Dave cannot create customers in Carol''s business');
select t.expect_err(format('select public.create_order_with_customer(%L, %L, null, jsonb_build_array(jsonb_build_object(''product_id'', %L, ''quantity'', 1)))', :'biz_b', :'c1', :'pb'),
                    'RB001', 'Dave cannot create an order for Carol''s customer');
select t.expect_err(format('select public.create_order_with_customer(%L, %L, null, jsonb_build_array(jsonb_build_object(''product_id'', %L, ''quantity'', 1)))', :'biz_a', :'c1', :'pa'),
                    'RB001', 'Dave cannot create orders in Carol''s business');
select t.expect_err(format('select public.record_payment(%L, 1, ''cash'', null, null, null)', :'o1'),
                    'RB001', 'Dave cannot record a payment on Carol''s order');
select t.expect_err(format('select public.void_payment(%L, ''x'')', :'pay1'),
                    'RB001', 'Dave cannot void Carol''s payment');
select t.expect_err(format('select public.create_followup(%L, now() + interval ''1 day'', ''x'', null, null)', :'c1'),
                    'RB001', 'Dave cannot add a follow-up to Carol''s customer');
select t.expect_err(format('select public.set_followup_status(%L, ''done'')', :'f2'),
                    'RB001', 'Dave cannot change Carol''s follow-up');
select t.expect_err(format('select public.update_followup(%L, now() + interval ''1 day'', ''x'', null, null)', :'f2'),
                    'RB001', 'Dave cannot edit Carol''s follow-up');
select t.expect_err(format('select * from public.list_business_members(%L)', :'biz_a'),
                    'RB001', 'Dave cannot list Carol''s team members');

-- Dave's own order must not be linkable to Carol's customer (composite foreign key)
select public.create_order(:'biz_b', 'Walk-in', null, null, null, null,
  jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 1))) as ob \gset
reset role;
select t.expect_err(format('update public.orders set customer_id = %L where id = %L', :'c1', :'ob'),
                    '23503', 'database refuses to link a business-B order to a business-A customer');
select t.login('dddddddd-0000-0000-0000-0000000000d1');
select t.expect_err(format('select public.link_order_to_customer(%L, %L)', :'ob', :'c1'),
                    'RB001', 'link_order_to_customer refuses a customer from another business');
select public.link_order_to_customer(:'ob', :'cb');
select t.ok((select customer_id from public.orders where id = :'ob') = :'cb', 'manager/owner can link an existing order to a customer in the same business');
reset role;

-- an anonymous (not logged in) caller gets nothing
set role anon;
select t.expect_err('select * from public.customers', '42501', 'anonymous role cannot read customers');
select t.expect_err(format('select public.create_customer(%L, ''Anon'', null, null, null, null, null)', :'biz_a'),
                    '42501', 'anonymous role cannot call create_customer');
reset role;

-- ---------------------------------------------------------------- delete keeps order history
select t.login('cccccccc-0000-0000-0000-0000000000c2');
select public.delete_customer(:'c1');
select t.ok((select count(*) from public.customers where id = :'c1') = 0, 'manager can delete a customer');
select t.ok((select count(*) from public.orders where id = :'o1') = 1, 'the customer''s orders still exist after deletion');
select t.ok((select customer_id is null from public.orders where id = :'o1'), 'orders are unlinked from the deleted customer');
select t.ok((select customer_name from public.orders where id = :'o1') = 'Rina Akter', 'order keeps the customer name snapshot');
select t.ok((select count(*) from public.order_payments where order_id = :'o1') = 2, 'payments remain on the order after the customer is deleted');
select t.ok((select count(*) from public.customer_followups where customer_id = :'c1') = 0, 'follow-ups are deleted together with the customer');
reset role;

select 'ALL PHASE 3 CHECKS PASSED' as result;
