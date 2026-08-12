// Atelier Capture — synthetic X conversation builders (test support, NOT a test file).
//
// Shared by twitter-thread.test.js (the pure walk) and twitter-detail-client.test.js (the
// request/expansion side) since [090] 2A split them: both need to hand the parser a
// TweetDetail-shaped body, and two copies of that shape would be two things to keep in
// step with X.
//
// These are INVENTED shapes, and that is a known limitation rather than a feature: they
// pin the parser's own logic (forks, foreign authors, branch resolution) but prove nothing
// about the live endpoint. The committed LIVE fixture is what does that — see [090] 1A and
// `checkThreadDetail` in src/drift.js. Keep these for the cases a real capture won't
// contain; don't grow them into a substitute for one.

/** A minimal tweet result in the timeline/TweetDetail shape. */
export function tweet({ id, author = "author", text = "t", replyTo = null, media = [], replyCount = 0 }) {
  return {
    __typename: "Tweet",
    rest_id: id,
    core: { user_results: { result: { core: { screen_name: author, name: author.toUpperCase() } } } },
    legacy: {
      full_text: text,
      conversation_id_str: "100",
      reply_count: replyCount,
      ...(replyTo ? { in_reply_to_status_id_str: replyTo } : {}),
      ...(media.length ? { extended_entities: { media } } : {}),
    },
  };
}

export const photo = (key) => ({
  media_key: key, media_url_https: `https://pbs.twimg.com/media/${key}.jpg`, type: "photo",
});

/** A TweetDetail body: the focal tweet as a bare entry, the rest inside a conversation
 * MODULE — the two shapes the real response mixes. */
export function conversation(tweets) {
  const [first, ...rest] = tweets;
  return {
    data: { threaded_conversation_with_injections_v2: { instructions: [{
      type: "TimelineAddEntries",
      entries: [
        { entryId: `tweet-${first.rest_id}`, content: {
          entryType: "TimelineTimelineItem",
          itemContent: { itemType: "TimelineTweet", tweet_results: { result: first } },
        } },
        { entryId: "conversationthread-999", content: {
          entryType: "TimelineTimelineModule",
          items: rest.map((t) => ({
            entryId: `conversationthread-999-tweet-${t.rest_id}`,
            item: { itemContent: { itemType: "TimelineTweet", tweet_results: { result: t } } },
          })),
        } },
      ],
    }] } },
  };
}
