create index newsletter_events_message_time on public.newsletter_events(message_id,occurred_at desc);

create function public.newsletter_delivery_log(p_campaign uuid default null)
returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
 select coalesce(jsonb_agg(r order by r.created_at desc),'[]') from (
  select m.id,m.email,m.kind,m.status,m.error,m.provider_id,m.accepted_at,m.created_at,
   e.delivered_at,e.opened_at,e.clicked_at,e.bounced_at,e.complained_at,e.unsubscribed_at,e.last_event_at,e.last_detail
  from (select * from newsletter_messages where p_campaign is null or campaign_id=p_campaign order by created_at desc,id limit 100) m
  left join lateral (
   select min(occurred_at) filter(where kind='delivered') delivered_at,
    max(occurred_at) filter(where kind='open') opened_at,
    max(occurred_at) filter(where kind='click') clicked_at,
    max(occurred_at) filter(where kind='bounce') bounced_at,
    max(occurred_at) filter(where kind='complaint') complained_at,
    max(occurred_at) filter(where kind='unsubscribe') unsubscribed_at,
    max(occurred_at) last_event_at,
    (array_agg(detail order by occurred_at desc) filter(where detail is not null and detail<>''))[1] last_detail
   from newsletter_events where message_id=m.id
  ) e on true
 ) r;
$$;
revoke all on function public.newsletter_delivery_log(uuid) from public,anon,authenticated;
grant execute on function public.newsletter_delivery_log(uuid) to service_role;

create or replace function public.newsletter_campaign_stats(p_id uuid)
returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
 select jsonb_build_object(
 'accepted_total',(select count(*) from newsletter_messages where campaign_id=p_id and accepted_at is not null),
 'messages',(select coalesce(jsonb_object_agg(status,n),'{}') from(select status,count(*) n from newsletter_messages where campaign_id=p_id and kind='campaign' group by status)m),
 'events',(select coalesce(jsonb_object_agg(kind,n),'{}') from(select kind,count(distinct message_id) n from newsletter_events where campaign_id=p_id group by kind)e),
 'recent',newsletter_delivery_log(p_id));
$$;
revoke all on function public.newsletter_campaign_stats(uuid) from public,anon,authenticated;
grant execute on function public.newsletter_campaign_stats(uuid) to service_role;
