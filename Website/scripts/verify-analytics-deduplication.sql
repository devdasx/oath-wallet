-- This verification rolls back every insert, including notification-outbox rows.
-- Other connections cannot observe the uncommitted test events. No push is sent.
begin;
do $$
declare
  visitor uuid := gen_random_uuid();
  session uuid := gen_random_uuid();
  event uuid := gen_random_uuid();
  payload jsonb;
  first_result boolean;
  second_result boolean;
begin
  payload:=jsonb_build_object('visitor_id',visitor,'session_id',session,'id',event,
    'kind','download','path','/__transactional_analytics_check',
    'browser','Other','os','Other','device','Desktop');
  first_result:=public.website_record_event(payload);
  second_result:=public.website_record_event(payload);
  if first_result is not true or second_result is not false then
    raise exception 'event retry deduplication failed';
  end if;
  if (select count(*) from public.website_events where id=event)<>1 then
    raise exception 'duplicate click persisted';
  end if;
  if (select count(*) from public.website_events where session_id=session and kind='visit')<>1 then
    raise exception 'duplicate visit persisted';
  end if;
end $$;
rollback;
select 'passed; all test rows rolled back' as verification;
