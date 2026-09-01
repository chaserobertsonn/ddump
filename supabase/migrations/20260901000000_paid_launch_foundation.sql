-- DDump paid-launch backend foundation.
-- Test-mode-default schema: no production credentials, no card data, no customer media paths.

create extension if not exists pgcrypto;

create schema if not exists ddump_private;

create type ddump_environment as enum ('test', 'production');
create type ddump_provider as enum ('auth', 'revenuecat', 'stripe');
create type ddump_provider_event_status as enum (
  'received',
  'processed',
  'duplicate',
  'dead_lettered',
  'replayed',
  'ignored'
);
create type ddump_entitlement_status as enum (
  'unknown',
  'pending',
  'trialing',
  'active',
  'past_due',
  'canceled',
  'expired',
  'refunded',
  'disputed',
  'chargeback',
  'revoked',
  'support_hold',
  'indeterminate'
);
create type ddump_installation_status as enum (
  'pending',
  'authorized',
  'deauthorized',
  'replaced',
  'revoked',
  'support_hold'
);
create type ddump_request_status as enum (
  'open',
  'approved',
  'denied',
  'expired',
  'completed',
  'canceled'
);

create table ddump_accounts (
  id uuid primary key default gen_random_uuid(),
  environment ddump_environment not null default 'test',
  stable_account_key text not null,
  email_hash text,
  auth_subject_hash text,
  beta_updates_eligible boolean not null default false,
  account_revocation_epoch timestamptz not null default 'epoch',
  deletion_requested_at timestamptz,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ddump_accounts_stable_key_not_blank check (length(stable_account_key) between 16 and 160),
  constraint ddump_accounts_email_hash_no_raw_email check (email_hash is null or position('@' in email_hash) = 0),
  unique (environment, stable_account_key)
);

create table ddump_provider_mappings (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references ddump_accounts(id),
  environment ddump_environment not null default 'test',
  provider ddump_provider not null,
  provider_project_id text not null,
  provider_account_id text not null,
  is_active boolean not null default true,
  supersedes_mapping_id uuid references ddump_provider_mappings(id),
  repair_ticket text,
  repair_reason text,
  repair_expires_at timestamptz,
  created_by text not null default 'system',
  created_at timestamptz not null default now(),
  constraint ddump_provider_mapping_repair_requires_audit check (
    supersedes_mapping_id is null
    or (repair_ticket is not null and repair_reason is not null and repair_expires_at is not null)
  ),
  unique (environment, provider, provider_project_id, provider_account_id)
);

create index ddump_provider_mappings_account_provider_idx
  on ddump_provider_mappings(account_id, environment, provider, provider_project_id, created_at desc);

create table ddump_installations (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references ddump_accounts(id),
  environment ddump_environment not null default 'test',
  installation_public_key_sha256 text not null,
  device_fingerprint_hash text,
  device_label text,
  authorization_status ddump_installation_status not null default 'pending',
  authorized_at timestamptz,
  deauthorized_at timestamptz,
  replacement_for_installation_id uuid references ddump_installations(id),
  max_devices_snapshot integer not null default 2,
  revocation_epoch timestamptz not null default 'epoch',
  last_seen_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ddump_installation_public_key_hash_shape check (installation_public_key_sha256 ~ '^[a-f0-9]{64}$'),
  constraint ddump_installation_device_hash_no_raw_path check (
    device_fingerprint_hash is null or position('/' in device_fingerprint_hash) = 0
  )
);

create unique index ddump_installations_one_key_per_environment
  on ddump_installations(environment, installation_public_key_sha256);

