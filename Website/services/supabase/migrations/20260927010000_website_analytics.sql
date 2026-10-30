-- Private, first-party website analytics. No IP addresses or wallet identifiers.
create table public.website_visitors (
 id uuid primary key, first_seen timestamptz not null default now(), last_seen timestamptz not null default now(), visits integer not null default 0
);
create table public.website_sessions (
 id uuid primary key, visitor_id uuid not null references public.website_visitors(id) on delete cascade,
 started_at timestamptz not null default now(), last_seen timestamptz not null default now()
);
create table public.website_events (
 id uuid primary key, visitor_id uuid not null references public.website_visitors(id) on delete cascade,
 session_id uuid not null references public.website_sessions(id) on delete cascade,
 occurred_at timestamptz not null default now(), kind text not null check(kind in ('visit','page_view','download')),
 path text not null, country text, city text, latitude double precision, longitude double precision,
 browser text not null, os text not null, device text not null, referrer text
);
create index website_events_time on public.website_events(occurred_at desc);
create index website_events_visitor on public.website_events(visitor_id,occurred_at desc);
create index website_sessions_seen on public.website_sessions(last_seen desc);
create table public.website_notification_preferences (
 installation_id uuid primary key, visits boolean not null default true, downloads boolean not null default true
);
create table public.website_notification_outbox (
 id uuid primary key default gen_random_uuid(), event_id uuid not null references public.website_events(id) on delete cascade,
 device_id uuid not null references public.vault_notification_devices(id) on delete cascade,
 state text not null default 'pending' check(state in ('pending','sending','sent','cancelled','failed')),
 attempts integer not null default 0, available_at timestamptz not null default now(), lease_token uuid, last_error text,
 unique(event_id,device_id)
);
create index website_outbox_ready on public.website_notification_outbox(state,available_at);

create function public.website_record_event(p_event jsonb) returns boolean language plpgsql security definer set search_path=public as $$
declare v uuid := (p_event->>'visitor_id')::uuid; s uuid := (p_event->>'session_id')::uuid; e uuid := (p_event->>'id')::uuid; is_new boolean; visit_id uuid; begin
 perform pg_advisory_xact_lock(hashtextextended(v::text, 0));
 if exists(select 1 from website_events where id=e) then return false; end if;
 -- Bound noisy clients; normal sessions cannot flood the notification queue.
 if (select count(*) from website_events where visitor_id=v and occurred_at>now()-interval '1 minute') >= 30 then return false; end if;
 insert into website_visitors(id) values(v) on conflict(id) do update set last_seen=now();
 if exists(select 1 from website_sessions where id=s and visitor_id<>v) then raise exception 'session_owner_mismatch'; end if;
 is_new := not exists(select 1 from website_sessions where id=s);
 insert into website_sessions(id,visitor_id) values(s,v) on conflict(id) do update set last_seen=now();
 if is_new then
   update website_visitors set visits=visits+1 where id=v;
   visit_id:=gen_random_uuid();
   insert into website_events select visit_id,v,s,now(),'visit',p_event->>'path',p_event->>'country',p_event->>'city',
     (p_event->>'latitude')::double precision,(p_event->>'longitude')::double precision,p_event->>'browser',p_event->>'os',p_event->>'device',p_event->>'referrer';
 end if;
 insert into website_events select e,v,s,now(),p_event->>'kind',p_event->>'path',p_event->>'country',p_event->>'city',
   (p_event->>'latitude')::double precision,(p_event->>'longitude')::double precision,p_event->>'browser',p_event->>'os',p_event->>'device',p_event->>'referrer';
 insert into website_notification_outbox(event_id,device_id)
 select ev.id,d.id from website_events ev cross join vault_notification_devices d
 left join website_notification_preferences p on p.installation_id=d.installation_id
 where ev.id in(e,visit_id) and d.enabled and ((ev.kind='visit' and coalesce(p.visits,true)) or (ev.kind='download' and coalesce(p.downloads,true)))
 on conflict do nothing;
 return true;
end $$;

create function public.website_notification_allowed(p_id uuid,p_lease uuid) returns boolean language sql security definer set search_path=public as $$
 select exists(select 1 from website_notification_outbox o join website_events e on e.id=o.event_id
 join vault_notification_devices d on d.id=o.device_id left join website_notification_preferences p on p.installation_id=d.installation_id
 where o.id=p_id and o.lease_token=p_lease and o.state='sending' and d.enabled
 and ((e.kind='visit' and coalesce(p.visits,true)) or(e.kind='download' and coalesce(p.downloads,true))));
