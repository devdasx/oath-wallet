-- Keep all delivery and engagement numerators in the same recipient cohort.
-- Events from older campaigns must not inflate the current period's rates.
create or replace function public.newsletter_dashboard(p_days integer default 30)
returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
 with bounds as (
  select date_trunc('day',now())-make_interval(days=>greatest(1,least(p_days,365))-1) as since
 ), cohort as (
  select m.* from newsletter_messages m, bounds b where m.kind='campaign' and m.created_at>=b.since
 )
 select jsonb_build_object(
 'subscribers',(select jsonb_build_object('total',count(*),'active',count(*) filter(where status='active'),'pending',count(*) filter(where status='pending'),'unsubscribed',count(*) filter(where status='unsubscribed'),'bounced',count(*) filter(where status='bounced'),'complained',count(*) filter(where status='complained')) from newsletter_subscribers),
 'delivery',(select jsonb_build_object('accepted',count(*) filter(where accepted_at is not null),'queued',count(*) filter(where status='queued'),'sending',count(*) filter(where status='sending'),'failed',count(*) filter(where status='failed'),'uncertain',count(*) filter(where status='uncertain'),'cancelled',count(*) filter(where status='cancelled'),'skipped',count(*) filter(where status='skipped')) from cohort),
 'events',(select coalesce(jsonb_object_agg(kind,n),'{}') from (select e.kind,count(distinct e.message_id) n from newsletter_events e join cohort c on c.id=e.message_id group by e.kind) e),
 'growth',(select jsonb_agg(jsonb_build_object('day',d::date,'signups',(select count(*) from newsletter_subscribers where created_at>=d and created_at<d+interval '1 day'),'confirmed',(select count(*) from newsletter_subscribers where confirmed_at>=d and confirmed_at<d+interval '1 day'))) from bounds, generate_series(bounds.since,date_trunc('day',now()),interval '1 day') d),
 'topics',(select jsonb_object_agg(topic,n) from (select unnest(topics) topic,count(*) n from newsletter_subscribers where status='active' group by 1) t),
 'health',(select coalesce(jsonb_object_agg(key,jsonb_build_object('value',value,'updated_at',updated_at)),'{}') from newsletter_health),
 'audit',(select coalesce(jsonb_agg(a),'[]') from (select * from newsletter_audit order by created_at desc limit 20) a),
 'reporting',jsonb_build_object('cohort','campaign messages queued in selected UTC days','since',(select since from bounds))
 );
$$;
revoke all on function public.newsletter_dashboard(integer) from public, anon, authenticated;
grant execute on function public.newsletter_dashboard(integer) to service_role;