create table ddump_entitlement_products (
  id text primary key,
  environment ddump_environment not null default 'test',
  revenuecat_entitlement_id text not null,
  stripe_product_id text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- Non-billable test identifiers only. Production products, prices, tax,
-- trials, and legal terms require explicit owner approval and dashboard setup.
insert into ddump_entitlement_products (id, environment, revenuecat_entitlement_id)
values
  ('ddump_test_monthly', 'test', 'ddump_pro_test'),
  ('ddump_test_annual', 'test', 'ddump_pro_test')
on conflict (id) do nothing;

create table ddump_provider_event_inbox (
  id uuid primary key default gen_random_uuid(),
  provider ddump_provider not null,
  environment ddump_environment not null default 'test',
  provider_project_id text not null,
  provider_event_id text not null,
  livemode boolean not null default false,
  body_sha256 text not null,
  received_at timestamptz not null default now(),
  effective_at timestamptz,
  account_id uuid references ddump_accounts(id),
  provider_account_id text,
  event_type text not null,
  raw_event jsonb not null,
  redacted_headers jsonb not null default '{}'::jsonb,
  status ddump_provider_event_status not null default 'received',
  attempts integer not null default 0,
  processed_at timestamptz,
  dead_letter_reason text,
  replay_of_event_id uuid references ddump_provider_event_inbox(id),
  constraint ddump_provider_event_body_hash_shape check (body_sha256 ~ '^[a-f0-9]{64}$'),
  unique(provider, environment, provider_project_id, provider_event_id)
);

create index ddump_provider_event_inbox_account_effective_idx
  on ddump_provider_event_inbox(account_id, provider, environment, effective_at);

create table ddump_canonical_entitlement_state (
  account_id uuid not null references ddump_accounts(id),
  environment ddump_environment not null default 'test',
  product_id text not null references ddump_entitlement_products(id),
  status ddump_entitlement_status not null default 'unknown',
  source_provider ddump_provider not null default 'revenuecat',
  source_event_id uuid references ddump_provider_event_inbox(id),
  revenuecat_app_user_id text,
  stripe_customer_id text,
  starts_at timestamptz,
  paid_through_at timestamptz,
  expires_at timestamptz,
  grace_expires_at timestamptz,
  recomputed_at timestamptz not null default now(),
  state_version bigint not null default 1,
  details jsonb not null default '{}'::jsonb,
  primary key(account_id, environment, product_id)
);

create table ddump_entitlement_audit_history (
  id uuid primary key default gen_random_uuid(),
  account_id uuid references ddump_accounts(id),
  installation_id uuid references ddump_installations(id),
  environment ddump_environment not null default 'test',
  actor text not null default 'system',
  action text not null,
  before_state jsonb,
  after_state jsonb,
  provider_event_id uuid references ddump_provider_event_inbox(id),
  ticket text,
  reason text,
  created_at timestamptz not null default now()
);

create table ddump_entitlement_document_issuance (
  id uuid primary key default gen_random_uuid(),
  token_id text not null,
  account_id uuid not null references ddump_accounts(id),
  installation_id uuid not null references ddump_installations(id),
  environment ddump_environment not null default 'test',
  product_id text not null references ddump_entitlement_products(id),
  status ddump_entitlement_status not null,
  key_id text not null,
  document_sha256 text not null,
  issued_at timestamptz not null default now(),
  refresh_at timestamptz not null,
  grace_expires_at timestamptz not null,
  hard_expires_at timestamptz not null,
  replay_cache_expires_at timestamptz not null,
  constraint ddump_entitlement_document_hash_shape check (document_sha256 ~ '^[a-f0-9]{64}$'),
  unique(environment, token_id)
);

create table ddump_checkout_handoffs (
  id uuid primary key default gen_random_uuid(),
  environment ddump_environment not null default 'test',
  account_id uuid not null references ddump_accounts(id),
  installation_id uuid not null references ddump_installations(id),
  offering_id text not null,
  variant_id text,
  state_nonce_sha256 text not null,
  pkce_challenge text not null,
  return_origin text not null,
  expires_at timestamptz not null,
  consumed_at timestamptz,
  consumed_by_installation_id uuid references ddump_installations(id),
  created_at timestamptz not null default now(),
  constraint ddump_checkout_handoff_state_hash_shape check (state_nonce_sha256 ~ '^[a-f0-9]{64}$'),
  unique(environment, state_nonce_sha256)
);

create table ddump_billing_lab_overrides (
  account_id uuid not null references ddump_accounts(id),
  environment ddump_environment not null default 'test',
  offering_id text not null,
  variant_id text not null,
  requested_by text not null default 'authenticated_test_customer',
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key(account_id, environment),
  constraint ddump_billing_lab_test_only check (environment = 'test')
);

create table ddump_billing_lab_scenarios (
  account_id uuid not null references ddump_accounts(id),
  environment ddump_environment not null default 'test',
  scenario text not null,
  product_id text not null references ddump_entitlement_products(id),
  requested_by text not null default 'authenticated_test_customer',
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key(account_id, environment),
  constraint ddump_billing_lab_scenario_test_only check (environment = 'test'),
  constraint ddump_billing_lab_scenario_allowed check (scenario in (
    'successful_purchase', 'canceled_checkout', 'abandoned_checkout',
    'restore', 'expiry', 'refund', 'failed_renewal', 'offline_grace',
    'delayed_webhook', 'provider_outage'
  ))
);

create table ddump_identity_repair_requests (
  id uuid primary key default gen_random_uuid(),
  environment ddump_environment not null default 'test',
  account_id uuid not null references ddump_accounts(id),
  requested_by text not null,
  approved_by text,
  provider ddump_provider not null,
  old_mapping_id uuid references ddump_provider_mappings(id),
  new_provider_project_id text not null,
  new_provider_account_id text not null,
  proof_summary text not null,
  ticket text not null,
  reason text not null,
  status ddump_request_status not null default 'open',
  override_expires_at timestamptz not null,
  customer_notified_at timestamptz,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  constraint ddump_identity_repair_dual_approval check (approved_by is null or approved_by <> requested_by)
);

create table ddump_deletion_requests (
  id uuid primary key default gen_random_uuid(),
  environment ddump_environment not null default 'test',
  account_id uuid not null references ddump_accounts(id),
  requested_by text not null,
  verified_at timestamptz,
  status ddump_request_status not null default 'open',
  retain_billing_records_until timestamptz,
  deletion_scope jsonb not null default '{}'::jsonb,
  customer_notified_at timestamptz,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

create table ddump_dead_letter_queue (
  id uuid primary key default gen_random_uuid(),
  provider_event_id uuid not null references ddump_provider_event_inbox(id),
  environment ddump_environment not null default 'test',
  reason text not null,
  payload jsonb not null,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by text,
  resolution text
);

create table ddump_replay_requests (
  id uuid primary key default gen_random_uuid(),
  environment ddump_environment not null default 'test',
  provider_event_id uuid not null references ddump_provider_event_inbox(id),
  requested_by text not null,
  reason text not null,
  status ddump_request_status not null default 'open',
  created_at timestamptz not null default now(),
  started_at timestamptz,
  completed_at timestamptz,
  result jsonb
);

create table ddump_reconciliation_runs (
  id uuid primary key default gen_random_uuid(),
  environment ddump_environment not null default 'test',
  provider ddump_provider not null,
  account_id uuid references ddump_accounts(id),
  provider_account_id text,
  trigger_event_id uuid references ddump_provider_event_inbox(id),
  requested_by text not null default 'system',
  status ddump_request_status not null default 'open',
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  observed_provider_state jsonb,
  computed_state jsonb,
  divergence_summary text
);

create table ddump_rate_limit_buckets (
  id uuid primary key default gen_random_uuid(),
  environment ddump_environment not null default 'test',
  route text not null,
  subject_hash text not null,
  window_start timestamptz not null,
  window_seconds integer not null,
  limit_count integer not null,
  request_count integer not null default 0,
  blocked_until timestamptz,
  updated_at timestamptz not null default now(),
  unique(environment, route, subject_hash, window_start)
);

create or replace function public.ddump_consume_rate_limit(
  p_environment ddump_environment,
  p_route text,
  p_subject_hash text,
  p_limit integer,
  p_window_seconds integer
)
returns table(allowed boolean, remaining integer, reset_at timestamptz)
language plpgsql
security definer
set search_path = public, ddump_private
as $$
declare
  v_window_start timestamptz;
  v_row ddump_rate_limit_buckets%rowtype;
begin
  if p_limit < 1 or p_window_seconds < 1 or p_subject_hash !~ '^[a-f0-9]{64}$' then
    raise exception 'invalid_rate_limit_input';
  end if;
  v_window_start := to_timestamp(
    floor(extract(epoch from clock_timestamp()) / p_window_seconds) * p_window_seconds
  );
  insert into ddump_rate_limit_buckets (
    environment, route, subject_hash, window_start, window_seconds,
    limit_count, request_count, blocked_until
  ) values (
    p_environment, p_route, p_subject_hash, v_window_start, p_window_seconds,
    p_limit, 1, null
  )
  on conflict (environment, route, subject_hash, window_start)
  do update set
    request_count = ddump_rate_limit_buckets.request_count + 1,
    limit_count = excluded.limit_count,
    updated_at = now(),
    blocked_until = case
      when ddump_rate_limit_buckets.request_count + 1 > excluded.limit_count
        then excluded.window_start + make_interval(secs => excluded.window_seconds)
      else null
    end
  returning * into v_row;

  return query select
    v_row.request_count <= v_row.limit_count,
    greatest(0, v_row.limit_count - v_row.request_count),
    v_row.window_start + make_interval(secs => v_row.window_seconds);
end;
$$;

revoke all on function public.ddump_consume_rate_limit(
  ddump_environment, text, text, integer, integer
) from public, anon, authenticated;
grant execute on function public.ddump_consume_rate_limit(
  ddump_environment, text, text, integer, integer
) to service_role;

create or replace function ddump_private.prevent_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception 'immutable table %.% cannot be updated or deleted; insert a replacement/audit row', tg_table_schema, tg_table_name;
end;
$$;

create trigger ddump_provider_mappings_immutable_update
before update or delete on ddump_provider_mappings
for each row execute function ddump_private.prevent_mutation();

create trigger ddump_provider_event_inbox_immutable_delete
before delete on ddump_provider_event_inbox
for each row execute function ddump_private.prevent_mutation();

create trigger ddump_entitlement_audit_history_immutable_update
before update or delete on ddump_entitlement_audit_history
for each row execute function ddump_private.prevent_mutation();

create or replace function ddump_private.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger ddump_accounts_touch_updated_at
before update on ddump_accounts
for each row execute function ddump_private.touch_updated_at();

create trigger ddump_installations_touch_updated_at
before update on ddump_installations
for each row execute function ddump_private.touch_updated_at();

alter table ddump_accounts enable row level security;
alter table ddump_provider_mappings enable row level security;
alter table ddump_installations enable row level security;
alter table ddump_entitlement_products enable row level security;
alter table ddump_provider_event_inbox enable row level security;
alter table ddump_canonical_entitlement_state enable row level security;
alter table ddump_entitlement_audit_history enable row level security;
alter table ddump_entitlement_document_issuance enable row level security;
alter table ddump_checkout_handoffs enable row level security;
alter table ddump_billing_lab_overrides enable row level security;
alter table ddump_billing_lab_scenarios enable row level security;
alter table ddump_identity_repair_requests enable row level security;
alter table ddump_deletion_requests enable row level security;
alter table ddump_dead_letter_queue enable row level security;
alter table ddump_replay_requests enable row level security;
alter table ddump_reconciliation_runs enable row level security;
alter table ddump_rate_limit_buckets enable row level security;

create policy service_role_all_ddump_accounts on ddump_accounts
  for all using (auth.role() = 'service_role') with check (auth.role() = 'service_role');
create policy service_role_all_ddump_provider_mappings on ddump_provider_mappings
  for all using (auth.role() = 'service_role') with check (auth.role() = 'service_role');
create policy service_role_all_ddump_installations on ddump_installations
  for all using (auth.role() = 'service_role') with check (auth.role() = 'service_role');
create policy service_role_all_ddump_entitlement_products on ddump_entitlement_products
  for all using (auth.role() = 'service_role') with check (auth.role() = 'service_role');
create policy service_role_all_ddump_provider_event_inbox on ddump_provider_event_inbox
  for all using (auth.role() = 'service_role') with check (auth.role() = 'service_role');
create policy service_role_all_ddump_canonical_entitlement_state on ddump_canonical_entitlement_state
  for all using (auth.role() = 'service_role') with check (auth.role() = 'service_role');
create policy service_role_all_ddump_entitlement_audit_history on ddump_entitlement_audit_history
  for all using (auth.role() = 'service_role') with check (auth.role() = 'service_role');
create policy service_role_all_ddump_entitlement_document_issuance on ddump_entitlement_document_issuance
  for all using (auth.role() = 'service_role') with check (auth.role() = 'service_role');
create policy service_role_all_ddump_checkout_handoffs on ddump_checkout_handoffs
  for all using (auth.role() = 'service_role') with check (auth.role() = 'service_role');
create policy service_role_all_ddump_billing_lab_overrides on ddump_billing_lab_overrides
  for all using (auth.role() = 'service_role') with check (auth.role() = 'service_role');
create policy service_role_all_ddump_billing_lab_scenarios on ddump_billing_lab_scenarios
  for all using (auth.role() = 'service_role') with check (auth.role() = 'service_role');
create policy service_role_all_ddump_identity_repair_requests on ddump_identity_repair_requests
  for all using (auth.role() = 'service_role') with check (auth.role() = 'service_role');
create policy service_role_all_ddump_deletion_requests on ddump_deletion_requests
  for all using (auth.role() = 'service_role') with check (auth.role() = 'service_role');
create policy service_role_all_ddump_dead_letter_queue on ddump_dead_letter_queue
  for all using (auth.role() = 'service_role') with check (auth.role() = 'service_role');
create policy service_role_all_ddump_replay_requests on ddump_replay_requests
  for all using (auth.role() = 'service_role') with check (auth.role() = 'service_role');
create policy service_role_all_ddump_reconciliation_runs on ddump_reconciliation_runs
  for all using (auth.role() = 'service_role') with check (auth.role() = 'service_role');
create policy service_role_all_ddump_rate_limit_buckets on ddump_rate_limit_buckets
  for all using (auth.role() = 'service_role') with check (auth.role() = 'service_role');
