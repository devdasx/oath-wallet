-- Read-only, aggregate report for the existing private website_events schema.
-- App Store clicks are outbound website actions, not verified installations.
-- Run through an already authorized database connection; do not publish event rows.
-- First recorded page view is the landing page. Missing/blocked referrers remain unattributed.
with period as (
  select now() - interval '28 days' as since
), landings as (
  select distinct on (session_id) session_id, path, referrer, occurred_at
  from public.website_events, period
  where kind = 'page_view' and occurred_at >= since
  order by session_id, occurred_at, id
), sessions as (
  select l.session_id, l.path,
    case when l.referrer ~ '(^|\.)(chatgpt\.com|chat\.openai\.com)$' then 'ChatGPT referral'
         when l.referrer ~ '(^|\.)perplexity\.ai$' then 'Perplexity referral'
         when l.referrer ~ '(^|\.)claude\.ai$' then 'Claude referral'
         when l.referrer = 'gemini.google.com' then 'Gemini referral'
         when l.referrer = 'copilot.microsoft.com' then 'Copilot referral'
         when l.referrer ~ '(^|\.)google\.(com|[a-z]{2}|co\.[a-z]{2}|com\.[a-z]{2})$' then 'Google referral'
         when l.referrer ~ '(^|\.)bing\.com$' then 'Bing referral'
         when l.referrer ~ '(^|\.)duckduckgo\.com$' then 'DuckDuckGo referral'
         when l.referrer = 'search.brave.com' then 'Brave referral'
         when l.referrer is null or l.referrer = '' then 'Unattributed'
         else 'Other referral' end as channel,
    exists(select 1 from public.website_events e where e.session_id=l.session_id
      and e.kind='download' and e.occurred_at>=l.occurred_at) as app_store_clicked
  from landings l
)
select channel, path as landing_page, count(*) as sessions,
       count(*) filter(where app_store_clicked) as sessions_with_app_store_click,
       round(100.0 * count(*) filter(where app_store_clicked) / nullif(count(*),0),2) as app_store_click_percent
from sessions group by channel,path order by sessions desc,landing_page;
-- A search referrer is an attribution signal, not proof of a particular query
-- or of paid versus organic traffic. Compare with Search Console separately.
-- Google AI features and Bing AI answers cannot be separated from conventional
-- search using these hostname-only referrers. AI apps may omit referrers entirely.
-- This report does not measure citations, assistant recommendations or installs.
