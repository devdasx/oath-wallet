// Search discovery and user-requested retrieval are distinct from model training.
// Keep explicit groups aligned with public/robots.txt. Other bots retain the
// existing wildcard policy; robots.txt is not an authentication boundary.
export function publicSearchRobots(origin) {
  return `# Public Oath content: search discovery and user-requested retrieval.
# OAI-SearchBot is for search; ChatGPT-User is for user-requested visits.
# GPTBot training permissions are separate and retain the wildcard policy here.
# Crawling does not guarantee indexing, citations, or recommendations.
User-agent: OAI-SearchBot
Allow: /

User-agent: ChatGPT-User
Allow: /

User-agent: *
Allow: /

Sitemap: ${origin}/sitemap.xml
`;
}
