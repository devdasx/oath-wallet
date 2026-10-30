-- Read-only, session-based acquisition summary. Run from the linked repository:
-- supabase db query --linked -f OathWebsite/scripts/acquisition-summary.sql
-- Use complete UTC days; each landing session counts once, even after many clicks.
with bounds as (
  select date_trunc('day', now()) - interval '28 days' as start_at,
         date_trunc('day', now()) as end_at
), cohort as (
  select s.id, s.started_at, landing.path, landing.referrer,
         exists(select 1 from public.website_events e
                where e.session_id=s.id and e.kind='download'
                  and e.occurred_at < b.end_at) as clicked,
         (select count(*) from public.website_events e
          where e.session_id=s.id and e.kind='download'
            and e.occurred_at < b.end_at) as clicks
  from public.website_sessions s cross join bounds b
  join lateral (
    select path,referrer from public.website_events e
    where e.session_id=s.id and e.kind='visit'
    order by e.occurred_at,e.id limit 1
  ) landing on true
  where s.started_at>=b.start_at and s.started_at<b.end_at
)
select 'all' as segment, 'all' as value, count(*) as sessions,
       count(*) filter(where clicked) as store_click_sessions,
       coalesce(sum(clicks),0) as outbound_store_clicks,
       round(100.0*count(*) filter(where clicked)/nullif(count(*),0),2) as store_action_rate_pct
from cohort
union all
select 'landing_page', path, count(*), count(*) filter(where clicked),
       coalesce(sum(clicks),0), round(100.0*count(*) filter(where clicked)/nullif(count(*),0),2)
from cohort group by path
union all
select 'referrer_host', coalesce(referrer,'direct_or_unavailable'),count(*),count(*) filter(where clicked),
       coalesce(sum(clicks),0),round(100.0*count(*) filter(where clicked)/nullif(count(*),0),2)
from cohort group by referrer
order by segment,sessions desc;
