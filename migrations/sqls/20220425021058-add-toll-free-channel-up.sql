-- Add toll-free table
-- ----------------------------

create table sms.toll_free_use_cases (
  id uuid primary key default  uuid_generate_v1mc(),
  client_id uuid not null references billing.clients (id),
  sending_account_id uuid not null references sms.sending_accounts (id),
  area_code text,
  phone_number_request_id uuid references sms.phone_number_requests (id),
  phone_number_id uuid references sms.all_phone_numbers (id),
  stakeholders text not null,
  submitted_at timestamptz,
  approved_at timestamptz,
  throughput_interval interval,
  throughput_limit interval,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint valid_toll_free_area_code check ( area_code is null or area_code ~* '^8[0-9]{2}$')
);

comment on table sms.toll_free_use_cases is E'@omit';
comment on column sms.toll_free_use_cases.id is E'@omit create,update,delete';
comment on column sms.toll_free_use_cases.client_id is E'@omit update,delete';
comment on column sms.toll_free_use_cases.sending_account_id is E'@omit update,delete';
comment on column sms.toll_free_use_cases.area_code is E'@omit update,delete\nOptional preference for specific toll-free area code.';
comment on column sms.toll_free_use_cases.stakeholders is E'Comma-separated list of stakeholders involved in toll-free use case approval. Ideally names and email addresses, but left as freeform text for flexibility in this new domain.';
comment on column sms.toll_free_use_cases.submitted_at is E'When the use case was submitted to the aggregator for approval.';
comment on column sms.toll_free_use_cases.approved_at is E'When the use case application was approved by the aggregator.';
comment on column sms.toll_free_use_cases.created_at is E'@omit create,update,delete';
comment on column sms.toll_free_use_cases.updated_at is E'@omit create,update,delete';

alter table sms.toll_free_use_cases enable row level security;

create trigger _500_updated_at
  before update
  on sms.toll_free_use_cases
  for each row
  execute function public.universal_updated_at();


-- Add reference from profiles
-- ------------------------------------

alter table sms.profiles
  add column toll_free_use_case_id uuid references sms.toll_free_use_cases (id),
  add constraint valid_toll_free_channel check ( channel <> 'toll-free' or toll_free_use_case_id is not null );


-- Sync toll-free provisioned status
-- ------------------------------------

create or replace function sms.tg__sync_toll_free_profile_provisioned() returns trigger as $$
begin
  update sms.profiles
  set provisioned = NEW.phone_number_id is not null
  from sms.toll_free_use_cases
  where true
    and toll_free_use_case_id = NEW.id
    and channel = 'toll-free';

  return NEW;
end;
$$ language plpgsql;

create trigger _700_sync_profile_provisioned
  after insert
  on sms.toll_free_use_cases
  for each row
  execute function sms.tg__sync_toll_free_profile_provisioned();

create trigger _700_sync_profile_provisioned_after_update
  after update
  on sms.toll_free_use_cases
  for each row
  when (OLD.phone_number_id is distinct from NEW.phone_number_id)
  execute function sms.tg__sync_toll_free_profile_provisioned();


-- Update outbound message trigger
-- ------------------------------------

create or replace function sms.tg__trigger_process_message() returns trigger as $$
declare
  v_channel sms.traffic_channel;
  v_job json;
begin
  select coalesce(channel, 'grey-route'::sms.traffic_channel)
  from sms.profiles
  where id = NEW.profile_id
  into v_channel;

  select row_to_json(NEW) into v_job;

  if v_channel = 'grey-route'::sms.traffic_channel then
    perform assemble_worker.add_job('process-grey-route-message', v_job, null, 5);
  elsif v_channel = 'toll-free'::sms.traffic_channel then
    perform assemble_worker.add_job('process-toll-free-message', v_job, null, 5);
  else
    raise 'Unsupported traffic channel %', v_channel;
  end if;

  return NEW;
end;
$$ language plpgsql;


-- Add toll-free process-message
-- ------------------------------------

create or replace function sms.process_toll_free_message(message sms.outbound_messages, prev_mapping_validity_interval interval DEFAULT '14 days'::interval)
  returns json
  as $$
declare
  v_channel sms.traffic_channel;
  v_sending_location_id uuid;
  v_from_number phone_number;
  v_result record;
begin
  select
      p.channel
    , sl.id
    , pn.phone_number
  from sms.phone_numbers pn
  join sms.sending_locations sl on sl.id = pn.sending_location_id
  join sms.profiles p on p.id = sl.profile_id
  where sl.profile_id = message.profile_id
  into
      v_channel
    , v_sending_location_id
    , v_from_number;

  if v_channel <> 'toll-free' then
    raise exception 'Profile is not toll-free channel: %', message.profile_id;
  end if;

  if v_sending_location_id is null or v_from_number is null then
    raise exception 'No toll-free number for profile: %', message.profile_id;
  end if;

  insert into sms.outbound_messages_routing (
      id
    , original_created_at
    , from_number
    , to_number
    , stage
    , sending_location_id
    , decision_stage
    , processed_at
  )
  values (
      message.id
    , message.created_at
    , v_from_number
    , message.to_number
    , 'queued'
    , v_sending_location_id
    , 'prev_mapping'
    , now()
  )
  returning *
  into v_result;

  return row_to_json(v_result);
end;
$$ language plpgsql security definer;

comment on function sms.process_toll_free_message is E'@omit';
