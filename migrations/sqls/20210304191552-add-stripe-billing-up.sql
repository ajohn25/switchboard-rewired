create type billing.pricing_version as enum (
  'v1',
  'v2',
  'byot',
  'other',
  'peoples-action'
);

create table billing.stripe_customers (
  id uuid primary key default uuid_generate_v1mc(),
  client_id uuid not null references billing.clients(id),
  stripe_customer_id text,
  email text,
  address_billing_line1 text,
  address_billing_line2 text,
  address_billing_city text,
  address_billing_state text,
  address_billing_zip text,
  pricing_version billing.pricing_version default 'v2'::billing.pricing_version
);

comment on table billing.stripe_customers is E'@omit';

create type billing.usage_type as enum (
  'lrn',
  'phone_number',
  'sms_outbound',
  'sms_inbound',
  'mms_outbound',
  'mms_inbound'
);

create table billing.stripe_customer_subscriptions (
  id uuid primary key default uuid_generate_v1mc(),
  customer_id uuid not null references billing.stripe_customers(id),
  subscription_id text not null,
  service_type sms.profile_service_option not null,
  usage_type billing.usage_type not null
);

comment on table billing.stripe_customer_subscriptions is E'@omit';
