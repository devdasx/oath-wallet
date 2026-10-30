begin;

-- Record what was actually enabled for a submitted message, independently of draft defaults.
alter table public.newsletter_messages add column tracking_enabled boolean not null default false;
alter table public.newsletter_campaigns alter column tracking set default false;

create function public.newsletter_record_engagement(p_id uuid,p_kind text,p_detail text,p_record boolean default true)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare m newsletter_messages; begin
 if p_kind not in ('open','click') then return false; end if;
 select * into m from newsletter_messages where id=p_id;
 if not found or m.kind<>'campaign' or not m.tracking_enabled or m.accepted_at is null then return false; end if;
 if not p_record then return true; end if;
 insert into newsletter_events(id,message_id,campaign_id,subscriber_id,kind,occurred_at,detail)
 values('https:'||m.id::text||':'||p_kind||':'||md5(coalesce(p_detail,'')),m.id,m.campaign_id,m.subscriber_id,p_kind,now(),left(p_detail,500))
 on conflict(id) do nothing;
 return true;
end $$;
revoke all on function public.newsletter_record_engagement(uuid,text,text,boolean) from public,anon,authenticated;
grant execute on function public.newsletter_record_engagement(uuid,text,text,boolean) to service_role;

-- Keep the latest opt-out boundary so a second opt-out also cancels a pending rejoin.
create or replace function public.newsletter_unsubscribe(p_id uuid,p_status text default 'unsubscribed')
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if p_status not in ('unsubscribed','bounced','complained') then raise exception 'invalid_status'; end if;
 update newsletter_subscribers set status=case when status='complained' then status else p_status end,
  unsubscribed_at=now(),updated_at=now() where id=p_id;
 if not found then return false; end if;
 update newsletter_tokens set expires_at=least(expires_at,now()) where subscriber_id=p_id;
 update newsletter_messages set status='cancelled',payload='{}' where subscriber_id=p_id and status='queued';
 insert into newsletter_audit(action,detail) values('subscriber_'||p_status,jsonb_build_object('subscriber_id',p_id));
 return true;
end $$;

-- An explicit signup after an opt-out may request a fresh confirmation immediately.
-- The normal resend cooldown still protects addresses that have not opted out.
create or replace function public.newsletter_signup(p_email text,p_topics text[],p_source text,p_token_hash text,p_token text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare s newsletter_subscribers; fresh_request boolean; begin
 insert into newsletter_subscribers(email,topics,pending_topics,source,last_signup_at)
 values(p_email,p_topics,p_topics,p_source,now()-interval '2 hours') on conflict(email) do nothing;
 select * into s from newsletter_subscribers where email=p_email for update;
 if s.status in ('active','bounced','complained') then return jsonb_build_object('ok',true,'queued',false); end if;
 fresh_request:=s.status='unsubscribed' and s.last_signup_at<=s.unsubscribed_at;
 if s.status='pending' then
  update newsletter_subscribers set topics=p_topics,pending_topics=p_topics,updated_at=now() where id=s.id;
 end if;
 if not fresh_request and s.last_signup_at>now()-interval '1 hour' then return jsonb_build_object('ok',true,'queued',false); end if;
 update newsletter_subscribers set pending_topics=p_topics,last_signup_at=now(),updated_at=now() where id=s.id;
 if exists(select 1 from newsletter_messages where subscriber_id=s.id and kind='confirmation' and status in ('queued','sending','uncertain')) then
  return jsonb_build_object('ok',true,'queued',false);
 end if;
 insert into newsletter_tokens(token_hash,subscriber_id,expires_at) values(p_token_hash,s.id,now()+interval '7 days');
 insert into newsletter_messages(subscriber_id,kind,email,dedupe_key,payload)
 values(s.id,'confirmation',s.email,'confirm:'||p_token_hash,jsonb_build_object('token',p_token));
 return jsonb_build_object('ok',true,'queued',true);
end $$;

commit;
