begin;
alter table public.newsletter_events drop constraint newsletter_events_kind_check;
alter table public.newsletter_events add constraint newsletter_events_kind_check check(kind in ('accepted','delivered','open','click','bounce','complaint','unsubscribe','delayed','failed','suppressed'));
grant usage, select on sequence public.newsletter_audit_id_seq to service_role;
drop function public.newsletter_claim_messages(integer);
create or replace function public.newsletter_claim_messages(p_limit integer default 10,p_daily_limit integer default 100)
returns setof newsletter_messages language plpgsql security definer set search_path=public,pg_temp as $$
declare remaining integer; begin
 perform pg_advisory_xact_lock(hashtext('oath-newsletter-dispatch'));
 if not newsletter_rate_limit('dispatch-global',1,60) then return; end if;
 select greatest(0,p_daily_limit-count(*)) into remaining from newsletter_messages where claimed_at>=date_trunc('day',now());
 -- A lost provider response must be reconciled, never blindly retried.
 update newsletter_messages set status='uncertain',error='Delivery request interrupted; reconcile with provider before retrying.'
 where status='sending' and claimed_at<now()-interval '10 minutes';
 update newsletter_messages m set status='skipped',payload='{}' where status='queued' and
 ((kind='campaign' and not exists(select 1 from newsletter_subscribers s where s.id=m.subscriber_id and s.status='active'))
 or (kind='confirmation' and created_at<now()-interval '7 days'));
 return query update newsletter_messages m set status='sending',claimed_at=now(),attempts=m.attempts+1
 where m.id in(select id from newsletter_messages where status='queued' and available_at<=now() order by available_at,id for update skip locked limit least(p_limit,10,remaining)) returning m.*;
end $$;

create or replace function public.newsletter_record_event(p_event jsonb)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare m newsletter_messages; begin
 select * into m from newsletter_messages where id=(p_event->>'message_id')::uuid for update;
 if not found or lower(m.email)<>lower(p_event->>'email') then return false; end if;
 if m.provider_id is not null and m.provider_id<>p_event->>'provider_id' then return false; end if;
 insert into newsletter_events(id,message_id,campaign_id,subscriber_id,kind,occurred_at,detail)
 values(p_event->>'id',m.id,m.campaign_id,m.subscriber_id,p_event->>'kind',(p_event->>'occurred_at')::timestamptz,p_event->>'detail') on conflict(id) do nothing;
 if not found then return true; end if;
 update newsletter_messages set provider_id=coalesce(provider_id,p_event->>'provider_id'),status='accepted',accepted_at=coalesce(accepted_at,now()),error=null
 where id=m.id and status in ('sending','uncertain');
 if p_event->>'kind' in ('failed','suppressed') then
 update newsletter_messages set status='failed',provider_id=coalesce(provider_id,p_event->>'provider_id'),error=coalesce(p_event->>'detail','Provider failure') where id=m.id;
 end if;
 if m.subscriber_id is not null and (p_event->>'kind' in ('complaint','unsubscribe','suppressed') or p_event->>'hard_bounce'='true') then
 perform newsletter_unsubscribe(m.subscriber_id,case p_event->>'kind' when 'complaint' then 'complained' when 'bounce' then 'bounced' when 'suppressed' then 'bounced' else 'unsubscribed' end);
 end if;
 return true;
end $$;

create or replace function public.newsletter_dashboard(p_days integer default 30)
returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
 select jsonb_build_object(
 'subscribers',(select jsonb_build_object('total',count(*),'active',count(*) filter(where status='active'),'pending',count(*) filter(where status='pending'),'unsubscribed',count(*) filter(where status='unsubscribed'),'bounced',count(*) filter(where status='bounced'),'complained',count(*) filter(where status='complained')) from newsletter_subscribers),
 'delivery',(select jsonb_build_object('accepted',count(*) filter(where accepted_at is not null),'queued',count(*) filter(where status='queued'),'sending',count(*) filter(where status='sending'),'failed',count(*) filter(where status='failed'),'uncertain',count(*) filter(where status='uncertain'),'cancelled',count(*) filter(where status='cancelled'),'skipped',count(*) filter(where status='skipped')) from newsletter_messages where kind='campaign' and created_at>=now()-make_interval(days=>p_days)),
 'events',(select coalesce(jsonb_object_agg(kind,n),'{}') from (select kind,count(distinct message_id) n from newsletter_events where campaign_id is not null and occurred_at>=now()-make_interval(days=>p_days) group by kind) e),
 'growth',(select jsonb_agg(jsonb_build_object('day',d::date,'signups',(select count(*) from newsletter_subscribers where created_at>=d and created_at<d+interval '1 day'),'confirmed',(select count(*) from newsletter_subscribers where confirmed_at>=d and confirmed_at<d+interval '1 day'))) from generate_series(date_trunc('day',now())-make_interval(days=>p_days-1),date_trunc('day',now()),interval '1 day') d),
 'topics',(select jsonb_object_agg(topic,n) from (select unnest(topics) topic,count(*) n from newsletter_subscribers where status='active' group by 1) t),
 'health',(select coalesce(jsonb_object_agg(key,jsonb_build_object('value',value,'updated_at',updated_at)),'{}') from newsletter_health),
 'audit',(select coalesce(jsonb_agg(a),'[]') from (select * from newsletter_audit order by created_at desc limit 20) a)
 );
$$;

create or replace function public.newsletter_campaign_stats(p_id uuid)
returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
 select jsonb_build_object('accepted_total',(select count(*) from newsletter_messages where campaign_id=p_id and accepted_at is not null),'messages',(select coalesce(jsonb_object_agg(status,n),'{}') from(select status,count(*) n from newsletter_messages where campaign_id=p_id and kind='campaign' group by status)m),
 'events',(select coalesce(jsonb_object_agg(kind,n),'{}') from(select kind,count(distinct message_id) n from newsletter_events where campaign_id=p_id group by kind)e),
 'recent',(select coalesce(jsonb_agg(r),'[]') from(select m.email,m.status,m.error,m.accepted_at,m.created_at from newsletter_messages m where campaign_id=p_id order by created_at desc limit 100)r));
$$;

-- Function execution must not leak through PostgREST's default PUBLIC grant.
do $$ declare r record; begin
 for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'newsletter_%' loop
 execute 'revoke all on function '||r.sig||' from public, anon, authenticated';
 execute 'grant execute on function '||r.sig||' to service_role';
 end loop;
end $$;

commit;
