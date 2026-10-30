begin;

-- Keep one unsent confirmation per address while collection is open and sending is off.
create or replace function public.newsletter_signup(p_email text,p_topics text[],p_source text,p_token_hash text,p_token text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare s newsletter_subscribers; begin
 insert into newsletter_subscribers(email,topics,pending_topics,source,last_signup_at)
 values(p_email,p_topics,p_topics,p_source,now()-interval '2 hours') on conflict(email) do nothing;
 select * into s from newsletter_subscribers where email=p_email for update;
 if s.status in ('active','bounced','complained') or s.last_signup_at>now()-interval '1 hour' then
  return jsonb_build_object('ok',true,'queued',false);
 end if;
 update newsletter_subscribers set pending_topics=p_topics,
  topics=case when status='pending' then p_topics else topics end,
  last_signup_at=now(),updated_at=now() where id=s.id;
 if exists(select 1 from newsletter_messages where subscriber_id=s.id and kind='confirmation' and status in ('queued','sending','uncertain')) then
  return jsonb_build_object('ok',true,'queued',false);
 end if;
 insert into newsletter_tokens(token_hash,subscriber_id,expires_at) values(p_token_hash,s.id,now()+interval '7 days');
 insert into newsletter_messages(subscriber_id,kind,email,dedupe_key,payload)
 values(s.id,'confirmation',s.email,'confirm:'||p_token_hash,jsonb_build_object('token',p_token));
 return jsonb_build_object('ok',true,'queued',true);
end $$;

-- Expiry is inclusive, and confirmation follows the same subscriber-first lock order
-- as unsubscribe and send preparation.
create or replace function public.newsletter_confirm(p_hash text)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare t newsletter_tokens; s newsletter_subscribers; begin
 select * into t from newsletter_tokens where token_hash=p_hash;
 if not found then return false; end if;
 select * into s from newsletter_subscribers where id=t.subscriber_id for update;
 if not found then return false; end if;
 select * into t from newsletter_tokens where token_hash=p_hash for update;
 if not found or t.expires_at<=now() or s.status in ('bounced','complained') then return false; end if;
 if t.used_at is not null then return s.status='active'; end if;
 update newsletter_tokens set used_at=now() where token_hash=p_hash;
 update newsletter_subscribers set status='active',topics=pending_topics,confirmed_at=now(),updated_at=now(),unsubscribed_at=null where id=s.id;
 insert into newsletter_audit(action,detail) values('subscriber_confirmed',jsonb_build_object('subscriber_id',s.id));
 return true;
end $$;

-- Existing collected signups must not be discarded just because launch is delayed.
create or replace function public.newsletter_claim_messages(p_limit integer default 10,p_daily_limit integer default 100)
returns setof newsletter_messages language plpgsql security definer set search_path=public,pg_temp as $$
declare remaining integer; begin
 perform pg_advisory_xact_lock(hashtext('oath-newsletter-dispatch'));
 if not newsletter_rate_limit('dispatch-global',1,60) then return; end if;
 select greatest(0,p_daily_limit-count(*)) into remaining from newsletter_messages where claimed_at>=date_trunc('day',now());
 update newsletter_messages set status='uncertain',error='Delivery request interrupted; reconcile with provider before retrying.'
 where status='sending' and claimed_at<now()-interval '10 minutes';
 update newsletter_messages m set status='skipped',payload='{}' where status='queued' and
 ((kind='campaign' and not exists(select 1 from newsletter_subscribers s where s.id=m.subscriber_id and s.status='active'))
 or (kind='confirmation' and not exists(select 1 from newsletter_subscribers s where s.id=m.subscriber_id
  and (s.status='pending' or (s.status='unsubscribed' and s.last_signup_at>s.unsubscribed_at)))));
 return query update newsletter_messages m set status='sending',claimed_at=now(),attempts=m.attempts+1
 where m.id in(select id from newsletter_messages where status='queued' and available_at<=now() order by available_at,id for update skip locked limit least(greatest(p_limit,0),10,remaining)) returning m.*;
end $$;

-- Generate a fresh seven-day link immediately before the provider submission.
-- Subscriber locking preserves an unsubscribe that happens before this preparation.
create or replace function public.newsletter_prepare_confirmation(p_message_id uuid,p_token_hash text,p_token text)
returns text language plpgsql security definer set search_path=public,pg_temp as $$
declare m newsletter_messages; s newsletter_subscribers; current_token text; begin
 if p_token_hash!~'^[a-f0-9]{64}$' or p_token!~'^[a-f0-9]{64}$' then raise exception 'invalid_token'; end if;
 select * into m from newsletter_messages where id=p_message_id;
 if not found or m.kind<>'confirmation' or m.subscriber_id is null then return null; end if;
 select * into s from newsletter_subscribers where id=m.subscriber_id for update;
 select * into m from newsletter_messages where id=p_message_id for update;
 if not found or m.status<>'sending' or m.provider_id is not null or m.claimed_at is null or m.claimed_at<now()-interval '10 minutes' then return null; end if;
 if s.status<>'pending' and not (s.status='unsubscribed' and s.last_signup_at>s.unsubscribed_at) then
  update newsletter_messages set status='skipped',payload='{}' where id=m.id;
  return null;
 end if;
 if m.payload->>'prepared_for'=m.id::text then
  select token_hash into current_token from newsletter_tokens
  where token_hash=m.payload->>'token_hash' and subscriber_id=s.id and used_at is null and expires_at>now();
  if found then return m.payload->>'token'; end if;
 end if;
 insert into newsletter_tokens(token_hash,subscriber_id,expires_at) values(p_token_hash,s.id,now()+interval '7 days');
 update newsletter_messages set payload=jsonb_build_object('token',p_token,'token_hash',p_token_hash,'prepared_for',m.id,'prepared_at',now()) where id=m.id;
 return p_token;
end $$;

-- Summarize stated interests during collection, including unconfirmed signups.
create or replace function public.newsletter_signup_topics()
returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
 select coalesce(jsonb_object_agg(topic,n),'{}') from (
  select unnest(case when status='pending' then pending_topics else topics end) topic,count(*) n
  from newsletter_subscribers where status in ('pending','active') group by 1
 ) t;
$$;

-- Collapse only duplicate, never-attempted confirmations from before this migration.
with duplicates as (
 select id,row_number() over(partition by subscriber_id order by created_at desc,id) n
 from newsletter_messages where kind='confirmation' and status='queued' and attempts=0
)
update newsletter_messages set status='cancelled',payload='{}',error='A newer confirmation is already queued.'
where id in(select id from duplicates where n>1);

revoke all on function public.newsletter_prepare_confirmation(uuid,text,text),public.newsletter_signup_topics() from public,anon,authenticated;
grant execute on function public.newsletter_prepare_confirmation(uuid,text,text),public.newsletter_signup_topics() to service_role;
commit;
