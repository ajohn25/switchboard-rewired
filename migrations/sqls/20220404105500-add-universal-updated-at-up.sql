-- Add updated_at trigger function
-- --------------------------------------------

create function public.universal_updated_at() returns trigger as $$
begin
  NEW.updated_at = CURRENT_TIMESTAMP;
  return NEW;
end;
$$ language plpgsql;
