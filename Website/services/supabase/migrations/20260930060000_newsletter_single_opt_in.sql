begin;

-- Record activation separately from proof of mailbox ownership. A direct signup
-- must never be reported as an email confirmation.
alter table public.newsletter_subscribers
 add column subscribed_at timestamptz,
 add column opt_in_method text not null default 'single'
  check(opt_in_method in ('single','email_confirmation'));

update public.newsletter_subscribers
set subscribed_at=confirmed_at,opt_in_method='email_confirmation'
where confirmed_at is not null;

-- These visitors already submitted explicit newsletter consent. Remove their
-- remaining confirmation step, without reactivating opt-outs or suppressed mail.
with activated as (
 update public.newsletter_subscribers
 set status='active',topics=pending_topics,subscribed_at=now(),
     opt_in_method='single',updated_at=now()
 where status='pending'
 returning id
)
insert into public.newsletter_audit(action,detail)
select 'subscriber_subscribed',jsonb_build_object('subscriber_id',id,
 'method','single','reason','confirmation_requirement_removed') from activated;

update public.newsletter_messages
set status='cancelled',payload='{}',error='Email confirmation is no longer required.'
where kind='confirmation' and status='queued';

-- Keep the legacy parameters for already deployed clients during the rollout.
-- No token or confirmation message is created, even when those values are sent.
create or replace function public.newsletter_signup(
 p_email text,p_topics text[],p_source text,
 p_token_hash text default null,p_token text default null
)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare s newsletter_subscribers; inserted_id uuid; begin
 insert into newsletter_subscribers(email,status,topics,pending_topics,source,
  consent_version,subscribed_at,opt_in_method)
 values(p_email,'active',p_topics,p_topics,p_source,
  '2026-09-30-single-opt-in',now(),'single')
 on conflict(email) do nothing returning id into inserted_id;
 select * into s from newsletter_subscribers where email=p_email for update;
 if s.status in ('bounced','complained') then
  return jsonb_build_object('ok',true,'queued',false,'subscribed',false);
 end if;
 -- Duplicate public signups cannot change an existing subscriber's preferences.
 if s.status='active' and inserted_id is null then
  return jsonb_build_object('ok',true,'queued',false,'subscribed',true);
 end if;
 if inserted_id is null then
  update newsletter_subscribers set status='active',topics=p_topics,
   pending_topics=p_topics,subscribed_at=now(),opt_in_method='single',
   consent_version='2026-09-30-single-opt-in',last_signup_at=now(),
   updated_at=now(),unsubscribed_at=null where id=s.id;
 end if;
 update newsletter_messages set status='cancelled',payload='{}',
  error='Email confirmation is no longer required.'
 where subscriber_id=s.id and kind='confirmation' and status='queued';
 insert into newsletter_audit(action,detail) values('subscriber_subscribed',
  jsonb_build_object('subscriber_id',s.id,'method','single',
   'resubscribed',s.status='unsubscribed'));
 return jsonb_build_object('ok',true,'queued',false,'subscribed',true);
end $$;

-- Old emailed links may report an already-active subscription, but must never
-- activate an address or undo an unsubscribe. The legacy endpoint is read-only.
create or replace function public.newsletter_confirm(p_hash text)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
 select exists(select 1 from newsletter_tokens t
  join newsletter_subscribers s on s.id=t.subscriber_id
  where t.token_hash=p_hash and s.status='active');
$$;

-- An older running dispatcher also cannot prepare another confirmation email.
create or replace function public.newsletter_prepare_confirmation(
 p_message_id uuid,p_token_hash text,p_token text
)
returns text language sql stable security definer set search_path=public,pg_temp as $$
 select null::text;
$$;

revoke all on function public.newsletter_signup(text,text[],text,text,text),
 public.newsletter_confirm(text),public.newsletter_prepare_confirmation(uuid,text,text)
 from public,anon,authenticated;
