-- Newsletter records are private. Only the authenticated server gateway may access them.
create table public.newsletter_subscribers (
 id uuid primary key default gen_random_uuid(),
 email text not null unique check (email = lower(trim(email)) and length(email) between 5 and 100),
 status text not null default 'pending' check(status in ('pending','active','unsubscribed','bounced','complained')),
 topics text[] not null default array['oath','markets','security','guides'],
 pending_topics text[] not null default array['oath','markets','security','guides'],
 source text not null default '/', consent_version text not null default '2026-09-29',
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 last_signup_at timestamptz not null default now(), confirmed_at timestamptz, unsubscribed_at timestamptz,
 check(topics <@ array['oath','markets','security','guides']::text[]),
 check(pending_topics <@ array['oath','markets','security','guides']::text[])
);
create index newsletter_subscribers_status_created on public.newsletter_subscribers(status,created_at desc);
create table public.newsletter_tokens (
 token_hash text primary key, subscriber_id uuid not null references public.newsletter_subscribers(id) on delete cascade,
 expires_at timestamptz not null, used_at timestamptz, created_at timestamptz not null default now()
);
create table public.newsletter_campaigns (
 id uuid primary key default gen_random_uuid(), name text not null check(length(name) between 1 and 150),
 subject text not null check(length(subject) between 1 and 200), preheader text not null default '',
 body text not null check(length(body) <= 50000), topic text not null default 'all' check(topic in ('all','oath','markets','security','guides')),
 status text not null default 'draft' check(status in ('draft','queued','sending','complete','cancelled')),
 tracking boolean not null default true, scheduled_at timestamptz, recipient_count integer not null default 0,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.newsletter_messages (
 id uuid primary key default gen_random_uuid(), subscriber_id uuid references public.newsletter_subscribers(id) on delete set null,
 campaign_id uuid references public.newsletter_campaigns(id), kind text not null check(kind in ('confirmation','campaign','test')),
 email text not null, status text not null default 'queued' check(status in ('queued','sending','accepted','failed','uncertain','cancelled','skipped')),
 dedupe_key text not null unique, payload jsonb not null default '{}', provider_id text,
 error text, attempts integer not null default 0, available_at timestamptz not null default now(),
 claimed_at timestamptz, accepted_at timestamptz, created_at timestamptz not null default now()
);
create index newsletter_messages_dispatch on public.newsletter_messages(status,available_at);
create index newsletter_messages_campaign on public.newsletter_messages(campaign_id,status);
create index newsletter_messages_provider on public.newsletter_messages(provider_id);
create table public.newsletter_events (
 id text primary key, message_id uuid not null references public.newsletter_messages(id),
 campaign_id uuid references public.newsletter_campaigns(id), subscriber_id uuid references public.newsletter_subscribers(id) on delete set null,
 kind text not null check(kind in ('delivered','open','click','bounce','complaint','unsubscribe')),
 occurred_at timestamptz not null, received_at timestamptz not null default now(), detail text
);
create index newsletter_events_campaign_kind on public.newsletter_events(campaign_id,kind,message_id);
create index newsletter_events_time on public.newsletter_events(occurred_at desc);
create table public.newsletter_admin_sessions (
 token_hash text primary key, credential_version text not null, expires_at timestamptz not null,
 created_at timestamptz not null default now()
);
create table public.newsletter_audit (
 id bigint generated always as identity primary key, action text not null, detail jsonb not null default '{}',
 created_at timestamptz not null default now()
);
create table public.newsletter_limits (
 key text primary key, count integer not null default 1, expires_at timestamptz not null
);
create table public.newsletter_health (
 key text primary key, value jsonb not null, updated_at timestamptz not null default now()
);
do $$ declare t text; begin
 foreach t in array array['newsletter_subscribers','newsletter_tokens','newsletter_campaigns','newsletter_messages','newsletter_events','newsletter_admin_sessions','newsletter_audit','newsletter_limits','newsletter_health'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('revoke all on public.%I from anon, authenticated',t);
 execute format('grant all on public.%I to service_role',t);
 end loop;
end $$;

create or replace function public.newsletter_rate_limit(p_key text,p_limit integer,p_seconds integer)
returns boolean language plpgsql security definer set search_path = public,pg_temp as $$
declare n integer; begin
 insert into newsletter_limits(key,count,expires_at) values(p_key,1,now()+make_interval(secs=>p_seconds))
 on conflict(key) do update set count=case when newsletter_limits.expires_at<now() then 1 else newsletter_limits.count+1 end,
 expires_at=case when newsletter_limits.expires_at<now() then now()+make_interval(secs=>p_seconds) else newsletter_limits.expires_at end
 returning count into n;
 return n<=p_limit;
end $$;

create or replace function public.newsletter_signup(p_email text,p_topics text[],p_source text,p_token_hash text,p_token text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare s newsletter_subscribers; begin
 -- Unique email and a row lock prevent duplicate concurrent confirmation messages.
 insert into newsletter_subscribers(email,topics,pending_topics,source,last_signup_at)
 values(p_email,p_topics,p_topics,p_source,now()-interval '2 hours') on conflict(email) do nothing;
 select * into s from newsletter_subscribers where email=p_email for update;
 if s.status in ('active','bounced','complained') or s.last_signup_at>now()-interval '1 hour' then
 return jsonb_build_object('ok',true,'queued',false); end if;
 update newsletter_subscribers set pending_topics=p_topics,last_signup_at=now(),updated_at=now() where id=s.id;
 insert into newsletter_tokens(token_hash,subscriber_id,expires_at) values(p_token_hash,s.id,now()+interval '7 days');
 insert into newsletter_messages(subscriber_id,kind,email,dedupe_key,payload)
 values(s.id,'confirmation',s.email,'confirm:'||p_token_hash,jsonb_build_object('token',p_token));
 return jsonb_build_object('ok',true,'queued',true);
end $$;

create or replace function public.newsletter_confirm(p_hash text)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare t newsletter_tokens; s newsletter_subscribers; begin
 select * into t from newsletter_tokens where token_hash=p_hash for update;
 if not found or t.expires_at<now() then return false; end if;
 select * into s from newsletter_subscribers where id=t.subscriber_id for update;
 if s.status in ('bounced','complained') then return false; end if;
 if t.used_at is not null then return s.status='active'; end if;
 update newsletter_tokens set used_at=now() where token_hash=p_hash;
 update newsletter_subscribers set status='active',topics=pending_topics,confirmed_at=now(),updated_at=now(),unsubscribed_at=null where id=s.id;
 insert into newsletter_audit(action,detail) values('subscriber_confirmed',jsonb_build_object('subscriber_id',s.id));
 return true;
end $$;

create or replace function public.newsletter_unsubscribe(p_id uuid,p_status text default 'unsubscribed')
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if p_status not in ('unsubscribed','bounced','complained') then raise exception 'invalid_status'; end if;
 update newsletter_subscribers set status=case when status='complained' then status else p_status end,
 unsubscribed_at=coalesce(unsubscribed_at,now()),updated_at=now() where id=p_id;
 if not found then return false; end if;
 update newsletter_tokens set expires_at=least(expires_at,now()) where subscriber_id=p_id;
 update newsletter_messages set status='cancelled',payload='{}' where subscriber_id=p_id and status='queued';
 insert into newsletter_audit(action,detail) values('subscriber_'||p_status,jsonb_build_object('subscriber_id',p_id));
 return true;
end $$;

create or replace function public.newsletter_queue_campaign(p_id uuid,p_expected integer,p_schedule timestamptz)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare c newsletter_campaigns; n integer; begin
 select * into c from newsletter_campaigns where id=p_id for update;
 if not found or c.status<>'draft' then return jsonb_build_object('error','Campaign is no longer a draft.'); end if;
 -- Lock recipients so an unsubscribe cannot slip between eligibility and queue insertion.
 perform id from newsletter_subscribers where status='active' and (c.topic='all' or c.topic=any(topics)) for share;
 select count(*) into n from newsletter_subscribers where status='active' and (c.topic='all' or c.topic=any(topics));
 if n<>p_expected or n=0 then return jsonb_build_object('error','Audience changed or is empty. Review it again.'); end if;
 update newsletter_campaigns set status='queued',recipient_count=n,scheduled_at=greatest(coalesce(p_schedule,now()),now()),updated_at=now() where id=p_id;
 insert into newsletter_messages(subscriber_id,campaign_id,kind,email,dedupe_key,available_at)
 select id,p_id,'campaign',email,p_id::text||':'||id::text,greatest(coalesce(p_schedule,now()),now()) from newsletter_subscribers
 where status='active' and (c.topic='all' or c.topic=any(topics));
 insert into newsletter_audit(action,detail) values('campaign_queued',jsonb_build_object('campaign_id',p_id,'recipients',n,'scheduled_at',p_schedule));
 return jsonb_build_object('ok',true,'recipients',n);
end $$;

create or replace function public.newsletter_cancel_campaign(p_id uuid)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
begin
 update newsletter_campaigns set status='cancelled',updated_at=now() where id=p_id and status in ('queued','sending');
 if not found then return false; end if;
 update newsletter_messages set status='cancelled' where campaign_id=p_id and status='queued';
 insert into newsletter_audit(action,detail) values('campaign_cancelled',jsonb_build_object('campaign_id',p_id));
 return true;
end $$;

create or replace function public.newsletter_claim_messages(p_limit integer default 10)
returns setof newsletter_messages language plpgsql security definer set search_path=public,pg_temp as $$
begin
 -- A lost provider response must be reconciled, never blindly retried.
 update newsletter_messages set status='uncertain',error='Delivery request interrupted; reconcile with provider before retrying.'
 where status='sending' and claimed_at<now()-interval '10 minutes';
 update newsletter_messages m set status='skipped',payload='{}' where status='queued' and
 ((kind='campaign' and not exists(select 1 from newsletter_subscribers s where s.id=m.subscriber_id and s.status='active'))
 or (kind='confirmation' and created_at<now()-interval '7 days'));
 return query update newsletter_messages m set status='sending',claimed_at=now(),attempts=m.attempts+1
 where m.id in(select id from newsletter_messages where status='queued' and available_at<=now() order by available_at,id for update skip locked limit least(p_limit,20)) returning m.*;
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
 update newsletter_messages set provider_id=coalesce(provider_id,p_event->>'provider_id'),status='accepted',accepted_at=coalesce(accepted_at,now()),error=null,payload='{}'
 where id=m.id and status in ('sending','uncertain');
 if m.subscriber_id is not null and (p_event->>'kind' in ('complaint','unsubscribe') or p_event->>'hard_bounce'='true') then
 perform newsletter_unsubscribe(m.subscriber_id,case p_event->>'kind' when 'complaint' then 'complained' when 'bounce' then 'bounced' else 'unsubscribed' end);
 end if;
 return true;
end $$;

create or replace function public.newsletter_dashboard(p_days integer default 30)
returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
 select jsonb_build_object(
 'subscribers',(select jsonb_build_object('total',count(*),'active',count(*) filter(where status='active'),'pending',count(*) filter(where status='pending'),'unsubscribed',count(*) filter(where status='unsubscribed'),'bounced',count(*) filter(where status='bounced'),'complained',count(*) filter(where status='complained')) from newsletter_subscribers),
 'delivery',(select jsonb_build_object('accepted',count(*) filter(where status='accepted'),'queued',count(*) filter(where status='queued'),'sending',count(*) filter(where status='sending'),'failed',count(*) filter(where status='failed'),'uncertain',count(*) filter(where status='uncertain'),'cancelled',count(*) filter(where status='cancelled'),'skipped',count(*) filter(where status='skipped')) from newsletter_messages where kind='campaign' and created_at>=now()-make_interval(days=>p_days)),
 'events',(select coalesce(jsonb_object_agg(kind,n),'{}') from (select kind,count(distinct message_id) n from newsletter_events where campaign_id is not null and occurred_at>=now()-make_interval(days=>p_days) group by kind) e),
 'growth',(select jsonb_agg(jsonb_build_object('day',d::date,'signups',(select count(*) from newsletter_subscribers where created_at>=d and created_at<d+interval '1 day'),'confirmed',(select count(*) from newsletter_subscribers where confirmed_at>=d and confirmed_at<d+interval '1 day'))) from generate_series(date_trunc('day',now())-make_interval(days=>p_days-1),date_trunc('day',now()),interval '1 day') d),
 'topics',(select jsonb_object_agg(topic,n) from (select unnest(topics) topic,count(*) n from newsletter_subscribers where status='active' group by 1) t),
 'health',(select coalesce(jsonb_object_agg(key,jsonb_build_object('value',value,'updated_at',updated_at)),'{}') from newsletter_health),
 'audit',(select coalesce(jsonb_agg(a),'[]') from (select * from newsletter_audit order by created_at desc limit 20) a)
 );
$$;

create or replace function public.newsletter_campaign_stats(p_id uuid)
returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
 select jsonb_build_object('messages',(select coalesce(jsonb_object_agg(status,n),'{}') from(select status,count(*) n from newsletter_messages where campaign_id=p_id and kind='campaign' group by status)m),
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
