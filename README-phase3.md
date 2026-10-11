# RANIBO Phase 3 (step 1 of 2): customers, follow-ups, payments - DATABASE LAYER

## Honest status

| Part | State |
|---|---|
| `supabase/migrations/20261011000003_phase3_customers_crm.sql` | Written. **Not executed anywhere yet.** |
| `supabase/tests/04_phase3_test.sql` (about 100 checks) | Written. **Not executed anywhere yet.** |
| Screens and server actions (customers, follow-ups, payments in Next.js) | **Not written yet.** Step 2. |

Nothing here has been tested, and no Android test steps exist yet because there are no screens to test.
Run the SQL tests on a scratch database before you touch your real Supabase project.

## What the migration adds

Run it once, **after** the Phase 1 and Phase 2 migrations.

- `customers`: name, phone, email, address, notes, tags, creation date. One customer per phone number per business.
- `orders.customer_id`: optional link from an order to a customer. Existing Phase 2 orders stay unlinked until a manager links them. Nothing is guessed or auto-matched.
- `customer_followups`: due date and time, purpose, notes, status (open, done, cancelled), assigned member.
- `order_payments`: amount, method, reference, date. Payments are never deleted, only **voided with a reason**.
- Views `order_payment_summary` and `customer_summary`: all totals, balances and segments are calculated from real orders and payments at read time. No figure is stored twice.
- Functions (the only way to write): `create_customer`, `update_customer`, `delete_customer`, `create_order_with_customer`, `link_order_to_customer`, `create_followup`, `update_followup`, `set_followup_status`, `list_business_members`, `record_payment`, `void_payment`.

## Rules the database enforces

- **Tenant isolation:** every table has `business_id` and Row Level Security. Composite foreign keys make it impossible to link a customer, order, follow-up or payment across businesses. Clients get read-only table access; all writes go through the functions, which check membership.
- **Who can do what:** any member can add and edit customers, create orders, and record payments. Only owner, admin and manager can delete customers, void payments, and link old orders. Members can change a follow-up they created or that is assigned to them; managers can change any.
- **Valid order** (counted in totals): status confirmed, shipped or delivered. Pending, cancelled and returned orders are not counted. Cancelled orders stay in the customer's order history.
- **Total purchases** = sum of valid order totals. **Outstanding** = total purchases - non-voided payments on valid orders.
- **Segments:** `inactive` if the last valid order (or, with none, the creation date) is older than 60 days; otherwise `returning` with 2 or more valid orders; otherwise `new`. To change 60 days or the order count, edit the `customer_summary` view.
- **Payments:** cannot exceed the order total, cannot be recorded on cancelled or returned orders, cannot be dated in the future. The order row is locked so two simultaneous payments cannot overpay.
- **Deleting a customer** unlinks their orders (orders keep the name, phone and address copied at creation), keeps payments, and deletes their follow-ups.

## Known limitations

- **Refunds are not modeled.** If an order with payments is cancelled or returned, the payments stay on it and are excluded from customer balances. The screens must show this clearly. Real refund tracking is a separate feature.
- Segment thresholds are fixed in the view, not editable per business.
- In-app reminders will be an overdue and upcoming list shown when the app is open. No background or push notifications will exist, and none will be claimed.
- `list_business_members` shows every member's email to other members of the same business.

## How to run the SQL tests (needs PostgreSQL 15 or newer)

Use a scratch database, **never your real Supabase project**.

```bash
# 1. Prepare the scratch database with your Phase 1 migration and the Supabase stub
psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/00_supabase_stub.sql
psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -f supabase/migrations/<your_phase1_file>.sql
psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -f supabase/migrations/20261011000002_phase2_products_orders.sql
psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -f supabase/migrations/20261011000003_phase3_customers_crm.sql

# 2. Run the Phase 3 tests
psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/04_phase3_test.sql
```

Success means the last line prints `ALL PHASE 3 CHECKS PASSED`. Any failure stops with a `FAIL:` message.
If the test setup fails early, the cause is likely a difference between the Phase 1 schema and the assumptions in the tests (they use `create_business()`, `memberships`, `is_business_member()` and `has_business_role()`, as Phase 2 does). Send me the exact error.

## Applying to your real Supabase project (only after the tests pass on the scratch database)

1. Supabase, then **SQL Editor**, then **New query**.
2. Paste the whole Phase 3 migration file and press **Run**. Run it once only.
3. If the app later reports "Could not find the function", run `notify pgrst, 'reload schema';` and wait a few seconds.
