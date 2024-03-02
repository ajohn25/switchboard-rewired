-- Store Campaign MNO Metadata
-- --------------------------------------------

create table sms.tendlc_campaign_mno_metadata (
  id uuid primary key default uuid_generate_v1mc(),
  campaign_id uuid not null references sms.tendlc_campaigns (id),
  mno_id text,
  mno text,
  qualify boolean,
  tpm integer,
  brand_tier text,
  msg_class text,
  mno_review boolean,
  mno_support boolean,
  min_msg_samples integer,
  req_subscriber_help boolean,
  req_subscriber_optin boolean,
  req_subscriber_optout boolean,
  no_embedded_phone boolean,
  no_embedded_link boolean,
  extra json,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint campaign_mno_metadata_unique_campaign_mno unique (campaign_id, mno_id)
);

comment on table sms.tendlc_campaign_mno_metadata is E'@omit';

alter table sms.tendlc_campaign_mno_metadata enable row level security;

create trigger _500_updated_at
  before update
  on sms.tendlc_campaign_mno_metadata
  for each row
  execute function public.universal_updated_at();