grant execute on function public.newsletter_signup(text,text[],text,text,text),
 public.newsletter_confirm(text),public.newsletter_prepare_confirmation(uuid,text,text)
 to service_role;

-- Preserve the existing campaign cohort and daily sending cap.
CREATE OR REPLACE FUNCTION public.newsletter_dashboard(p_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
 with bounds as (
  select date_trunc('day',now())-make_interval(days=>greatest(1,least(p_days,365))-1) as since
 ), cohort as (
  select m.* from newsletter_messages m, bounds b where m.kind='campaign' and m.created_at>=b.since
 )
 select jsonb_build_object(
 'subscribers',(select jsonb_build_object('total',count(*),'active',count(*) filter(where status='active'),'pending',count(*) filter(where status='pending'),'unsubscribed',count(*) filter(where status='unsubscribed'),'bounced',count(*) filter(where status='bounced'),'complained',count(*) filter(where status='complained')) from newsletter_subscribers),
 'delivery',(select jsonb_build_object('accepted',count(*) filter(where accepted_at is not null),'queued',count(*) filter(where status='queued'),'sending',count(*) filter(where status='sending'),'failed',count(*) filter(where status='failed'),'uncertain',count(*) filter(where status='uncertain'),'cancelled',count(*) filter(where status='cancelled'),'skipped',count(*) filter(where status='skipped')) from cohort),
 'events',(select coalesce(jsonb_object_agg(kind,n),'{}') from (select e.kind,count(distinct e.message_id) n from newsletter_events e join cohort c on c.id=e.message_id group by e.kind) e),
 'growth',(select jsonb_agg(jsonb_build_object('day',d::date,'signups',(select count(*) from newsletter_subscribers where created_at>=d and created_at<d+interval '1 day'),'confirmed',(select count(*) from newsletter_subscribers where confirmed_at>=d and confirmed_at<d+interval '1 day'),'subscribed',(select count(*) from newsletter_subscribers where subscribed_at>=d and subscribed_at<d+interval '1 day'))) from bounds, generate_series(bounds.since,date_trunc('day',now()),interval '1 day') d),
 'topics',(select jsonb_object_agg(topic,n) from (select unnest(topics) topic,count(*) n from newsletter_subscribers where status='active' group by 1) t),
 'health',(select coalesce(jsonb_object_agg(key,jsonb_build_object('value',value,'updated_at',updated_at)),'{}') from newsletter_health),
 'audit',(select coalesce(jsonb_agg(a),'[]') from (select * from newsletter_audit order by created_at desc limit 20) a),
 'reporting',jsonb_build_object('cohort','campaign messages queued in selected UTC days','since',(select since from bounds))
 );
$function$
;
CREATE OR REPLACE FUNCTION public.newsletter_claim_messages(p_limit integer DEFAULT 10, p_daily_limit integer DEFAULT 100)
 RETURNS SETOF newsletter_messages
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare remaining integer; begin
 perform pg_advisory_xact_lock(hashtext('oath-newsletter-dispatch'));
 if not newsletter_rate_limit('dispatch-global',1,60) then return; end if;
 select greatest(0,p_daily_limit-count(*)) into remaining from newsletter_messages where claimed_at>=date_trunc('day',now());
 update newsletter_messages set status='uncertain',error='Delivery request interrupted; reconcile with provider before retrying.'
 where status='sending' and claimed_at<now()-interval '10 minutes';
 update newsletter_messages m set status='skipped',payload='{}' where status='queued' and
 ((kind='campaign' and not exists(select 1 from newsletter_subscribers s where s.id=m.subscriber_id and s.status='active'))
 or (kind='confirmation'));
 return query update newsletter_messages m set status='sending',claimed_at=now(),attempts=m.attempts+1
 where m.id in(select id from newsletter_messages where status='queued' and available_at<=now() order by available_at,id for update skip locked limit least(greatest(p_limit,0),10,remaining)) returning m.*;
end $function$
;

notify pgrst, 'reload schema';

commit;