$$;
create function public.website_claim_deliveries() returns jsonb language sql security definer set search_path=public as $$
 with ready as (
 select id from website_notification_outbox where state in('pending','sending') and available_at<=now() and attempts<8
 order by available_at for update skip locked limit 20
 ), claimed as (
 update website_notification_outbox o set state='sending', attempts=attempts+1, available_at=now()+interval '2 minutes',lease_token=gen_random_uuid()
 from ready where o.id=ready.id returning o.*
 ) select coalesce(jsonb_agg(jsonb_build_object('delivery_id',c.id,'apns_request_id',c.id,'lease_token',c.lease_token,'device_id',d.id,
 'apns_token',d.apns_token,'apns_environment',d.apns_environment,'kind',e.kind,'event_id',e.id,'country',e.country,'city',e.city,'path',e.path)), '[]'::jsonb)
 from claimed c join vault_notification_devices d on d.id=c.device_id join website_events e on e.id=c.event_id;
$$;
create function public.website_finish_delivery(p_id uuid,p_lease uuid,p_state text,p_error text default null) returns void language sql security definer set search_path=public as $$
 update website_notification_outbox set state=case when p_state in('sent','cancelled','failed') then p_state when attempts>=8 then 'failed' else 'pending' end,
 available_at=now()+make_interval(secs=>least(3600,30*power(2,attempts)::integer)),last_error=left(p_error,100)
 where id=p_id and lease_token=p_lease and state='sending';
$$;
create function public.website_dashboard(p_days integer default 7) returns jsonb language plpgsql security definer set search_path=public as $$
declare since timestamptz := date_trunc('day',now() at time zone 'UTC') at time zone 'UTC' - make_interval(days=>greatest(1,least(p_days,365))-1); begin
 return jsonb_build_object('generatedAt',now(),'since',since,
 'visits',(select count(*) from website_events where occurred_at>=since and kind='visit'),
 'pageViews',(select count(*) from website_events where occurred_at>=since and kind='page_view'),
 'downloads',(select count(*) from website_events where occurred_at>=since and kind='download'),
 'uniqueVisitors',(select count(distinct visitor_id) from website_events where occurred_at>=since),
 'returningVisitors',(select count(*) from website_visitors v where visits>1 and exists(select 1 from website_events e where e.visitor_id=v.id and e.occurred_at>=since)),
 'activeNow',(select count(distinct visitor_id) from website_sessions where last_seen>now()-interval '5 minutes'),
 'daily',(select coalesce(jsonb_agg(x order by x.day),'[]') from (
 select to_char(d,'YYYY-MM-DD') as day,count(e.id) filter(where kind='visit') as visits,count(e.id) filter(where kind='download') as downloads
 from generate_series(since,date_trunc('day',now()),interval '1 day') d left join website_events e on e.occurred_at>=d and e.occurred_at<d+interval '1 day' group by d) x),
 'locations',(select coalesce(jsonb_agg(x),'[]') from (select coalesce(country,'Unknown') as country,city,latitude,longitude,
 count(*) as visits,count(distinct visitor_id) as visitors from website_events where occurred_at>=since and kind='visit' group by country,city,latitude,longitude order by count(*) desc limit 200) x),
 'recent',(select coalesce(jsonb_agg(x),'[]') from (select * from website_events where occurred_at>=since order by occurred_at desc limit 100) x),
 'visitors',(select coalesce(jsonb_agg(x),'[]') from (select v.id,v.first_seen,v.last_seen,v.visits,
 (select jsonb_build_object('country',e.country,'city',e.city,'browser',e.browser,'os',e.os,'device',e.device,'path',e.path) from website_events e where e.visitor_id=v.id order by e.occurred_at desc limit 1) as latest
 from website_visitors v where last_seen>=since order by last_seen desc limit 100) x));
end $$;

-- Strict service-only access, including RPCs.
do $$ declare t text; f record; begin
 foreach t in array array['website_visitors','website_sessions','website_events','website_notification_preferences','website_notification_outbox'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('revoke all on public.%I from public,anon,authenticated',t);
 execute format('grant all on public.%I to service_role',t);
 end loop;
 for f in select oid::regprocedure as signature from pg_proc where pronamespace='public'::regnamespace and proname in('website_record_event','website_notification_allowed','website_claim_deliveries','website_finish_delivery','website_dashboard') loop
 execute format('revoke all on function %s from public,anon,authenticated',f.signature);
 execute format('grant execute on function %s to service_role',f.signature);
 end loop;
end $$;

create function public.website_prune_history() returns void language plpgsql security definer set search_path=public as $$
begin
 delete from website_events where id in(select id from website_events where occurred_at<now()-interval '400 days' limit 5000);
 delete from website_visitors where id in(select id from website_visitors where last_seen<now()-interval '400 days' limit 1000);
 delete from website_sessions where id in(select s.id from website_sessions s where s.last_seen<now()-interval '400 days' and not exists(select 1 from website_events e where e.session_id=s.id) limit 1000);
end $$;
revoke all on function public.website_prune_history() from public,anon,authenticated;
grant execute on function public.website_prune_history() to service_role;
