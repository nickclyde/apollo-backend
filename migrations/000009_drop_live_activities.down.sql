CREATE TABLE live_activities (
    id SERIAL PRIMARY KEY,
    apns_token character varying(100) UNIQUE,
    reddit_account_id character varying(32) DEFAULT ''::character varying,
    access_token character varying(64) DEFAULT ''::character varying,
    refresh_token character varying(64) DEFAULT ''::character varying,
    token_expires_at timestamp without time zone,
    thread_id character varying(32) DEFAULT ''::character varying,
    subreddit character varying(32) DEFAULT ''::character varying,
    next_check_at timestamp without time zone,
    expires_at timestamp without time zone,
    development boolean DEFAULT FALSE
);
